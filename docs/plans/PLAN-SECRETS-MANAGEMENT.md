# Plano: Gerenciamento Seguro de Secrets no Git

## Problema

Os manifestos atuais contem secrets em texto plano (tokens, senhas, API keys) que nao podem ser versionados no GitHub sem exposicao.

**Arquivos afetados:**
- `infra/cloudflare-tunnel/base/secret.yaml` — Tunnel token
- `infra/alertmanager/base/configmap.yaml` — Telegram bot token
- `infra/pve-exporter/base/secret.yaml` — Proxmox API token
- `infra/pihole-exporter/base/secret.yaml` — Pi-hole password
- `apps/n8n/base/secret.yaml` — Encryption key + Postgres password

---

## Opcao 1: SOPS + age (Recomendada)

**O que e:** Ferramenta da Mozilla que encripta apenas os *valores* dentro do YAML, mantendo as chaves visiveis. Usa `age` (substituto moderno do GPG) para criptografia.

**Como funciona:**
```
                  ┌─────────────┐
  secret.yaml ──▶ │  sops encrypt│ ──▶ secret.enc.yaml (Git)
  (texto plano)   │  (age key)   │     (valores encriptados)
                  └─────────────┘
                         │
        kubectl apply ◀──┘ sops decrypt (no deploy)
```

**Exemplo antes/depois:**
```yaml
# ANTES (texto plano - NAO vai pro Git)
stringData:
  token: "eyJhIjoiZjE0MWQ5..."

# DEPOIS (encriptado - seguro no Git)
stringData:
  token: ENC[AES256_GCM,data:abc123...,type:str]
sops:
  age: age1ql3z7hjy54pw3hyww2ayc3e...
  lastmodified: "2026-02-14T12:00:00Z"
```

**Setup no k3s (single-node):**
1. Instalar `sops` e `age` no local
2. Gerar chave: `age-keygen -o keys.txt`
3. Criar `.sops.yaml` na raiz do projeto com regras de encriptacao
4. Encriptar: `sops --encrypt --in-place secret.yaml`
5. No deploy: `sops --decrypt secret.yaml | kubectl apply -f -`

**Pros:**
- Diff legivel no Git (chaves visiveis, so valores encriptados)
- Funciona com qualquer cluster K8s/k3s
- Zero dependencias no cluster (nao precisa de controller)
- Suporte nativo no FluxCD
- Projeto ativo e bem mantido

**Contras:**
- Chave privada (`keys.txt`) precisa ser protegida fora do Git
- Processo manual no deploy (sem controller automatico)
- Se perder a chave, perde acesso aos secrets

**Complexidade:** Baixa
**Repo:** https://github.com/getsops/sops

---

## Opcao 2: Sealed Secrets (Bitnami)

**O que e:** Controller Kubernetes que descriptografa SealedSecrets automaticamente. Voce encripta localmente com a chave publica do controller, e so o controller no cluster consegue descriptografar.

**Como funciona:**
```
                    ┌──────────────┐
  secret.yaml ───▶  │  kubeseal     │ ──▶ sealed-secret.yaml (Git)
  (texto plano)     │  (pub key)    │     (RSA encriptado)
                    └──────────────┘
                           │
  ┌─────────────────────────────────────────┐
  │  Cluster K3s                            │
  │  sealed-secrets-controller              │
  │  (private key) ──▶ descriptografa ──▶   │
  │  cria Secret nativo automaticamente     │
  └─────────────────────────────────────────┘
```

**Setup no k3s:**
1. Deploy do controller:
   ```bash
   kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.0/controller.yaml
   ```
2. Instalar `kubeseal` CLI no local
3. Selar secret:
   ```bash
   kubeseal --format yaml < secret.yaml > sealed-secret.yaml
   ```
4. Aplicar no cluster: `kubectl apply -f sealed-secret.yaml`
5. Controller cria o Secret real automaticamente

**Pros:**
- Setup simples (1 comando pra instalar)
- Automatico — controller descriptografa e cria Secrets sozinho
- Nao precisa gerenciar chaves localmente (chave publica e do cluster)
- Funciona perfeitamente com GitOps (ArgoCD, Flux)

