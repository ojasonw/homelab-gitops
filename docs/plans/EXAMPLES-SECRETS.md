# Exemplos Praticos: Secrets Management

Usando o secret `cloudflare-tunnel-token` como base para os 3 exemplos.

**Arquivo original (NUNCA commitar isso no Git):**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-tunnel-token
  namespace: cloudflare
type: Opaque
stringData:
  token: "eyJhIjoiZjE0MWQ5MjkyOTlmODAxZmY3MjRi..."
```

---

## Exemplo 1: SOPS + age

### Setup (uma vez)

```bash
# 1. Instalar sops e age
sudo apt install age
curl -LO https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64
sudo mv sops-v3.9.4.linux.amd64 /usr/local/bin/sops && sudo chmod +x /usr/local/bin/sops

# 2. Gerar chave age
age-keygen -o ~/.config/sops/age/keys.txt
# Saida:
#   Public key: age1ql3z7hjy54pw3hyww2ayc3ehlm0ywpmrzg3p4m5lpca5jlnpx9ysjdgh3y

# 3. Criar .sops.yaml na raiz do projeto
cat > .sops.yaml << 'EOF'
creation_rules:
  - path_regex: .*secret.*\.yaml$
    encrypted_regex: ^(stringData|data)$
    age: age1ql3z7hjy54pw3hyww2ayc3ehlm0ywpmrzg3p4m5lpca5jlnpx9ysjdgh3y
EOF
```

### Uso diario

```bash
# Encriptar o secret (in-place)
sops --encrypt --in-place infra/cloudflare-tunnel/base/secret.yaml
```

### Resultado no Git (seguro para commitar)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-tunnel-token        # <-- chaves visiveis!
  namespace: cloudflare                 # <-- estrutura legivel!
type: Opaque
stringData:
  token: ENC[AES256_GCM,data:kW3gR7pN2mX9vLqY8hBnTfDc6jA5wZsE4uHiOoMr1bCeJxKv0dPaF+lSg==,iv:abc123,tag:def456,type:str]
sops:
  kms: []
  gcp_kms: []
  azure_kv: []
  hc_vault: []
  age:
    - recipient: age1ql3z7hjy54pw3hyww2ayc3ehlm0ywpmrzg3p4m5lpca5jlnpx9ysjdgh3y
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSB...
        -----END AGE ENCRYPTED FILE-----
  lastmodified: "2026-02-14T15:30:00Z"
  mac: ENC[AES256_GCM,data:...,type:str]
  version: 3.9.4
```

### Deploy

```bash
# Descriptografar e aplicar direto
sops --decrypt infra/cloudflare-tunnel/base/secret.yaml | kubectl apply -f -

# Ou descriptografar pra editar
sops infra/cloudflare-tunnel/base/secret.yaml
# (abre no $EDITOR com valores em texto plano, re-encripta ao salvar)
```

### Git diff (legivel!)

```diff
  stringData:
-   token: ENC[AES256_GCM,data:kW3gR7pN2mX9vLqY8h...,type:str]
+   token: ENC[AES256_GCM,data:xZ9aB3cD4eF5gH6iJ...,type:str]
  sops:
-   lastmodified: "2026-02-14T15:30:00Z"
+   lastmodified: "2026-02-14T16:00:00Z"
```

Voce sabe que o `token` mudou, mas nao ve o valor real.

---

## Exemplo 2: Sealed Secrets (Bitnami)

### Setup (uma vez)

```bash
# 1. Instalar controller no cluster
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.0/controller.yaml

# 2. Instalar kubeseal no local
curl -LO https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.0/kubeseal-0.27.0-linux-amd64.tar.gz
tar xfz kubeseal-0.27.0-linux-amd64.tar.gz
sudo mv kubeseal /usr/local/bin/

# 3. Backup da chave privada do controller (IMPORTANTE!)
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-master-key.yaml
# Guardar este arquivo em local seguro, FORA do Git
```

### Uso diario

```bash
# Selar o secret (gera novo arquivo)
kubeseal --format yaml < infra/cloudflare-tunnel/base/secret.yaml > infra/cloudflare-tunnel/base/sealed-secret.yaml
```

### Resultado no Git (seguro para commitar)

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: cloudflare-tunnel-token
  namespace: cloudflare
spec:
  encryptedData:
    token: AgBy3i4OJSWK+PiTySYZZA9rO43cGDEq6bN7gJmPZBkLh5B1xHNcPGT3
      dMYFGQiXGqElByA0WG5cIJrE8MlKmEf7JVZqo3m8kCkLd5OKHLRx2kAV
      G7KhVlZoRTSNdPAGSnXPXV9VjEqUmPGc9MfVc7QqpXGUNLGJRNGbsTsGr
      KqD7Jgg6p/HEfHBbTnPZMx2EROwLkE7JnM8xjGQ5IqB7VjG5BkDFVG2x
      Y3Ff5dTWEF6NrPkZZ1LAqG3V7nLEW6qX+Qp6lMGTsDV+eKdpCF5qHwAG
      bKZmG7l3F... (blob RSA 4096-bit)
  template:
    metadata:
      name: cloudflare-tunnel-token
      namespace: cloudflare
    type: Opaque
```

### Deploy

```bash
# Aplicar o SealedSecret — controller cria o Secret real automaticamente
kubectl apply -f infra/cloudflare-tunnel/base/sealed-secret.yaml

