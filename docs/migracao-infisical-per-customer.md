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
`["zuno-app", "skull"]`) ele cria uma pasta dedicada em
`/zuno-clients/<cliente>`, uma machine identity própria, e uma role que só
enxerga aquele path. Isso substitui as pastas antigas `/zuno-app-prod` e
`/zuno-app-prod/skulls-prod` — **sem** o sufixo `-prod`, porque o Infisical já
separa prod/dev por `environmentSlug`, não por segmento de path.

[tf]: https://github.com/zuno-webapp/terraform

## O que já está pronto neste repo

Os `ClusterSecretStore` novos já existem, lado a lado com os antigos:

- `infra/tenants/zuno-app/prod/clustersecretstore-v2.yaml` →
  `infisical-zuno-app-clients`, aponta para `/zuno-clients/zuno-app`
- `infra/tenants/skull/prod/clustersecretstore-v2.yaml` →
  `infisical-skull-clients`, aponta para `/zuno-clients/skull`

Nenhum dos dois é referenciado por nenhum `ExternalSecret` ainda — os
`secretStoreRef` em `infra/tenants/<tenant>/prod/secretstore-patch.yaml`
continuam nos stores antigos (`infisical-zuno-app-prod`,
`infisical-skull-prod`). Os stores novos ficam com status `Invalid` no
`kubectl get clustersecretstore` até o passo 2 abaixo — **isso é esperado**,
os Secrets que eles referenciam ainda não existem no cluster.

O que falta é 100% trabalho do lado Terraform (bloqueado por permissão de
admin no Infisical, fora do escopo deste repo) e um bootstrap manual no
cluster. Este documento é o runbook de quem for destravar isso.

## Passo a passo do cutover

### 1. Rodar `terraform apply` e recuperar as credenciais novas

No repo `zuno-webapp/terraform`, com uma identidade que tenha permissão de
admin no projeto Infisical:

```bash
terraform apply   # aplica o module.customer inteiro, para zuno-app e skull

terraform output -json customer_client_ids
terraform output -json customer_client_secrets
```

Os dois outputs são mapas `{ "zuno-app": "...", "skull": "..." }` — ver
`infra/live/prod/outputs.tf` no repo terraform. O segundo é sensível; não cole
em canais que persistem histórico.

### 2. Criar os Secrets no cluster (bootstrap manual, fora do ArgoCD)

Igual ao Secret `cloudflare-zunosite-tunnel` (ver o comentário em
`infra/cloudflare-tunnel-zunosite/base/deployment.yaml`): estes Secrets **não**
são gerenciados por ExternalSecret nem por Terraform do lado do cluster — é o
Terraform quem gera a credencial, mas alguém precisa aplicá-la a mão. Faz
sentido: um ExternalSecret que buscasse a credencial *da própria* identidade
que ele usa para autenticar seria circular.

```bash
ssh ubuntu@192.168.15.204

kubectl create secret generic infisical-universal-auth-zuno-app \
  -n external-secrets \
  --from-literal=clientId='<customer_client_ids["zuno-app"]>' \
  --from-literal=clientSecret='<customer_client_secrets["zuno-app"]>' \
  --dry-run=client -o yaml | kubectl apply -f - --save-config=false

kubectl create secret generic infisical-universal-auth-skull \
  -n external-secrets \
  --from-literal=clientId='<customer_client_ids["skull"]>' \
  --from-literal=clientSecret='<customer_client_secrets["skull"]>' \
  --dry-run=client -o yaml | kubectl apply -f - --save-config=false
```

O `--dry-run=client -o yaml | kubectl apply --save-config=false` (em vez de
`kubectl create` puro) evita repetir o problema já encontrado no Secret
compartilhado atual: um `kubectl apply` normal com `stringData` grava o
manifesto inteiro — clientId e clientSecret em texto plano — na anotação
`last-applied-configuration`, legível por qualquer um que possa ler Secrets
no namespace, sem precisar decodificar base64. Esse fluxo não escreve essa
anotação.

### 3. Confirmar que os stores novos ficam `Valid`

```bash
kubectl get clustersecretstore
```