**Contras:**
- Controller roda no cluster (consome recursos ~50MB RAM)
- Se perder o cluster sem backup da chave privada, perde os secrets
- Secrets sao locked por namespace (nao da pra reusar entre namespaces)
- Diff no Git nao e legivel (blob encriptado)

**Complexidade:** Baixa
**Repo:** https://github.com/bitnami-labs/sealed-secrets

---

## Opcao 3: Cloudflare Lockbox

**O que e:** Ferramenta open-source da propria Cloudflare para encriptar Kubernetes Secrets offline. Funciona similar ao Sealed Secrets mas usa criptografia Salsa20 + Poly1305 + Curve25519.

**Como funciona:**
```
                    ┌──────────────┐
  secret.yaml ───▶  │  locket CLI   │ ──▶ lockbox.yaml (Git)
  (texto plano)     │  (pub key)    │     (encriptado)
                    └──────────────┘
                           │
  ┌─────────────────────────────────────────┐
  │  Cluster K3s                            │
  │  lockbox-controller                     │
  │  (private key) ──▶ descriptografa ──▶   │
  │  cria Secret nativo automaticamente     │
  └─────────────────────────────────────────┘
```

**Setup no k3s:**
1. Deploy do controller Lockbox no cluster
2. Instalar CLI `locket` no local
3. Encriptar: `locket lock < secret.yaml > lockbox.yaml`
4. Aplicar: `kubectl apply -f lockbox.yaml`
5. Controller cria o Secret real

**Pros:**
- Feito pela Cloudflare (alinhado com sua stack atual)
- Criptografia moderna (Salsa20/Poly1305/Curve25519)
- Secrets locked por namespace (seguranca extra)
- Open-source

**Contras:**
- Projeto com pouca atividade recente no GitHub
- Comunidade menor que SOPS e Sealed Secrets
- Menos documentacao e tutoriais
- Sem integracao nativa com FluxCD/ArgoCD

**Complexidade:** Baixa-Media
**Repo:** https://github.com/cloudflare/lockbox

---

## Nota sobre Cloudflare Secrets Store

A Cloudflare lancou em 2025 o **Secrets Store** (beta), porem:
- Funciona **apenas com Cloudflare Workers**
- **NAO tem integracao com Kubernetes**
- NAO e suportado pelo External Secrets Operator
- Nao resolve o problema de secrets em manifestos K8s

Por isso nao foi incluido como opcao viavel para este cenario.

---

## Comparativo

| Criterio                    | SOPS + age        | Sealed Secrets     | Cloudflare Lockbox |
|-----------------------------|-------------------|--------------------|--------------------|
| Secrets no Git              | Encriptados       | Encriptados        | Encriptados        |
| Controller no cluster       | Nao               | Sim                | Sim                |
| Diff legivel no Git         | Sim               | Nao                | Nao                |
| Complexidade setup          | Baixa             | Baixa              | Baixa-Media        |
| Comunidade/Suporte          | Grande            | Grande             | Pequena            |
| Integracao FluxCD/ArgoCD    | Nativo            | Nativo             | Manual             |
| Dependencia externa         | Chave age local   | Backup chave ctrl  | Backup chave ctrl  |
| Consumo no cluster          | Zero              | ~50MB RAM          | ~50MB RAM          |
| Manutencao projeto          | Ativo             | Ativo              | Baixa atividade    |

---

## Recomendacao

Para seu cenario (k3s single-node, homelab, GitOps):

**1o lugar: SOPS + age** — Menor overhead, zero recursos extras no cluster, diffs legiveis, e o mais usado pela comunidade GitOps. Ideal para homelab.

**2o lugar: Sealed Secrets** — Se preferir automatizacao total (controller descriptografa sozinho), e a melhor opcao. Muito maduro e confiavel.

**3o lugar: Lockbox** — So faz sentido se quiser manter tudo "Cloudflare". Projeto com pouca atividade recente.

---

## Proximos passos

Apos escolher a opcao:
1. Implementar a solucao escolhida
2. Encriptar todos os 5 arquivos de secrets listados acima
3. Adicionar `.sops.yaml` ou sealed-secret manifests ao repo
4. Criar `.gitignore` para chaves privadas e secrets em texto plano
5. Push seguro para GitHub
