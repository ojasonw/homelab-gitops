# Guia SOPS + age — Gerenciamento de Secrets no Homelab

## O que e SOPS?

**SOPS** (Secrets OPerationS) e uma ferramenta da Mozilla que encripta **apenas os valores** de arquivos YAML/JSON/ENV, mantendo as **chaves visiveis**. Isso permite que voce versione secrets no Git sem expor dados sensiveis, e ainda consiga fazer `git diff` e code review normalmente.

**age** e o algoritmo de encriptacao usado pelo SOPS (alternativa moderna ao PGP). Uma chave age e composta por:
- **Public key** (`age1...`): usada para encriptar. Pode ser compartilhada.
- **Private key** (arquivo `keys.txt`): usada para decriptar. **NUNCA commitar.**

---

## Estrutura no projeto

```
~/.config/sops/age/keys.txt    # Chave privada age (FORA do repo)
.sops.yaml                      # Regras de encriptacao (NA RAIZ do repo)
.gitignore                      # Bloqueia keys.txt e *.decrypted.yaml
```

### `.sops.yaml` — Regras de encriptacao

Este arquivo define **quais arquivos** encriptar e **quais campos** dentro deles:

```yaml
creation_rules:
  # Regra 1: qualquer arquivo com "secret" no nome
  - path_regex: '.*secret.*\.yaml$'
    encrypted_regex: '^(data|stringData)$'    # so encripta esses campos
    age: age1fweajqxcxfygfurlpg6r9myu25fcrha0xxtaujwywskkaryewyas8hww9f

  # Regra 2: configmap do alertmanager (tem bot_token do Telegram)
  - path_regex: '.*/alertmanager/.*configmap\.yaml$'
    encrypted_regex: '^(data)$'
    age: age1fweajqxcxfygfurlpg6r9myu25fcrha0xxtaujwywskkaryewyas8hww9f
```

**Como funciona:**
- `path_regex`: SOPS compara o caminho do arquivo com esse regex para decidir qual regra usar
- `encrypted_regex`: dentro do YAML, **so encripta campos que casam com esse regex**
- `age`: public key usada para encriptar

---

## Comandos do dia a dia

### Encriptar um arquivo (primeira vez)

```bash
# Encripta in-place — o arquivo e substituido pela versao encriptada
sops --encrypt --in-place infra/cloudflare-tunnel/base/secret.yaml
```

Antes:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: meu-secret
stringData:
  password: "minha-senha-super-secreta"
```

Depois:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: meu-secret          # <-- metadata continua legivel!
stringData:
  password: ENC[AES256_GCM,data:abc123...,iv:...,tag:...,type:str]
sops:
  age:
    - recipient: age1fweajq...
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
        -----END AGE ENCRYPTED FILE-----
  lastmodified: "2026-02-14T..."
  mac: ENC[AES256_GCM,...]
  version: 3.9.4
```

> Note que `apiVersion`, `kind` e `metadata` continuam em texto plano. So `stringData` foi encriptado, conforme o `encrypted_regex`.

---

### Decriptar um arquivo (ver conteudo original)

```bash
# Mostra o conteudo decriptado no terminal (nao modifica o arquivo)
sops --decrypt infra/cloudflare-tunnel/base/secret.yaml

# Salvar em arquivo separado (para debug, nunca commitar)
sops --decrypt infra/cloudflare-tunnel/base/secret.yaml > /tmp/secret-decrypted.yaml
```

---

### Editar um secret encriptado

```bash
# Abre no $EDITOR (vim/nano), decripta, voce edita, e re-encripta ao salvar
sops infra/cloudflare-tunnel/base/secret.yaml
```

Este e o comando mais usado no dia a dia. O SOPS:
1. Decripta o arquivo em memoria
2. Abre no editor
3. Quando voce salva e fecha, re-encripta automaticamente

> **Dica:** configure `export EDITOR=nano` ou `export EDITOR=vim` no seu `.zshrc`

---

### Re-encriptar apos trocar a chave ou mudar regras

```bash
# Se voce mudou o .sops.yaml (ex: adicionou uma nova chave age)
sops updatekeys infra/cloudflare-tunnel/base/secret.yaml
```

---

## Modos de encriptacao

### Modo 1: Encriptar apenas campos especificos (recomendado para K8s)

E o que usamos no projeto. O `encrypted_regex` no `.sops.yaml` controla quais campos sao encriptados.

```yaml
# .sops.yaml
creation_rules:
  - path_regex: '.*secret.*\.yaml$'
    encrypted_regex: '^(data|stringData)$'    # so encripta data e stringData
    age: age1...
```

**Resultado:** `apiVersion`, `kind`, `metadata`, `type` ficam em texto plano. Apenas os valores dentro de `data` ou `stringData` sao encriptados.

**Quando usar:** Secrets do Kubernetes, ConfigMaps com dados sensiveis.

---

### Modo 2: Encriptar o arquivo inteiro

```bash
# Sem .sops.yaml — encripta TUDO
sops --encrypt --age age1fweajq... arquivo.yaml > arquivo.enc.yaml

# Ou com .sops.yaml sem encrypted_regex:
creation_rules:
  - path_regex: '.*\.env\.yaml$'
    age: age1...
    # sem encrypted_regex = encripta TODOS os valores
```

**Resultado:** todas as chaves ficam visiveis, mas todos os valores sao encriptados.

**Quando usar:** Arquivos onde tudo e sensivel (credenciais de banco, tokens de API).

---

### Modo 3: Encriptar arquivo nao-YAML (dotenv, json, binario)

```bash
# Arquivo .env
sops --encrypt --age age1... .env > .env.encrypted

# JSON
sops --encrypt --age age1... config.json > config.enc.json

# Para binarios, SOPS nao e ideal — use age diretamente:
age --encrypt -r age1... -o arquivo.bin.age arquivo.bin
age --decrypt -i keys.txt -o arquivo.bin arquivo.bin.age
```

