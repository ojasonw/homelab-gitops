# zuno-stack

Base única do stack Zuno (backend + frontend). Todo tenant sai daqui.

```
infra/zuno-stack/base/        manifests compartilhados + versões de imagem
infra/tenants/<tenant>/prod/  só o que varia por tenant
```

## Subir uma versão nova

Um lugar só, para todos os tenants:

```
infra/zuno-stack/base/kustomization.yaml   ->  images: newTag
```

O ArgoCD aplica no próximo sync, em `zuno-app` e `skull` de uma vez. Não
existe mais bloco `images:` por tenant.

Se um tenant precisar de um pin diferente (canário, rollback pontual),
declare `images:` no overlay dele. **Case o matcher com o nome que o base
produz, não com o original**: o base faz `newName: ojasonw/zuno-be`, e o
transformer dele roda primeiro — um matcher em `ghcr.io/zuno-webapp/zuno-be`
não encontra mais nada e o pin é ignorado **em silêncio**, sem erro. Veja
`infra/tenants/zuno-app/dev/kustomization.yaml`.

## Por que os nomes dos recursos são genéricos

`backend`, `frontend`, `config`, `secrets`... sem prefixo de tenant. Cada
tenant vive no seu próprio namespace, então não há colisão — e o nginx do
frontend aponta para `http://backend:8081` sem precisar saber de que tenant
se trata. É isso que permite o `nginx-config.yaml` ser um arquivo só.

Duas exceções, ambas por dependência externa ao kustomize:

- **Service do frontend** (`zuno-app-frontend`, `skull-frontend`): o túnel do
  Cloudflare é por token, e o mapeamento hostname → origem vive no Terraform
  (`local.tunnel_routes` em `zuno-webapp/terraform`), fora deste repo.
  Renomear o Service quebra o túnel em silêncio — a rota continua apontando
  para o nome antigo até alguém atualizar o outro lado. Fica em cada overlay,
  onde o tipo também difere (NodePort vs ClusterIP).
- **Secret do postgres** (`zuno-app-postgres`, `skull-postgres`): consumido
  pelo Application separado `postgresql-<tenant>-prod` via
  `auth.existingSecret`. Preservado pelo `postgres-secret-patch.yaml`.

## Adicionar um tenant

Copie `infra/tenants/skull/prod/` e ajuste:

| arquivo | o que muda |
|---|---|
| `kustomization.yaml` | `namespace` |
| `config-patch.yaml` | URL do banco, bucket do Supabase, domínio |
| `frontend-config-patch.yaml` | `API_BASE_URL` |
| `clustersecretstore.yaml` | nome do store e `secretsPath` no Infisical |
| `secretstore-patch.yaml` | nome do store |
| `postgres-secret-patch.yaml` | nome do Secret esperado pelo chart do postgres |
| `frontend-service.yaml` | nome e tipo do Service público |

Depois crie o Application em `nodes/zuno-app/apps/<tenant>.yaml` apontando
para `infra/tenants/<tenant>/prod`.
