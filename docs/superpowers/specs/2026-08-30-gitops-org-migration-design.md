# Design: gitops sai de `ojasonw/homelab-gitops` (pessoal) para `zuno-webapp/zuno-tips` (org)

## Contexto

`zuno-webapp/zuno-tips` já existe — extraído de `ojasonw/homelab-gitops` em
2026-08-08 como cópia de referência, mas **nunca foi live**: as `Application`
do ArgoCD (`root-app` e as 12 filhas) ainda apontam pro repo pessoal. Ver
`zuno-app/CLAUDE.md`, seção *Tools & accounts* — este repo é um dos
candidatos de migração da tabela de padronização de contas.

Motivação de mexer agora, além da padronização: enquanto investigava por que
o tenant `czanks` não subia (issues resolvidas em `homelab-gitops` PR #113 e
#114), ficou claro que o formato atual de "1 tenant = N `Application`s
avulsas, cada arquivo copiado do cliente anterior" é frágil — foi
exatamente por isso que o `Application` do Postgres do czanks ficou faltando
sem ninguém notar até o backend entrar em `CrashLoopBackOff`. Duas mudanças
saem desse mesmo problema: trocar de dono do repo, e trocar a forma como um
tenant é descrito.

## Decisões

### 1. Repo: `zuno-tips` vira o gitops de verdade

Reaproveita o repo já extraído em vez de criar um novo do zero — evita
recomeçar história/estrutura.

**Diferença que muda o setup**: `homelab-gitops` (pessoal) é **público**, por
isso o ArgoCD nunca precisou de credencial de leitura de git. `zuno-tips` é
**privado** (mesmo padrão dos outros repos da org — terraform/backend/
frontend também são privados). Isso é peça nova: hoje não existe nenhum
`Secret` do tipo `repository` no namespace `argocd` do cluster.

- Criar uma **deploy key** SSH no repo (`Settings → Deploy keys` do
  `zuno-tips`, sem "Allow write access") — não um PAT. Escopo nativo de 1
  repo só, sem vínculo com conta pessoal, sem expiração forçada (PAT
  fine-grained do GitHub expira em até 1 ano, precisa rotação; deploy key
  não). ArgoCD suporta nativamente via `sshPrivateKey` no `Secret` de repo,
  mais simples que usuário+senha de um PAT.
- Aplicar como `Secret` (label `argocd.argoproj.io/secret-type: repository`,
  campos `url` + `sshPrivateKey`) no namespace `argocd` — bootstrap manual,
  mesma classe dos outros segredos deste cluster que não passam pelo
  Infisical (token do túnel Cloudflare, identidade universal do Infisical)
  porque autenticam algo que o próprio Infisical/GitOps depende de já
  estar funcionando.
- Validar a leitura (`argocd repo get` ou equivalente) **antes** do cutover,
  isolado, sem mexer em nenhuma `Application` real ainda.

### 2. Ponto de corte é um só: `root-app`

`root-app` é a única `Application` aplicada manualmente (bootstrap — não é
gerada por nada). Ela aponta pra `nodes/zuno-app/apps` no repo, e cada
arquivo `.yaml` nesse diretório vira uma `Application` filha, cada uma
carregando seu próprio `repoURL` (mesmo valor, repetido em cada arquivo).

Cutover:
1. Preparar `zuno-tips` com o conteúdo completo já migrado — todo `repoURL`
   trocado pro org, de ponta a ponta — sem tocar `root-app` ainda.
2. `kubectl edit application root-app -n argocd`, trocar só o `repoURL`.
3. ArgoCD reconcilia a partir do repo novo. Nomes de `Application`,
   namespace e recursos continuam idênticos — não é recriação, é troca de
   fonte. Nenhum downtime esperado nos tenants (Postgres/Deployments não
   mudam, só de onde o manifesto que os descreve é lido).
4. Confirmar todas as 12+ `Application` `Synced`/`Healthy` a partir da fonte
   nova antes de considerar concluído.
5. `homelab-gitops` (pessoal) vira arquivado/read-only — mesmo tratamento
   dos outros repos já listados como migração pendente.

### 3. Postgres: sai do Helm chart, vira manifesto puro — só tenants futuros

`infra/postgresql/chart` é um chart caseiro de 3 templates (statefulset,
service, secret) — não precisava ser um chart Helm pra começo de conversa.
Ele dissolve em YAML direto dentro de `infra/zuno-stack/base/` (junto do
`deployment.yaml` que já existe ali), parametrizado por patch por cliente
— mesmo padrão que `config-patch.yaml` já usa hoje.

Efeito: elimina o `Application` `postgresql-<tenant>-prod` separado. Cada
tenant passa a ter **um** `Application` cobrindo app + Postgres + secrets,
tudo no mesmo namespace. Nome do Service do Postgres simplifica pra
`postgres` (sem prefixo de tenant — o namespace já isola; era
`postgresql-<tenant>-prod`, herdado do padrão Bitnami que o chart nunca
precisou seguir).

**Escopo deliberadamente limitado**: essa dissolução vale só pra tenants
**futuros**. `default`, `skulls` e `czanks` continuam com o Postgres atual
(`Application` Helm separada) — migrar StatefulSet com dado real em produção
é um risco à parte, fora do escopo deste corte. Fica como trabalho futuro
opcional, não bloqueia nada aqui.

### 4. Provisionamento de tenant: `ApplicationSet`, não Helm

Cogitado um chart Helm único com `range` sobre `.Values.tenants` pra gerar
todos os tenants de uma vez — descartado porque isso naturalmente produz
**um release/uma `Application` cobrindo todos os clientes**, o que reabre uma
decisão já tomada antes neste design: cada tenant precisa do próprio
`Application`, com seu próprio blast radius e status de sync, não uma
`Application` guarda-chuva.

`ApplicationSet` (controller já rodando no cluster, `argocd-applicationset-
controller`, zero instalação nova) resolve as duas coisas ao mesmo tempo:
- **Um template só** — elimina a duplicação de YAML entre `infra/tenants/
  default`, `skulls`, `czanks` (hoje cada um é cópia do anterior com
  `s/skulls/czanks/`).
- **Gerador de lista** produz **uma `Application` por tenant**, mantendo o
  isolamento já decidido.
- Os patches inline de uma `Application` gerada por `ApplicationSet` aceitam
  `{{ }}` (Go template) vindos direto dos parâmetros do gerador — então
  `slug`, `CORS_URLS`, nome do banco, nome do bucket etc. podem ser
  injetados sem nenhum arquivo por tenant. Onboarding de cliente novo vira
  **uma entrada na lista do próprio `ApplicationSet`**, não uma pasta nova.

Isso também remove de raiz a classe de bug que motivou essa investigação: não
tem como "esquecer" de criar o `Application` do Postgres de um cliente,
porque não existe mais um `Application` de Postgres separado pra esquecer.

**Escopo**: o `ApplicationSet` vale pra tenants futuros. `default`/`skulls`/
`czanks` migram pra ele depois, se fizer sentido — não faz parte deste corte
(mesma lógica da decisão 3: não migrar tenant já em produção junto com a
migração de repo).

## Fora de escopo (deliberado)

- Migrar `default`/`skulls`/`czanks` pro padrão novo (Postgres inline +
  `ApplicationSet`). Ficam exatamente como estão, funcionando, até uma
  decisão separada.
- Trocar a role `viewer` do Infisical por uma role escopada por path (exige
  plano pago — já documentado em `docs/migracao-infisical-per-customer.md`).
- Qualquer mudança na identidade compartilhada `infisical-universal-auth`
  usada pelo `ClusterSecretStore` do czanks (`homelab-gitops` PR #113) — já
  resolvida, não faz parte deste corte.

## Riscos

- **Credencial nova no ArgoCD** (deploy key SSH pro `zuno-tips`) é ponto único
  de falha do cutover: se estiver errada/faltando permissão, `root-app` para
  de sincronizar — mas o cluster continua rodando com o último estado
  aplicado (ArgoCD não remove recursos por falha de leitura de repo, só para
  de detectar mudança). Validar a leitura isolada antes do passo 2 do
  cutover cobre isso.
- **`repoURL` muda de forma**: com deploy key SSH, `repoURL` vira
  `git@github.com:zuno-webapp/zuno-tips.git` (SSH), não mais HTTPS — precisa
  ser essa mesma forma em toda `Application` filha, ArgoCD casa a
  credencial pela URL exata.
- **`repoURL` esquecido em algum arquivo**: como cada `Application` carrega
  o próprio `repoURL`, uma migração de conteúdo incompleta deixaria
  `Application`s filhas ainda lendo do repo pessoal mesmo depois do
  `root-app` já apontar pro novo. Mitigação: grep por
  `github.com/ojasonw/homelab-gitops` no repo novo antes de considerar a
  preparação concluída — tem que dar zero.
- **`zuno-tips` desatualizado**: como é cópia manual de 2026-08-08, tem que
  ser resincronizado com o estado atual do `homelab-gitops` (inclui os PRs
  #113/#114 recentes) antes do conteúdo ser considerado "completo" pro
  cutover.

## Próximo passo

Plano de implementação detalhado via `writing-plans`, cobrindo, nesta ordem:
sincronizar `zuno-tips` com o estado atual + trocar todo `repoURL` +
dissolver o chart Postgres pro molde novo (só na base, sem tocar tenants
existentes) + desenhar o `ApplicationSet` (template + gerador) + credencial
deploy key/Secret + validação isolada + cutover do `root-app` + arquivar
`homelab-gitops`.
