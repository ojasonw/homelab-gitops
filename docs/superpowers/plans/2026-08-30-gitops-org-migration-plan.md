# Migração GitOps para `zuno-webapp/zuno-gitops` — Plano de Implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fazer `zuno-webapp/zuno-gitops` (privado, renomeado de `zuno-tips`) virar a fonte de verdade que o ArgoCD lê de fato, substituindo `ojasonw/homelab-gitops` (pessoal, público) — sem downtime dos tenants — e dissolver o padrão "1 tenant = N `Application`s avulsas copiadas à mão" pra um template único (`ApplicationSet`), aplicável a tenants futuros.

**Architecture:** Sincronizar o conteúdo Zuno-relevante do `homelab-gitops` atual pro `zuno-gitops`, trocar todo `repoURL` pra SSH, dissolver o chart Helm do Postgres em manifesto puro dentro de `zuno-stack/base`, converter o template estático (`infra/tenants/_template` + `scripts/new-tenant.sh`) num `ApplicationSet` real, bootstrapar uma deploy key SSH no ArgoCD (via Ansible, mesma classe do token do túnel Cloudflare), validar leitura isolada, e só então cortar `root-app` pro repo novo. `default`/`skulls`/`czanks` (já em produção) não são tocados — continuam com Postgres via Helm e `Application` avulsa até uma decisão separada.

**Tech Stack:** Kustomize, ArgoCD (`Application`, `ApplicationSet`), External Secrets Operator, Ansible (bootstrap de credencial), GitHub (deploy key SSH).

**Spec:** `docs/superpowers/specs/2026-08-30-gitops-org-migration-design.md` (mesmo repo, `ojasonw/homelab-gitops`)

## Global Constraints

- `zuno-tips` foi renomeado pra `zuno-gitops` — todo texto/URL nova referencia esse nome, não o antigo.
- Nome do Service do Postgres depois de inline: `postgres` (sem prefixo de tenant).
- Credencial do ArgoCD pro repo novo é **deploy key SSH**, não PAT — sem "Allow write access".
- `default`/`skulls`/`czanks` (produção) não mudam de padrão nesta migração — só tenants futuros usam Postgres inline + `ApplicationSet`.
- Nenhuma etapa aplica no cluster de produção antes da validação isolada (Task 6) — Tasks 1-5 só tocam os repos (`zuno-gitops`, `ansible`), não o `root-app`.
- Repositórios envolvidos, caminhos locais usados neste plano:
  - `zuno-gitops`: `~/my-projects/github-ojasonw/zuno-app/zuno-gitops` (remoto `zuno-webapp/zuno-gitops`)
  - `homelab-gitops`: `~/my-projects/github-ojasonw/personal/homelab-gitops` (remoto `ojasonw/homelab-gitops`, fonte hoje)
  - `ansible`: `~/my-projects/github-ojasonw/personal/ansible` (remoto `ojasonw/ansible`)
  - Cluster: `ssh ubuntu@192.168.15.204`, `kubectl` já configurado

---

### Task 1: Sincronizar `zuno-gitops` com o estado atual do `homelab-gitops`

Fecha `zuno-gitops` issue #4.

**Files:**
- Create: `~/my-projects/github-ojasonw/zuno-app/zuno-gitops/scripts/sync-from-homelab-gitops.sh`
- Modify: todo o conteúdo sob `infra/`, `nodes/zuno-app/`, `docs/`, `README.md` em `zuno-gitops` (espelhado do `homelab-gitops`)

**Interfaces:**
- Produces: `zuno-gitops` com conteúdo Zuno-relevante idêntico ao `homelab-gitops` atual (mesmo filtro da extração original de 2026-08-08: exclui `joga-together`, `n8n`, `monitoring`, `homolog`, `dev`, `docs-analitics`, `web-page`, `localstack-explorer`, `.github` do homelab (CI própria já existe em `zuno-gitops`), `.env`, `.codex`).

- [ ] **Step 1: Escrever o script de sync**

