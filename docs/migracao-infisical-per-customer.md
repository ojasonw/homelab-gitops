# Migração Infisical: identidade compartilhada → identidade por cliente

## Contexto

Hoje **todo** `ClusterSecretStore` do cluster `zuno-app` (`infisical-zuno-app-prod`,
`infisical-skull-prod`) e o do `joga-together` (cluster `homolog`, ver
`infra/external-secrets/base/infisical-clustersecretstore.yaml`) autenticam no
Infisical com a **mesma** machine identity, via o Secret
`infisical-universal-auth` (namespace `external-secrets`). O `secretsPath` de
cada store é só um filtro do lado do cliente — não uma fronteira. Quem tiver
acesso a um store consegue, em tese, ler o path de qualquer outro, porque a
credencial por trás é a mesma para todos.

O módulo `infisical-customer` (repo [`zuno-webapp/terraform`][tf], em
`modules/infisical-customer/`) resolve isso para os clientes do stack Zuno:
para cada nome em `local.customers` (`infra/live/prod/main.tf`, hoje
`["default", "skull"]`) ele cria uma pasta dedicada em `/zuno-clients/<cliente>`
e uma machine identity própria. Isso substitui as pastas antigas
`/zuno-app-prod` e `/zuno-app-prod/skulls-prod` — **sem** o sufixo `-prod`,
porque o Infisical já separa prod/dev por `environmentSlug`, não por segmento
de path.

[tf]: https://github.com/zuno-webapp/terraform

### Nome divergente: tenant "zuno-app" vira cliente "default"

O tenant continua se chamando **`zuno-app`** neste repo — diretório
(`infra/tenants/zuno-app/`), namespace, Application do ArgoCD, nada disso
mudou. Mas no Infisical/Terraform ele foi renomeado de `zuno-app` para
**`default`**, porque é o tenant que responde no apex/curinga de
`zunosite.com` — o catch-all multi-tenant legado, não um cliente específico.
`default` é o nome do *cliente* lá; `zuno-app` continua o nome do *tenant*
aqui. Por isso os manifestos dentro de `infra/tenants/zuno-app/` referenciam
`infisical-universal-auth-default`, `/zuno-clients/default` etc. — não é erro
de digitação.

### Sobre a role: `viewer`, não escopada por path

O plano original previa uma role custom por cliente (`permissions_v2` +
`conditions`, restrita ao `secretPath` de cada um). Isso **exige plano pago do
Infisical** — a tentativa real deu `Failed to create custom role due to plan
RBAC restriction`. Por ora (`scoped_role = false`, o default no módulo), cada
identidade usa a role built-in `viewer`, que enxerga **todas** as secrets do
projeto, não só as do próprio cliente.

O que essa migração já resolve mesmo assim: cada cliente tem uma identidade
**própria**, revogável individualmente sem afetar os outros — o Secret
`infisical-universal-auth` compartilhado deixa de ser usado por zuno-app/skull.
O que ainda não resolve: isolamento de **leitura** entre clientes (`viewer`
enxerga o path de qualquer um). Vira `scoped_role = true` quando o plano
permitir; nada mais precisa mudar.

## Status: migração concluída (2026-08-08)

- ✅ **Passo 1** — `terraform apply` rodou, `module.customer["default"]` e
  `module.customer["skull"]` existem no Infisical com identidade e pasta
  próprias.
- ✅ **Passo 2** — os Secrets `infisical-universal-auth-default` e
  `infisical-universal-auth-skull` já existem no cluster (namespace
  `external-secrets`).
- ✅ **Passo 3** — os dois stores novos confirmados `Valid`.
- ✅ **Passo 4** — cutover feito em duas tentativas. A primeira (PR #44) quebrou
  os 6 `ExternalSecret` (`SecretSyncedError: could not get secret data from
  provider`) porque as pastas novas tinham só a estrutura, sem os **valores**
  — revertida no PR #45 assim que detectado (sem impacto nos pods: o
  ExternalSecrets Operator não limpa o Secret de destino quando o sync falha).
  As 9 chaves de cada tenant foram copiadas de `/zuno-app-prod` e
  `/zuno-app-prod/skulls-prod` para as pastas novas, verificadas com a
  identidade *real* de cada cliente, e o cutover refeito com sucesso no PR #46.