# Verificar que o Secret foi criado
kubectl get secret cloudflare-tunnel-token -n cloudflare
# NAME                      TYPE     DATA   AGE
# cloudflare-tunnel-token   Opaque   1      5s
```

### Estrutura de arquivos

```
infra/cloudflare-tunnel/base/
├── secret.yaml          # texto plano — NO .gitignore, nunca commitar
├── sealed-secret.yaml   # encriptado — seguro no Git
├── deployment.yaml
├── namespace.yaml
└── kustomization.yaml   # referencia sealed-secret.yaml ao inves de secret.yaml
```

### Git diff (NAO legivel)

```diff
  encryptedData:
-   token: AgBy3i4OJSWK+PiTySYZZA9rO43cGDEq6bN7gJmPZ...
+   token: BhCz4j5PKTWL+QjUzTZAAB0sP54dHEFr7cO8hKnQaC...
```

Blob completamente diferente — nao da pra saber o que mudou.

---

## Exemplo 3: Cloudflare Lockbox

### Setup (uma vez)

```bash
# 1. Instalar controller no cluster
kubectl apply -f https://github.com/cloudflare/lockbox/releases/latest/download/install.yaml

# 2. Instalar locket CLI no local
curl -LO https://github.com/cloudflare/lockbox/releases/latest/download/locket-linux-amd64
sudo mv locket-linux-amd64 /usr/local/bin/locket && sudo chmod +x /usr/local/bin/locket

# 3. Obter chave publica do controller
kubectl get lockbox -n lockbox-system -o jsonpath='{.items[0].spec.peer}'
# Saida: mDlKqjHbQz8v2nX5pY1wR4tG7uA0cE3fI6hL9oS+xN=

# 4. Backup da chave privada
kubectl get secret -n lockbox-system lockbox-keypair -o yaml > lockbox-master-key.yaml
# Guardar fora do Git
```

### Uso diario

```bash
# Encriptar usando a chave publica do controller
locket lock \
  --namespace cloudflare \
  --name cloudflare-tunnel-token \
  --peer mDlKqjHbQz8v2nX5pY1wR4tG7uA0cE3fI6hL9oS+xN= \
  < infra/cloudflare-tunnel/base/secret.yaml \
  > infra/cloudflare-tunnel/base/lockbox.yaml
```

### Resultado no Git (seguro para commitar)

```yaml
apiVersion: lockbox.k8s.cloudflare.com/v1
kind: Lockbox
metadata:
  name: cloudflare-tunnel-token
  namespace: cloudflare
spec:
  sender: 7pR2mX9vLqY8hBnTfDc6jA5wZsE4uHiOoMr1bCeJ=
  peer: mDlKqjHbQz8v2nX5pY1wR4tG7uA0cE3fI6hL9oS+xN=
  data:
    - name: token
      value: bG9ja2JveC1lbmNyeXB0ZWQtZGF0YS12MS4wLjAKLS0t
        CnNlbmRlcjogN3BSMm1YOXZMcVk4aEJuVGZEYzZqQTU
        d1pzRTR1SGlPb01yMWJDZUo9CnBlZXI6IG1EbEtxakhiUX
        o4djJuWDVwWTF3UjR0Rzd1QTBjRTNmSTZoTDlvUyt4Tj0
        ... (Salsa20+Poly1305 encriptado)
  template:
    type: Opaque
```

### Deploy

```bash
# Aplicar o Lockbox — controller cria o Secret real automaticamente
kubectl apply -f infra/cloudflare-tunnel/base/lockbox.yaml

# Verificar
kubectl get secret cloudflare-tunnel-token -n cloudflare
# NAME                      TYPE     DATA   AGE
# cloudflare-tunnel-token   Opaque   1      3s
```

### Detalhe: secrets locked por namespace

O Lockbox encripta o secret vinculado ao namespace `cloudflare`. Se alguem mover o arquivo para outro namespace, o controller recusa a descriptografia. Seguranca extra.

---

## Resumo Visual

```
┌─────────────────────────────────────────────────────────────────┐
│                        SEU COMPUTADOR                           │
│                                                                 │
│  secret.yaml ─────┬──▶ sops encrypt ──▶ secret.yaml (encript.) │
│  (texto plano)    │                      Opcao 1: SOPS          │
│                   │                                              │
│  .gitignore ◀─────┤──▶ kubeseal ──────▶ sealed-secret.yaml     │
│  (nunca commitar) │                      Opcao 2: Sealed        │
│                   │                                              │
│                   └──▶ locket lock ───▶ lockbox.yaml            │
│                                          Opcao 3: Lockbox       │
└─────────────┬───────────────────────────────────────────────────┘
              │ git push (apenas arquivos encriptados)
              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         GITHUB                                  │
│  Valores encriptados — seguros mesmo em repo publico            │
└─────────────┬───────────────────────────────────────────────────┘
              │ git pull / kubectl apply
              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      CLUSTER K3S                                │
│                                                                 │
│  SOPS:    sops decrypt | kubectl apply (manual no deploy)       │
│  Sealed:  controller descriptografa automaticamente             │
│  Lockbox: controller descriptografa automaticamente             │
│                                                                 │
│  Resultado final: Secret nativo do Kubernetes                   │
│  kubectl get secret cloudflare-tunnel-token -n cloudflare       │
└─────────────────────────────────────────────────────────────────┘
```

---

## .gitignore necessario (para qualquer opcao)

```gitignore
# Chaves privadas
*.key
keys.txt
*-master-key.yaml

# Secrets em texto plano (manter apenas os encriptados)
# Descomentar a linha abaixo se usar SOPS (que encripta in-place):
# (nao precisa, o arquivo ja esta encriptado)

# Para Sealed Secrets e Lockbox, ignorar os originais:
# infra/*/base/secret.yaml
# apps/*/base/secret.yaml
```