```bash
#!/usr/bin/env bash
# scripts/sync-from-homelab-gitops.sh
#
# Espelha o conteudo Zuno-relevante de ojasonw/homelab-gitops pra dentro
# deste repo. Mesmo filtro da extracao original de 2026-08-08: so o que
# pertence ao stack Zuno, nada de joga-together/n8n/monitoring/homolog/dev.
# Idempotente - roda de novo sempre que homelab-gitops mudar antes do
# cutover (Task 6).
set -euo pipefail

SRC="${1:-$HOME/my-projects/github-ojasonw/personal/homelab-gitops}"
DST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -d "$SRC/.git" ]; then
  echo "Origem invalida: $SRC nao e um repo git" >&2
  exit 1
fi

INFRA_DIRS=(
  beyla
  cloudflare-tunnel-zunosite
  external-secrets
  kube-state-metrics
  node-exporter
  postgresql
  storage
  tenants
  zuno-stack
)

for d in "${INFRA_DIRS[@]}"; do
  rsync -a --delete "$SRC/infra/$d/" "$DST/infra/$d/"
done

rsync -a --delete "$SRC/nodes/zuno-app/" "$DST/nodes/zuno-app/"
cp "$SRC/docs/migracao-infisical-per-customer.md" "$DST/docs/"

echo "Sync completo. Revise 'git status' e 'git diff' antes de commitar."
```

- [ ] **Step 2: Rodar o script**

Run: `chmod +x scripts/sync-from-homelab-gitops.sh && ./scripts/sync-from-homelab-gitops.sh`