---

### Modo 4: Encriptar campos especificos via linha de comando

Se voce nao quer usar `.sops.yaml`, pode especificar na hora:

```bash
# So encripta o campo "stringData"
sops --encrypt --encrypted-regex '^(stringData)$' --age age1... --in-place secret.yaml

# So encripta os campos "password" e "token"
sops --encrypt --encrypted-regex '^(password|token)$' --age age1... --in-place config.yaml
```

---

## Fluxo de trabalho: adicionando um novo secret

### 1. Crie o arquivo YAML normalmente

```yaml
# infra/novo-servico/base/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: novo-secret
  namespace: meu-namespace
type: Opaque
stringData:
  API_KEY: "chave-secreta-aqui"
  DB_PASSWORD: "senha-do-banco"
```

### 2. Encripte com SOPS

```bash
sops --encrypt --in-place infra/novo-servico/base/secret.yaml
```

> O SOPS usa o `.sops.yaml` para saber qual regra aplicar (baseado no caminho do arquivo).

### 3. Crie o KSOPS generator

```yaml
# infra/novo-servico/base/secret-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: novo-secret
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - secret.yaml
```

### 4. Atualize o kustomization.yaml

```yaml
# infra/novo-servico/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
generators:                    # <-- secret sai de resources e vai pra generators
  - secret-generator.yaml
```

### 5. Adicione ao kustomization.yaml raiz (se for componente novo)

```yaml
# kustomization.yaml (raiz)
resources:
  - ...
  - infra/novo-servico/base    # adicionar aqui
```

### 6. Teste localmente

```bash
# Verifica se o kustomize + KSOPS decripta corretamente
kustomize build --enable-alpha-plugins --enable-exec infra/novo-servico/base/
```

### 7. Commit e push

```bash
git add infra/novo-servico/
git commit -m "add: novo-servico com secret encriptado via SOPS"
git push
```

O ArgoCD detecta o push e sincroniza automaticamente.

---

## Fluxo de trabalho: editando um secret existente

```bash
# 1. Edita (decripta -> editor -> re-encripta)
sops infra/cloudflare-tunnel/base/secret.yaml

# 2. Commit e push
git add infra/cloudflare-tunnel/base/secret.yaml
git commit -m "update: rotacionar token do cloudflare tunnel"
git push
```

Pronto. O ArgoCD sincroniza sozinho.

---

## Cuidados importantes

### NUNCA faca isso:

| Erro | Consequencia |
|---|---|
| Commitar `keys.txt` | Qualquer pessoa com a chave decripta tudo |
| Commitar `*.decrypted.yaml` | Secret em texto plano no historico do Git |
| Rodar `sops --decrypt --in-place` e commitar | Substitui o arquivo encriptado pelo texto plano |
| Perder o `keys.txt` sem backup | Nao consegue mais decriptar nenhum secret |

### SEMPRE faca isso:

| Pratica | Motivo |
|---|---|
| Backup do `keys.txt` em local seguro | Unica forma de decriptar os secrets |
| Verificar com `git diff` antes do commit | Confirmar que os valores estao como `ENC[...]` |
| Usar `sops` (sem flags) para editar | Decripta no editor e re-encripta ao salvar |
| Testar com `kustomize build` antes do push | Garante que o KSOPS vai conseguir processar |

### Backup da chave age

A chave privada esta em `~/.config/sops/age/keys.txt`. Se perder esse arquivo, **nao tem como recuperar os secrets**. Faca backup:

```bash
# Ver a chave (para copiar e guardar em local seguro)
cat ~/.config/sops/age/keys.txt

# Copiar para um local seguro (USB, password manager, etc.)
cp ~/.config/sops/age/keys.txt /media/usb/backup-age-key.txt
```

---

## Verificacoes uteis

```bash
# Verificar que nenhum secret esta em texto plano nos YAMLs do repo
grep -r "ENC\[AES256_GCM" . --include="*.yaml" -l
# Deve listar todos os arquivos encriptados

# Verificar que um arquivo especifico esta encriptado
sops filestatus infra/cloudflare-tunnel/base/secret.yaml
# Retorno esperado: o arquivo esta encriptado

# Decriptar e ver sem modificar
sops --decrypt infra/cloudflare-tunnel/base/secret.yaml

# Listar quais chaves age podem decriptar um arquivo
sops --decrypt --extract '["sops"]["age"]' infra/cloudflare-tunnel/base/secret.yaml
```

---

## Referencia rapida

| Acao | Comando |
|---|---|
| Encriptar arquivo novo | `sops --encrypt --in-place arquivo.yaml` |
| Decriptar (ver no terminal) | `sops --decrypt arquivo.yaml` |
| Editar secret encriptado | `sops arquivo.yaml` |
| Re-encriptar (apos mudar chave) | `sops updatekeys arquivo.yaml` |
| Testar build Kustomize | `kustomize build --enable-alpha-plugins --enable-exec <path>/` |
| Ver public key | `grep "public key" ~/.config/sops/age/keys.txt` |

---

## Como funciona no ArgoCD

```
Git push → ArgoCD detecta mudanca → argocd-repo-server executa:
  kustomize build --enable-alpha-plugins --enable-exec .
    → KSOPS intercepta os generators
    → Decripta com a chave age montada no pod (/sops-age secret)
    → Retorna o YAML decriptado para o ArgoCD aplicar no cluster
```

A chave age esta no cluster como Secret `sops-age` no namespace `argocd`, montada no `argocd-repo-server`. Voce nunca precisa decriptar manualmente no cluster — o KSOPS faz isso automaticamente.
