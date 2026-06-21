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
| `core-k3s` | k3s standalone | monitoring, n8n, cloudflare-tunnel, joga-together, web-page |
| `homelab-monitoring` | k3s standalone | victoriametrics, grafana |
| `homelab-dev` | k3s standalone | localstack |

## Secrets

External Secrets Operator + Infisical. Cada app com secret tem um `*-externalsecret.yaml` em `infra/<app>/base/` referenciando o `ClusterSecretStore` definido em `infra/external-secrets/base/`.