Expected: sem erro; `git status` em `zuno-gitops` mostra o tenant `czanks` novo, `beyla.yaml`, e os arquivos divergentes já listados no diff manual feito antes (config-patch, kustomization, apps/*.yaml).

- [ ] **Step 3: Verificar que todo kustomization ainda builda**

Run:
```bash
for d in $(find infra nodes -name "kustomization.yaml" -exec dirname {} \;); do
  echo "==> $d"
  kubectl kustomize "$d" > /dev/null || echo "FALHOU: $d"
done
```

Expected: nenhuma linha `FALHOU`.

- [ ] **Step 4: Confirmar que `docs/novo-cliente.md`, `docs/onboarding-infra.md`, `infra/tenants/_template`, `scripts/new-tenant.sh` (conteúdo próprio deste repo, não existe no homelab-gitops) sobreviveram ao sync**

Run: `git status --porcelain -- docs/novo-cliente.md docs/onboarding-infra.md infra/tenants/_template scripts/new-tenant.sh`

Expected: vazio (nenhuma mudança/remoção) — o sync não toca esses caminhos.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: sincroniza com estado atual do homelab-gitops (czanks, beyla)"
```

---

### Task 2: Trocar `repoURL` de HTTPS pessoal para SSH `zuno-gitops`

Continua `zuno-gitops` issue #4.

**Files:**
- Modify: todo `.yaml` sob `nodes/zuno-app/apps/` e `infra/tenants/_template/` em `zuno-gitops` que contenha `repoURL:`

**Interfaces:**
- Consumes: conteúdo sincronizado pela Task 1
- Produces: zero ocorrência de `github.com/ojasonw/homelab-gitops` no repo; todo `repoURL` aponta pra `git@github.com:zuno-webapp/zuno-gitops.git`

- [ ] **Step 1: Trocar via sed**

```bash
grep -rl "github.com/ojasonw/homelab-gitops" --include="*.yaml" . | \
  xargs sed -i '' 's#https://github.com/ojasonw/homelab-gitops.git#git@github.com:zuno-webapp/zuno-gitops.git#g'
```

- [ ] **Step 2: Verificar que não sobrou nenhuma ocorrência**

Run: `grep -rn "github.com/ojasonw/homelab-gitops" --include="*.yaml" .`

Expected: sem output (grep sai com código 1).

- [ ] **Step 3: Rebuildar todo kustomization de novo (repoURL não afeta build local, mas confirma que o sed não quebrou YAML)**

Run: mesmo loop do Task 1 Step 3.

Expected: nenhuma linha `FALHOU`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: repoURL aponta pro proprio repo (SSH), nao mais homelab-gitops"
```

---

### Task 3: Dissolver o chart Postgres em manifesto puro (`zuno-stack/base`)

Fecha `zuno-gitops` issue #5. Só afeta o **template** de tenant futuro — `infra/tenants/{default,skulls,czanks}` e `infra/postgresql/{zuno-app,skulls,czanks}-prod` não mudam nesta task (ficam no padrão Helm atual, fora de escopo).

**Files:**
- Create: `infra/zuno-stack/base/postgres-statefulset.yaml`
- Create: `infra/zuno-stack/base/postgres-service.yaml`
- Modify: `infra/zuno-stack/base/kustomization.yaml` (adicionar os dois resources novos)
- Modify: `infra/tenants/_template/prod/config-patch.yaml` (`SPRING_DATASOURCE_URL` aponta pra `postgres:5432`, não mais `postgresql-__TENANT__-prod`)
- Delete: `infra/tenants/_template/application-postgres.yaml` (Application separada de Postgres deixa de existir no template)
- Create: `infra/tenants/_template/prod/postgres-patch.yaml` (tamanho de disco, nome do banco — variam por cliente, mesmo padrão de `config-patch.yaml`)

**Interfaces:**
- Consumes: `infra/postgresql/chart/templates/{statefulset,service,secret}.yaml` (fonte pros manifestos novos — secret já é coberto por `postgres-secret-patch.yaml` existente, não precisa duplicar)
- Produces: um Postgres `StatefulSet`/`Service` nascendo automaticamente em qualquer kustomization que importe `zuno-stack/base`, sem `Application` separada

- [ ] **Step 1: Ler o chart de origem**

Run: `cat infra/postgresql/chart/templates/statefulset.yaml infra/postgresql/chart/templates/service.yaml infra/postgresql/chart/values.yaml`

(Chart caseiro, só 3 templates — conteúdo já visto no design, use como base pros dois arquivos abaixo.)

- [ ] **Step 2: Criar `infra/zuno-stack/base/postgres-service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  clusterIP: None
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
```

- [ ] **Step 3: Criar `infra/zuno-stack/base/postgres-statefulset.yaml`**

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: "changeme-db"
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: changeme-postgres
                  key: postgres-password
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
              subPath: pgdata
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 250m
              memory: 384Mi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: custom-local-path
        resources:
          requests:
            storage: 8Gi
```

(`POSTGRES_DB`/`secretKeyRef.name` com valor `changeme-*` de propósito — corrigidos pelo patch por tenant no Step 6, igual todo outro valor por-cliente neste repo.)

- [ ] **Step 4: Registrar os dois arquivos no `kustomization.yaml` do base**

Modify `infra/zuno-stack/base/kustomization.yaml`, dentro do bloco `resources:`, adicionar:
```yaml
  - postgres-statefulset.yaml
  - postgres-service.yaml
```

- [ ] **Step 5: Build isolado do base pra conferir sintaxe**

Run: `kubectl kustomize infra/zuno-stack/base > /dev/null`

Expected: sem erro (mesmo com `POSTGRES_DB`/secret ainda com valor placeholder — kustomize não valida referência cruzada de Secret).

- [ ] **Step 6: Criar `infra/tenants/_template/prod/postgres-patch.yaml`**

```yaml
# Nome do banco e do Secret variam por cliente — mesmo padrao de
# config-patch.yaml. secretKeyRef.name precisa bater com o target de
# postgres-secret-patch.yaml (__TENANT__-postgres).
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  template:
    spec:
      containers:
        - name: postgres
          env:
            - name: POSTGRES_DB
              value: "__TENANT__-db"
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: __TENANT__-postgres
                  key: postgres-password
```

- [ ] **Step 7: Registrar o patch novo no `kustomization.yaml` do template**

Modify `infra/tenants/_template/prod/kustomization.yaml`, dentro de `patches:`, adicionar:
```yaml
  - path: postgres-patch.yaml
```

- [ ] **Step 8: Trocar `SPRING_DATASOURCE_URL` no `config-patch.yaml` do template**

Modify `infra/tenants/_template/prod/config-patch.yaml`:
```diff
-  SPRING_DATASOURCE_URL: "jdbc:postgresql://postgresql-__TENANT__-prod:5432/__TENANT__-db"
+  SPRING_DATASOURCE_URL: "jdbc:postgresql://postgres:5432/__TENANT__-db"
```

- [ ] **Step 9: Apagar `application-postgres.yaml` do template**

```bash
rm infra/tenants/_template/application-postgres.yaml
```

- [ ] **Step 10: Build do template inteiro, substituindo `__TENANT__` manualmente pra validar**

```bash
mkdir -p /tmp/tenant-test/prod
cp infra/tenants/_template/prod/*.yaml /tmp/tenant-test/prod/
sed -i '' 's/__TENANT__/testtenant/g' /tmp/tenant-test/prod/*.yaml
sed -i '' "s#\.\./\.\./\.\./zuno-stack/base#$(pwd)/infra/zuno-stack/base#" /tmp/tenant-test/prod/kustomization.yaml
kubectl kustomize /tmp/tenant-test/prod > /dev/null
```

Expected: sem erro. Confirma que o template inteiro (base + patches) builda com Postgres inline.

- [ ] **Step 11: Limpar teste e commitar**

```bash
rm -rf /tmp/tenant-test
git add -A
git commit -m "feat: dissolve chart Postgres em manifesto puro no zuno-stack/base

Postgres nasce junto do app via kustomize, sem Application/Helm separado.
Vale so pra tenants futuros - default/skulls/czanks continuam no Helm."
```

---

### Task 4: Converter o template estático num `ApplicationSet`

Fecha `zuno-gitops` issue #6. Depende da Task 3 (template já sem `application-postgres.yaml`).

**Files:**
- Create: `nodes/zuno-app/apps/tenants-appset.yaml`
- Modify: `infra/tenants/_template/application.yaml` (vira só documentação/referência — o `ApplicationSet` não lê mais este arquivo por template de arquivo, os parâmetros vêm inline)

**Interfaces:**
- Consumes: `infra/tenants/_template/prod/*` (mesmo diretório, mesmos patches — só passa a ser referenciado por `path` fixo com o nome do tenant vindo do gerador, não mais copiado por `scripts/new-tenant.sh`)
- Produces: uma `Application` por entrada da lista do gerador, mesmo nome/namespace que `scripts/new-tenant.sh` geraria hoje

- [ ] **Step 1: Criar `nodes/zuno-app/apps/tenants-appset.yaml`**

```yaml
# ApplicationSet: 1 entrada na lista abaixo = 1 tenant completo (app +
# postgres + secrets), sem arquivo novo por cliente. Ver
# docs/onboarding-infra.md pra como adicionar um cliente.
#
# default/skulls/czanks NAO estao nesta lista de proposito — continuam com
# Application avulsa + Postgres Helm (ver nodes/zuno-app/apps/{default,
# skulls,czanks}.yaml e postgresql-{...}.yaml). Migrar eles pra ca e
# trabalho futuro separado.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: zuno-tenants
  namespace: argocd
spec:
  generators:
    - list:
        elements: []
        # Exemplo de elemento, adicionado quando o primeiro tenant migrar
        # pra este padrao:
        # - tenant: exemplo
  template:
    metadata:
      name: "{{tenant}}"
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: default
      source:
        repoURL: git@github.com:zuno-webapp/zuno-gitops.git
        targetRevision: main
        path: "infra/tenants/_template/prod"
        kustomize:
          namePrefix: ""
          patches:
            - target:
                kind: Kustomization
              patch: |-
                - op: replace
                  path: /namespace
                  value: "zuno-{{tenant}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: "zuno-{{tenant}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

- [ ] **Step 2: Validar a sintaxe do YAML (não builda via kustomize — `ApplicationSet` é lido pelo controller, não pelo `kubectl kustomize`)**

Run: `kubectl apply --dry-run=client -f nodes/zuno-app/apps/tenants-appset.yaml`

Expected: `applicationset.argoproj.io/zuno-tenants created (dry run)` (o `kubectl` local não precisa estar conectado ao cluster real pra validar sintaxe — se `--dry-run=client` reclamar de contexto, rode `kubectl apply --dry-run=client --validate=false -f ...` só pra checar YAML bem-formado).

- [ ] **Step 3: Anotar `application.yaml` do template como referência histórica**

Modify `infra/tenants/_template/application.yaml`, adicionar no topo:
```yaml
# NAO USADO MAIS a partir da introducao do ApplicationSet
# (nodes/zuno-app/apps/tenants-appset.yaml). Fica como referencia do
# formato de Application avulsa que default/skulls/czanks ainda usam.
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: ApplicationSet pra provisionamento de tenant futuro

Substitui a Application avulsa gerada por scripts/new-tenant.sh. Onboarding
de cliente novo vira 1 entrada em generators.list.elements, sem arquivo
novo. default/skulls/czanks ficam fora, continuam no padrao antigo."
```

---

### Task 5: Bootstrap da deploy key SSH (repo `ansible`)

Fecha `ansible` issue #1. Repo diferente — `~/my-projects/github-ojasonw/personal/ansible`.

**Files:**
- Create: `playbooks/zuno_gitops_deploy_key.yml`
- Modify: `host_vars/zuno-app/vault.yml` (nova var `vault_zuno_gitops_deploy_key`, chave privada)

**Interfaces:**
- Produces: `Secret` `zuno-gitops-repo` (label `argocd.argoproj.io/secret-type: repository`) no namespace `argocd`, campos `url` (`git@github.com:zuno-webapp/zuno-gitops.git`) e `sshPrivateKey`

- [ ] **Step 1: Gerar o par de chaves (fora do playbook — ação manual, uma vez)**

Run: `ssh-keygen -t ed25519 -f /tmp/zuno-gitops-deploy-key -N "" -C "argocd-zuno-gitops"`

Expected: dois arquivos, `/tmp/zuno-gitops-deploy-key` (privada) e `/tmp/zuno-gitops-deploy-key.pub` (pública).

- [ ] **Step 2: Adicionar a pública como Deploy Key no GitHub**

Run: `gh repo deploy-key add /tmp/zuno-gitops-deploy-key.pub --repo zuno-webapp/zuno-gitops --title "argocd-read-only" --read-only`

Expected: confirmação de key adicionada, sem "Allow write access".

- [ ] **Step 3: Guardar a chave privada no ansible-vault**

Run:
```bash
cd ~/my-projects/github-ojasonw/personal/ansible
ansible-vault encrypt_string --vault-password-file .vault_system_pass \
  --name vault_zuno_gitops_deploy_key "$(cat /tmp/zuno-gitops-deploy-key)" \
  >> host_vars/zuno-app/vault.yml
```

Expected: bloco `vault_zuno_gitops_deploy_key: !vault |` adicionado ao fim do arquivo.

- [ ] **Step 4: Apagar a chave privada do disco local (já está no vault)**

Run: `shred -u /tmp/zuno-gitops-deploy-key /tmp/zuno-gitops-deploy-key.pub 2>/dev/null || rm -f /tmp/zuno-gitops-deploy-key /tmp/zuno-gitops-deploy-key.pub`

- [ ] **Step 5: Criar `playbooks/zuno_gitops_deploy_key.yml`**

```yaml
# Aplica a deploy key SSH do zuno-gitops como Secret de repositorio do
# ArgoCD. Mesmo padrao de cloudflare_zunosite_secret.yml: credencial
# ansible-vault, nao Infisical (ArgoCD ler este repo e pre-requisito de
# tudo que o Infisical/GitOps materializa, entao nao pode depender de si
# mesmo).
- name: Apply zuno-gitops deploy key as ArgoCD repository Secret
  hosts: zuno-app
  gather_facts: false
  vars:
    vault_zuno_gitops_deploy_key: !vault |
      # populado por ansible-vault encrypt_string no Step 3
  tasks:
    - name: Render repository secret manifest
      command: >
        kubectl create secret generic zuno-gitops-repo
        --namespace argocd
        --from-literal=type=git
        --from-literal=url=git@github.com:zuno-webapp/zuno-gitops.git
        --from-literal=sshPrivateKey={{ vault_zuno_gitops_deploy_key }}
        --dry-run=client -o yaml
      register: secret_manifest
      changed_when: false
      no_log: true

    - name: Add ArgoCD repository label
      ansible.builtin.set_fact:
        labeled_manifest: "{{ secret_manifest.stdout | from_yaml | combine({'metadata': {'labels': {'argocd.argoproj.io/secret-type': 'repository'}}}, recursive=True) | to_nice_yaml }}"
      no_log: true

    - name: Write secret manifest to a temp file
      ansible.builtin.copy:
        content: "{{ labeled_manifest }}"
        dest: /tmp/zuno-gitops-repo-secret.yaml
        mode: "0600"
      no_log: true

    - name: Apply the secret
      command: kubectl apply -f /tmp/zuno-gitops-repo-secret.yaml
      no_log: true

    - name: Remove temp manifest
      ansible.builtin.file:
        path: /tmp/zuno-gitops-repo-secret.yaml
        state: absent
```

(Nota: cole o bloco `!vault |` real gerado no Step 3 no lugar do placeholder de `vars.vault_zuno_gitops_deploy_key` — ou, preferencialmente, referencie a var já carregada de `host_vars/zuno-app/vault.yml` em vez de duplicá-la no playbook, já que `ansible-playbook` carrega `host_vars` automaticamente por host.)

- [ ] **Step 2 (execução): Rodar o playbook**

Run: `ansible-playbook playbooks/zuno_gitops_deploy_key.yml --vault-password-file .vault_system_pass`

Expected: `changed=1` na task "Apply the secret", sem erro.

- [ ] **Step 3 (execução): Confirmar o Secret existe e tem o label certo**

Run: `ssh ubuntu@192.168.15.204 "kubectl get secret zuno-gitops-repo -n argocd -o jsonpath='{.metadata.labels}'"`

Expected: `{"argocd.argoproj.io/secret-type":"repository"}`

- [ ] **Step 4: Commit (playbook, sem a chave privada em texto — só o vault)**

```bash
git add playbooks/zuno_gitops_deploy_key.yml host_vars/zuno-app/vault.yml
git commit -m "feat: bootstrap deploy key SSH pro ArgoCD ler zuno-gitops"
```

---

### Task 6: Validar leitura isolada, depois cortar `root-app`

Fecha `homelab-gitops` issue #116. Depende de Tasks 1, 2 e 5 concluídas.

**Files:**
- Nenhum arquivo de repo — só operações no cluster via `kubectl`/ArgoCD.

**Interfaces:**
- Consumes: `Secret zuno-gitops-repo` (Task 5), conteúdo sincronizado com `repoURL` já trocado (Tasks 1-2)

- [ ] **Step 1: Validar a leitura do repo novo isoladamente, sem tocar `root-app`**

Run:
```bash
ssh ubuntu@192.168.15.204 "kubectl exec -n argocd deploy/argocd-repo-server -- argocd-util --help" 2>&1 | head -1
```
Se `argocd-util`/CLI não estiver disponível no pod, validar via um `Application` de teste descartável:
```bash
ssh ubuntu@192.168.15.204 "cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: zuno-gitops-read-test
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:zuno-webapp/zuno-gitops.git
    targetRevision: main
    path: infra/zuno-stack/base
  destination:
    server: https://kubernetes.default.svc
    namespace: zuno-gitops-read-test
  syncPolicy: {}
EOF"
sleep 10
ssh ubuntu@192.168.15.204 "kubectl get application zuno-gitops-read-test -n argocd -o jsonpath='{.status.sync.status} {.status.conditions}'"
```

Expected: sem `ComparisonError`/`Unknown` — o repo respondeu (não precisa estar `Synced`, `syncPolicy: {}` deliberadamente não sincroniza, só testa leitura).

- [ ] **Step 2: Apagar a `Application` de teste**

Run: `ssh ubuntu@192.168.15.204 "kubectl delete application zuno-gitops-read-test -n argocd"`

- [ ] **Step 3: Cortar `root-app` pro repo novo**

Run: `ssh ubuntu@192.168.15.204 "kubectl patch application root-app -n argocd --type merge -p '{\"spec\":{\"source\":{\"repoURL\":\"git@github.com:zuno-webapp/zuno-gitops.git\"}}}'"`

- [ ] **Step 4: Forçar refresh e aguardar sync**

Run:
```bash
ssh ubuntu@192.168.15.204 "kubectl patch application root-app -n argocd --type merge -p '{\"metadata\":{\"annotations\":{\"argocd.argoproj.io/refresh\":\"hard\"}}}'"
```
Poll (até 6x, 10s de intervalo):
```bash
ssh ubuntu@192.168.15.204 "kubectl get application root-app -n argocd -o jsonpath='{.status.sync.status} {.status.health.status}'"
```

Expected: `Synced Healthy`.

- [ ] **Step 5: Confirmar todas as Applications filhas ainda `Synced`/`Healthy` a partir da fonte nova**

Run: `ssh ubuntu@192.168.15.204 "kubectl get application -n argocd -o custom-columns=NAME:.metadata.name,REPO:.spec.source.repoURL,SYNC:.status.sync.status,HEALTH:.status.health.status"`

Expected: toda linha com `REPO` = `git@github.com:zuno-webapp/zuno-gitops.git`, `SYNC=Synced`, `HEALTH=Healthy`. Nenhuma regressão nos tenants existentes (Postgres/Deployments não mudam — só a fonte do manifesto).

- [ ] **Step 6: Confirmar nenhum pod reiniciou por causa do cutover**

Run: `ssh ubuntu@192.168.15.204 "kubectl get pods -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp | grep -E 'zuno-|argocd'"`

Expected: `AGE` de cada pod não mudou por causa desta task (cutover é troca de fonte de manifesto, não recriação de recurso).

---

### Task 7: Arquivar `homelab-gitops`

Último passo da issue #116.

**Files:**
- Modify: `README.md` do `homelab-gitops` (aviso de arquivamento no topo)
- Modify: `~/my-projects/github-ojasonw/zuno-app/CLAUDE.md` (linha da tabela *Tools & accounts* — `homelab-gitops` sai de "live source of truth", `zuno-gitops` vira "✅ live")
- Modify: `~/my-projects/github-ojasonw/zuno-app/docs/zunosite-standardization.md` (marcar item concluído, se existir entrada pra isso)

**Interfaces:**
- Nenhuma — task de documentação/encerramento.

- [ ] **Step 1: Confirmar Task 6 estável há pelo menos algumas horas antes de arquivar (não apagar a rede de segurança cedo demais)**

Run: repetir o Step 5 da Task 6, confirmar ainda `Synced`/`Healthy`.

- [ ] **Step 2: Adicionar aviso no topo do README do `homelab-gitops`**

```markdown
> **ARQUIVADO em 2026-08-30.** Este repo não é mais lido pelo ArgoCD — a
> fonte de verdade agora é [`zuno-webapp/zuno-gitops`](https://github.com/zuno-webapp/zuno-gitops).
> Mantido só como histórico.

```
(inserir como primeira linha, antes do conteúdo existente)

- [ ] **Step 3: Marcar o repo como archived no GitHub**

Run: `gh repo archive ojasonw/homelab-gitops --yes`

- [ ] **Step 4: Atualizar `zuno-app/CLAUDE.md`**

Modify a linha da tabela *Tools & accounts*:
```diff
-| GitHub — `homelab-gitops` repo | ArgoCD's **live** source of truth for everything running in the cluster (repoURL still points here) | `ojasonw` personal | ❌ |
-| GitHub — `zuno-webapp/zuno-gitops` repo (renamed from `gitops`, then from `zuno-tips`) | reference copy of the Zuno GitOps content, extracted 2026-08-08 — not yet wired to ArgoCD, migration design spec written (`ojasonw/homelab-gitops` PR #115) | `zuno-webapp` org | ✅ (copy only, cutover pending) |
+| GitHub — `homelab-gitops` repo | **archived** — was ArgoCD's source of truth, replaced by `zuno-gitops` on 2026-08-30 | `ojasonw` personal | ❌ (archived) |
+| GitHub — `zuno-webapp/zuno-gitops` repo | ArgoCD's **live** source of truth for everything running in the cluster | `zuno-webapp` org | ✅ |
```

- [ ] **Step 5: Commit e push (repo `zuno-app`, branch `main` — mudança de documentação, sem risco)**

```bash
cd ~/my-projects/github-ojasonw/zuno-app
git add CLAUDE.md
git commit -m "docs: homelab-gitops arquivado, zuno-gitops e a fonte de verdade"
git push origin main
```

---

## Self-Review

**Cobertura da spec**: as 4 decisões da spec (repo/deploy key, ponto de corte único, Postgres inline, `ApplicationSet`) mapeiam pras Tasks 5+6, 6, 3, 4 respectivamente. Riscos da spec (`repoURL` esquecido, credencial errada, repo desatualizado) têm verificação explícita nas Tasks 1 Step 3-4, 2 Step 2, 6 Step 1.

**Fora de escopo respeitado**: nenhuma task toca `infra/tenants/{default,skulls,czanks}` nem `infra/postgresql/{zuno-app,skulls,czanks}-prod` — só o `_template` e o `zuno-stack/base` compartilhado (que ganha recursos novos, mas os tenants existentes não os referenciam já que seus `kustomization.yaml` não mudam nesta migração).