- ✅ **Passo 5** — os 6 `ExternalSecret` confirmados `SecretSynced: True` nos
  stores novos; tamanhos dos Secrets de destino conferidos.
- ✅ **Passo 6** — `clustersecretstore.yaml` (antigo) removido dos dois
  overlays. O Secret compartilhado `infisical-universal-auth` **não** foi
  removido — ainda serve o `joga-together`, fora do escopo desta migração.

**Lição para a próxima migração de estrutura de secrets:** o passo de trocar
o `secretStoreRef` só é seguro depois que os *valores* — não só a pasta —
existirem no destino, e depois de verificar leitura com a identidade que vai
ser usada de verdade em produção, não com uma identidade admin.

## Estado final

| | |
|---|---|
| Store em uso | `infisical-default-clients` (zuno-app) / `infisical-skull-clients` (skull) |
| Auth | Secret dedicado `infisical-universal-auth-default` / `-skull`, namespace `external-secrets` |
| `secretsPath` | `/zuno-clients/default` / `/zuno-clients/skull` |
| Role da identidade | `viewer` (built-in, não escopada por path — ver nota acima) |
| `clustersecretstore.yaml` (antigo) | removido dos dois overlays |
| Secret compartilhado `infisical-universal-auth` | **mantido** — ainda serve o `joga-together` |
| Pastas antigas `/zuno-app-prod`, `/zuno-app-prod/skulls-prod` no Infisical | não apagadas pelo Terraform nem por este repo; limpeza manual futura, fora do escopo daqui |

## Runbook (para replicar em outra migração de secretStoreRef)

Os passos, na ordem que se mostrou segura na prática:

1. **Provisionar identidade + pasta no destino** (aqui: `terraform apply` do
   módulo `infisical-customer`).
2. **Aplicar a credencial da identidade no cluster** — Secret bootstrap manual,
   mesmo padrão do token do túnel Cloudflare (`infra/cloudflare-tunnel-zunosite/base/deployment.yaml`):
   ```bash
   kubectl create secret generic infisical-universal-auth-<cliente> \
     -n external-secrets \
     --from-literal=clientId='...' --from-literal=clientSecret='...' \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
   `--dry-run=client -o yaml | kubectl apply` em vez de `kubectl create` puro
   evita gravar a credencial em texto plano na anotação
   `last-applied-configuration`.
3. **Confirmar `Valid`**: `kubectl get clustersecretstore`.
4. **Copiar os VALORES das secrets para o path novo antes de trocar
   `secretStoreRef`.** Este é o passo que faltou na primeira tentativa daqui e
   quebrou produção (ver "O que deu errado" abaixo) — o Terraform só cria a
   pasta, não os valores dentro dela.
5. **Verificar leitura com a identidade REAL do cliente**, não com uma
   identidade admin — a admin lê qualquer coisa e não prova que o cutover vai
   funcionar.
6. **Só então trocar o `secretStoreRef`** em
   `infra/tenants/<tenant>/prod/secretstore-patch.yaml`, validar com
   `kubectl kustomize ... | grep -A2 secretStoreRef` antes de commitar.
7. **Confirmar `SecretSynced: True`** em todos os `ExternalSecret`, e que os
   Secrets de destino têm as chaves esperadas.
8. **Remover o store antigo** só depois do passo 7 confirmado — e o Secret de
   auth compartilhado só quando *todas* as apps que o usam tiverem migrado,
   não apenas as desta migração.

## O que deu errado na primeira tentativa (registro, não repita)

O cutover foi feito primeiro sem o passo 4 acima: `secretStoreRef` trocado
para os stores novos enquanto `/zuno-clients/default` e `/zuno-clients/skull`
tinham só a pasta, sem nenhuma secret dentro. Resultado: os 6 `ExternalSecret`
(3 por tenant) foram para `SecretSyncedError: could not get secret data from
provider` — o `viewer` conseguia autenticar no store, mas não tinha o que ler.

Sem impacto real: o ExternalSecrets Operator não limpa o Secret de destino
quando um sync falha, então os Secrets no cluster mantiveram os valores
antigos e nenhum pod foi afetado. Ainda assim, revertido assim que percebido
(voltar `secretStoreRef` para os stores antigos), os 9 pares chave/valor de
cada tenant foram copiados via API para os paths novos, a leitura verificada
com a identidade real de cada cliente, e só então o cutover refeito.