`infisical-zuno-app-clients` e `infisical-skull-clients` devem sair de
`Invalid`/sem status para `Valid` assim que o External Secrets Operator
conseguir autenticar com a credencial nova. Se continuarem inválidos, o
problema está na credencial (passo 2) ou na role/permissão criada pelo
Terraform (`infisical_project_role` em `modules/infisical-customer/main.tf`)
— confira o `describe` do store para o motivo exato.

### 4. Trocar o `secretStoreRef` de cada tenant

Em `infra/tenants/zuno-app/prod/secretstore-patch.yaml`, trocar:

```yaml
spec:
  secretStoreRef:
    name: infisical-zuno-app-prod   # -> infisical-zuno-app-clients
```

E o equivalente em `infra/tenants/skull/prod/secretstore-patch.yaml`
(`infisical-skull-prod` → `infisical-skull-clients`). Isso repassa os três
`ExternalSecret` do base (`secrets`, `postgres-secret`, `imagepullsecret` —
ver `infra/zuno-stack/base/kustomization.yaml`) de uma vez, via o seletor por
`kind` já existente no `kustomization.yaml` do overlay.

Se preferir uma transição mais gradual em vez de trocar os três de uma vez —　
por exemplo, um `ExternalSecret` duplicado temporário apontando para o store
novo, rodando em paralelo com o antigo, para comparar os valores antes de
cortar o antigo — é uma opção válida, mas **não foi aplicada aqui**: fica a
critério de quem for rodar o cutover, e exigiria um manifesto extra (o
`externalsecret.yaml` do base não pode ter dois `secretStoreRef` ao mesmo
tempo, então seria necessário um overlay adicional só para o período de
transição).

Depois de editar, valide antes de commitar:

```bash
kubectl kustomize infra/tenants/zuno-app/prod | grep -A2 secretStoreRef
kubectl kustomize infra/tenants/skull/prod    | grep -A2 secretStoreRef
```

### 5. Confirmar `SecretSynced: True`

```bash
kubectl get externalsecret -n zuno-app
kubectl get externalsecret -n zuno-skull
```

Confira também que os valores realmente chegaram nos Secrets de destino
(`secrets`, `postgres-secret`, `imagepullsecret`) — um `SecretSynced: True`
com uma chave faltando ainda quebra o pod em runtime, só que mais tarde.

Só depois disso os pods de `zuno-app`/`zuno-skull` devem ser reiniciados (ou
aguardar o próximo restart natural) para pegarem os valores atualizados, já
que os Secrets do ExternalSecrets Operator não fazem live-reload em pods já
rodando.

### 6. Remover os stores antigos e o Secret compartilhado — só quando TUDO tiver migrado

Depois que o passo 5 estiver confirmado para **zuno-app e skull**:

- Apagar `infra/tenants/zuno-app/prod/clustersecretstore.yaml` e a entrada
  correspondente em `kustomization.yaml` (idem para skull)
- **Não apagar ainda** o Secret `infisical-universal-auth` (namespace
  `external-secrets`) nem a identidade compartilhada no Infisical. Esse
  Secret também é usado pelo `ClusterSecretStore` do `joga-together`
  (`infra/external-secrets/base/infisical-clustersecretstore.yaml`, stores
  `infisical-prod`/`infisical-dev`) — um app completamente fora do escopo
  desta migração. Só remova a identidade compartilhada quando **todas** as
  apps do cluster tiverem sua própria identidade dedicada, não só
  zuno-app/skull.

## Coexistência durante a migração

| | Store antigo | Store novo |
|---|---|---|
| Nome | `infisical-zuno-app-prod` / `infisical-skull-prod` | `infisical-zuno-app-clients` / `infisical-skull-clients` |
| Auth | Secret compartilhado `infisical-universal-auth` | Secret dedicado `infisical-universal-auth-<cliente>` |
| `secretsPath` | `/zuno-app-prod` / `/zuno-app-prod/skulls-prod` | `/zuno-clients/zuno-app` / `/zuno-clients/skull` |
| Usado por `ExternalSecret`? | Sim, até o passo 4 | Só depois do passo 4 |

Os dois conjuntos de pastas no Infisical existem em paralelo até o passo 6 —
o Terraform não apaga `/zuno-app-prod` sozinho, e este repo também não deleta
os stores antigos antes da hora.
