# homelab-gitops

Repositório GitOps central do homelab. Cada VM tem seu próprio cluster k3s + ArgoCD isolado, todos gerenciados a partir deste repo.

## Estrutura

```
homelab-gitops/
├── infra/          # Bases Kustomize compartilhadas (qualquer nó pode referenciar)
└── nodes/
    ├── <vm>/
    │   ├── apps/   # ArgoCD Applications do cluster dessa VM
    │   └── values/ # Helm values por serviço (quando usa chart upstream)
    └── ...
```

### `infra/`
Manifests Kustomize reutilizáveis. Um ArgoCD Application em qualquer nó pode apontar para `infra/<serviço>` sem duplicar YAML.

### `nodes/<vm>/apps/`
Cada arquivo `.yaml` é um ArgoCD `Application`. O ArgoCD daquela VM lê este diretório e sincroniza os recursos ao cluster.

Dois padrões de Application:

**Kustomize** (manifests em `infra/`):
```yaml
source:
  repoURL: https://github.com/ojasonw/homelab-gitops.git
  path: infra/monitoring
```

**Helm upstream + values local** (multi-source):
```yaml
sources:
  - repoURL: https://grafana.github.io/helm-charts
    chart: grafana
    targetRevision: "8.x"
  - repoURL: https://github.com/ojasonw/homelab-gitops.git
    ref: values
helm:
  valueFiles:
    - $values/nodes/<vm>/values/grafana.yaml
```

### `nodes/<vm>/values/`
Helm values específicos daquela VM. Sem valores aqui = chart sobe com defaults.

---

## Adicionar um novo nó

1. Criar `nodes/<vm>/apps/` no repo
2. Adicionar os ArgoCD Applications desejados
3. Rodar o Ansible para bootstrapar k3s + ArgoCD na VM:
   ```bash
   ansible-playbook -i inventory/hosts.yml playbooks/setup-k3s.yml -e target=<vm>
   ```
   O ArgoCD passa a ler `nodes/<vm>/apps/` automaticamente.

## Adicionar um serviço a um nó existente

1. Criar `nodes/<vm>/apps/<serviço>.yaml`
2. Se usar Helm, criar `nodes/<vm>/values/<serviço>.yaml`
3. Fazer push — o ArgoCD sincroniza automaticamente

---

## Nós ativos

| VM | Cluster | Apps |
|----|---------|------|
| `monitoring` | k3s standalone | victoriametrics, grafana, alertmanager, vmagent, vmalert, kube-state-metrics, exporters, cloudflare-tunnel, external-secrets, web-page, storage |
| `dev` | k3s standalone | localstack, n8n, docs-analitics |
| `homolog` | k3s standalone | joga-together, postgresql-joga |
| `zuno-app` | k3s standalone (`192.168.15.204`) | zuno-app e skull (via `infra/zuno-stack`), postgresql de cada tenant, cloudflare-tunnel-zunosite, external-secrets, storage, node-exporter, kube-state-metrics |

## Secrets

External Secrets Operator + Infisical. Cada app com secret tem um `*-externalsecret.yaml` em `infra/<app>/base/` referenciando o `ClusterSecretStore` definido em `infra/external-secrets/base/`.

---

## Fronteira com o Terraform

Este repo e dono do que **roda dentro** dos clusters. Parte do que esta **fora** deles saiu do controle manual e passou a ser gerenciada por Terraform, no repo [`zuno-webapp/terraform`](https://github.com/zuno-webapp/terraform).

| Recurso | Escopo |
|---|---|
| Zona DNS `zunosite.com` | os 10 registros — tunnel, MX/SPF/DKIM/DMARC do Hostinger |
| Tunnel `zunosite` e suas regras de ingress | o tunnel que serve os tenants no cluster `zuno-app` |
| Bucket R2 `tf-state-zuno-prod` | state do proprio Terraform |
| Pastas `/zuno-clients/<cliente>` no Infisical | as que os `ClusterSecretStore` de cada cliente leem — ver abaixo |

**Continua manual:** a zona `artjason.com` e o tunnel da VM `monitoring` (`578337b6-...`). O runbook de `docs/DOCS.md` vale para eles.

### Migração em andamento: identidade por cliente no Infisical

**Parcialmente aplicada, não completa.** Historicamente todo `ClusterSecretStore`
do cluster `zuno-app` autenticava no Infisical com uma identidade
COMPARTILHADA (Secret `infisical-universal-auth`), lendo a pasta antiga
`/zuno-app-prod` (e `/zuno-app-prod/skulls-prod` para o skull) — o
`secretsPath` era só um filtro, não uma fronteira de acesso real. O módulo
`infisical-customer` (repo terraform) está migrando cada cliente para
pasta (`/zuno-clients/<cliente>`) e identidade próprias, mas o apply está
bloqueado por permissão no lado do Infisical e as credenciais novas ainda
não existem.

Os `ClusterSecretStore` novos já existem neste repo, lado a lado com os
antigos, esperando pelo bootstrap manual das credenciais — ver
[`docs/migracao-infisical-per-customer.md`](docs/migracao-infisical-per-customer.md)
para o runbook completo do cutover.

### Ao adicionar um tenant novo ao `zuno-stack`

Alem do overlay em `infra/tenants/<tenant>/prod/`, o hostname precisa de uma **regra de ingress no tunnel**, e ela vive no Terraform — nao no dashboard da Cloudflare.

`local.tunnel_routes` em `infra/live/prod/main.tf` e o **estado desejado completo** do tunnel: uma rota criada pelo dashboard sobrevive so ate o proximo `terraform apply`, que a remove sem avisar. Ja aconteceu duas vezes com `skull.zunosite.com`.

A ordem naquela lista tambem importa: o cloudflared para no primeiro hostname que casa, entao hostname especifico precisa ficar **acima** do curinga `*.zunosite.com`.

Um subdominio novo **nao** precisa de registro DNS — o CNAME curinga ja cobre. So a regra de ingress.

### Ao adicionar uma secret ao stack

A lista de chaves esta declarada nos **dois** lados: em `infra/zuno-stack/base/externalsecret.yaml` aqui, e em `local.zuno_secret_keys` no Terraform. Mexer em so um falha em silencio — o pod sobe sem a variavel.
