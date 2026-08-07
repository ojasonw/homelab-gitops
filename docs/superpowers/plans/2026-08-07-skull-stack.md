# Skull Stack (new isolated customer on skull.zunosite.com) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a second, fully isolated deployment of the zuno-be/zuno-frontend stack (own namespace, own Postgres, own secrets) for a new customer, reachable at `https://skull.zunosite.com`, without disturbing the existing zuno-app deployment or its `*.zunosite.com` wildcard tenants.

**Architecture:** Near-exact duplicate of `infra/zuno-app` (same images, same Deployment/Service/ConfigMap/ExternalSecret shapes), parameterized under a new `infra/skull` path and `skull` namespace. `skull-frontend` stays **ClusterIP** (no NodePort) — the dedicated `zunosite` cloudflared connector runs in-cluster on this same box, so it reaches the Service directly via in-cluster DNS, no LAN hop needed (unlike zuno-app-frontend's pre-existing NodePort, which dates from before that dedicated tunnel existed). Exposed via a **specific** Cloudflare Tunnel ingress rule (`skull.zunosite.com`) placed above the existing `*.zunosite.com` wildcard rule in the same dedicated `zunosite` tunnel — first-match-wins means skull's traffic never falls through to zuno-app's frontend. `APP_TENANT_BASE_DOMAIN` stays `zunosite.com` (same as zuno-app) so `TenantResolver` correctly extracts slug `skull` from the `Host` header — the barber account created inside skull's own database must have `username: "skull"` for the public booking flow to resolve.

**Tech Stack:** Kustomize, ArgoCD (app-of-apps via `nodes/zuno-app/apps/`), External Secrets Operator + Infisical, the local `infra/postgresql/chart` Postgres chart, Cloudflare Tunnel API.

## Global Constraints

- `skull-frontend` and `skull-backend` are **ClusterIP only** — no NodePort. The tunnel connector reaches them via in-cluster DNS (`skull-frontend.skull.svc.cluster.local`).
- Namespace: `skull` (new, separate from `zuno-app`).
- Images: same repo as zuno-app, `ghcr.io/zuno-webapp/zuno-be` / `ghcr.io/zuno-webapp/zuno-frontend`, starting at the same tags currently live in zuno-app prod (`v0.0.5` backend / `b6fb64899c8afff9fae34065bb699f0ec2a1f5a4` frontend) — bump independently later.
- Infisical: same project (`externalsecrets-i-rq2`), same environment slug (`prod`), **new** secrets path `/zuno-app-prod/skulls-prod` (nested under the existing `zuno-app-prod` folder, per your setup — not a sibling top-level path).
- Supabase: same project (same `SUPABASE_URL`), but a **new dedicated bucket** `skull-bucket` (private, mirrors `zuno-bucket`'s settings) — see Task 5 for exact steps. `SUPABASE_KEY` (the project's service key) is reused as-is; only `SUPABASE_BUCKET` changes.
- `APP_TENANT_BASE_DOMAIN` = `zunosite.com` (not a skull-specific domain) — required for `TenantResolver` to resolve the `skull` slug.
- `CORS_URLS` for skull = exact match `https://skull.zunosite.com` only — no wildcard.
- Cloudflare Tunnel used: the dedicated `zunosite` tunnel already created (ID `0e243e71-f43e-45e3-bab8-b3c855ad508e`), not the shared homelab tunnel and not a new tunnel.
- No DNS change needed — `*.zunosite.com` wildcard CNAME already resolves `skull.zunosite.com`; Cloudflare's universal cert already covers it.
- **Known gap, not fixed by this plan:** every `ClusterSecretStore` in this cluster (zuno-app's, skull's, joga-together's) authenticates to Infisical using the *same* `infisical-universal-auth` Identity. The per-store `secretsPath` is a query filter on the client side, not a security boundary — if that Identity's Infisical-side policy grants broad project access (worth checking), a compromised store can read every app's secrets, not just its own. See the note at the end of this plan.

---

### Task 1: Postgres for skull

**Files:**
- Create: `infra/postgresql/skull-prod/values.yaml`
- Create: `nodes/zuno-app/apps/postgresql-skull.yaml`

**Interfaces:**
- Produces: a `postgresql-skull-prod` Service (chart-managed, standard Helm release-name-prefixed naming, same as `postgresql-zuno-app-prod`) and a `skull-postgres` Secret (created by Task 2's ExternalSecret) that this release's `auth.existingSecret` will reference.

- [ ] **Step 1: Create the postgres values file**

`infra/postgresql/skull-prod/values.yaml`:
```yaml
auth:
  # Password comes from the skull-postgres Secret (ExternalSecret →
  # Infisical /zuno-app-prod/skulls-prod/POSTGRES_PASSWORD), not plaintext here.
  existingSecret: skull-postgres
  database: skull-db

primary:
  replicaCount: 1

persistence:
  enabled: true
  storageClass: custom-local-path
  size: 8Gi
```

- [ ] **Step 2: Create the ArgoCD Application for skull's postgres**

`nodes/zuno-app/apps/postgresql-skull.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgresql-skull-prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://github.com/ojasonw/homelab-gitops.git
      targetRevision: main
      ref: valuesRepo
    - repoURL: https://github.com/ojasonw/homelab-gitops.git
      targetRevision: main
      path: infra/postgresql/chart
      helm:
        releaseName: postgresql-skull-prod
        valueFiles:
          - $valuesRepo/infra/postgresql/skull-prod/values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: skull
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 3: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('infra/postgresql/skull-prod/values.yaml'))" && python3 -c "import yaml; yaml.safe_load(open('nodes/zuno-app/apps/postgresql-skull.yaml'))"`
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add infra/postgresql/skull-prod/values.yaml nodes/zuno-app/apps/postgresql-skull.yaml
git commit -m "feat(skull): add dedicated postgres release for the skull stack"
```

---

### Task 2: Base manifests for skull (mirrors infra/zuno-app/base)

**Files:**
- Create: `infra/skull/base/deployment.yaml`
- Create: `infra/skull/base/service.yaml`
- Create: `infra/skull/base/nginx-config.yaml`
- Create: `infra/skull/base/configmap.yaml`
- Create: `infra/skull/base/frontend-configmap.yaml`
- Create: `infra/skull/base/externalsecret.yaml`
- Create: `infra/skull/base/imagepullsecret.yaml`
- Create: `infra/skull/base/postgres-secret.yaml`
- Create: `infra/skull/base/kustomization.yaml`

**Interfaces:**
- Consumes: `postgresql-skull-prod` Service name from Task 1 (used in `SPRING_DATASOURCE_URL`).
- Produces: `skull-backend` / `skull-frontend` Deployments+Services, `skull-config` / `skull-frontend-config` ConfigMaps, `skull-secrets` / `skull-registry` / `skull-postgres` Secrets (via ExternalSecret) — all consumed by Task 3's overlay patches.

- [ ] **Step 1: Deployment**

`infra/skull/base/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: skull-backend
spec:
  selector:
    matchLabels:
      app: skull-backend
  template:
    metadata:
      labels:
        app: skull-backend
    spec:
      imagePullSecrets:
        - name: skull-ghcr-secret
      containers:
      - name: skull-backend
        image: ghcr.io/zuno-webapp/zuno-be:latest
        ports:
        - containerPort: 8081
        envFrom:
        - configMapRef:
            name: skull-config
        - secretRef:
            name: skull-secrets
        readinessProbe:
          tcpSocket:
            port: 8081
          initialDelaySeconds: 15
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: 8081
          initialDelaySeconds: 30
          periodSeconds: 20
        resources:
          requests:
            cpu: 100m
            memory: 384Mi
          limits:
            cpu: 500m
            memory: 512Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: skull-frontend
spec:
  selector:
    matchLabels:
      app: skull-frontend
  template:
    metadata:
      labels:
        app: skull-frontend
    spec:
      imagePullSecrets:
        - name: skull-ghcr-secret
      containers:
      - name: skull-frontend
        image: ghcr.io/zuno-webapp/zuno-frontend:latest
        envFrom:
        - configMapRef:
            name: skull-frontend-config
        ports:
        - containerPort: 80
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
        livenessProbe:
          httpGet:
            path: /healthz
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 15
        readinessProbe:
          httpGet:
            path: /healthz
            port: 80
          initialDelaySeconds: 3
          periodSeconds: 10
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
      volumes:
      - name: nginx-config
        configMap:
          name: nginx-config
```

- [ ] **Step 2: Services**

`infra/skull/base/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: skull-backend
spec:
  selector:
    app: skull-backend
  ports:
    - protocol: TCP
      port: 8081
      targetPort: 8081
  type: ClusterIP
---
apiVersion: v1
kind: Service
metadata:
  name: skull-frontend
spec:
  selector:
    app: skull-frontend
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  type: ClusterIP
```

- [ ] **Step 3: Nginx config (identical to zuno-app's, proxies to skull-backend)**

`infra/skull/base/nginx-config.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
data:
  default.conf: |
    server {
        listen 80;
        server_name _;
        root /usr/share/nginx/html;
        index index.html;

        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;

        location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires 30d;
            add_header Cache-Control "public, immutable";
        }

        location = /config.js {
            add_header Cache-Control "no-store";
            add_header Content-Type "application/javascript";
        }

        location /healthz {
            access_log off;
            return 200 "ok";
            add_header Content-Type text/plain;
        }

        location /api/ {
            proxy_pass http://skull-backend:8081/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location / {
            try_files $uri $uri/ /index.html;
        }
    }
```

- [ ] **Step 4: Backend ConfigMap**

`infra/skull/base/configmap.yaml`:
```yaml
# Non-sensitive backend config for the skull stack. Credentials live in
# Infisical (see externalsecret.yaml / postgres-secret.yaml).
apiVersion: v1
kind: ConfigMap
metadata:
  name: skull-config
data:
  SPRING_DATASOURCE_URL: "jdbc:postgresql://postgresql-skull-prod:5432/skull-db"
  SPRING_DATASOURCE_USERNAME: "postgres"
  SUPABASE_URL: "https://ycpxtencdkkwxzdihpqr.supabase.co"
  SUPABASE_BUCKET: "zuno-bucket"
  FRONTEND_RESET_PASSWORD_URL: "https://skull.zunosite.com/admin/redefinir-senha"
  # Same base domain as zuno-app, not a skull-specific one — TenantResolver
  # strips ".zunosite.com" off the Host header regardless of which
  # deployment answers the request. Skull's own Barber account must use
  # username "skull" for the public booking flow to resolve.
  APP_TENANT_BASE_DOMAIN: "zunosite.com"
```

- [ ] **Step 5: Frontend ConfigMap**

`infra/skull/base/frontend-configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: skull-frontend-config
data:
  API_BASE_URL: "https://skull.zunosite.com/api"
```

- [ ] **Step 6: Backend secrets ExternalSecret**

`infra/skull/base/externalsecret.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: skull-secrets
spec:
  refreshInterval: 8h
  secretStoreRef:
    kind: ClusterSecretStore
    name: infisical-skull-prod
  target:
    name: skull-secrets
    creationPolicy: Owner
  data:
    - secretKey: SPRING_DATASOURCE_PASSWORD
      remoteRef:
        key: POSTGRES_PASSWORD
    - secretKey: SPRING_JWT_SECRET
      remoteRef:
        key: SPRING_JWT_SECRET
    - secretKey: EMAIL_USERNAME
      remoteRef:
        key: EMAIL_USERNAME
    - secretKey: EMAIL_PASSWORD
      remoteRef:
        key: EMAIL_PASSWORD
    - secretKey: SUPABASE_KEY
      remoteRef:
        key: SUPABASE_KEY
    - secretKey: CORS_URLS
      remoteRef:
        key: CORS_URLS
```

- [ ] **Step 7: GHCR image pull secret**

`infra/skull/base/imagepullsecret.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: skull-registry
spec:
  refreshInterval: 8h
  secretStoreRef:
    kind: ClusterSecretStore
    name: infisical-skull-prod
  target:
    name: skull-ghcr-secret
    creationPolicy: Owner
    template:
      type: kubernetes.io/dockerconfigjson
      data:
        .dockerconfigjson: >-
          {"auths":{"https://ghcr.io":{"username":"{{ .GHCR_USERNAME }}","password":"{{ .GHCR_TOKEN }}","auth":"{{ printf "%s:%s" .GHCR_USERNAME .GHCR_TOKEN | b64enc }}"}}}
  data:
    - secretKey: GHCR_USERNAME
      remoteRef:
        key: GHCR_USERNAME
    - secretKey: GHCR_TOKEN
      remoteRef:
        key: GHCR_TOKEN
```

- [ ] **Step 8: Postgres password ExternalSecret**

`infra/skull/base/postgres-secret.yaml`:
```yaml
# Feeds infra/postgresql/chart via `auth.existingSecret: skull-postgres`.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: skull-postgres
spec:
  refreshInterval: 8h
  secretStoreRef:
    kind: ClusterSecretStore
    name: infisical-skull-prod
  target:
    name: skull-postgres
    creationPolicy: Owner
  data:
    - secretKey: postgres-password
      remoteRef:
        key: POSTGRES_PASSWORD
```

- [ ] **Step 9: Base kustomization**

`infra/skull/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - nginx-config.yaml
  - configmap.yaml
  - frontend-configmap.yaml
  - externalsecret.yaml
  - imagepullsecret.yaml
  - postgres-secret.yaml
images:
  - name: ghcr.io/zuno-webapp/zuno-frontend
    newTag: latest
  - name: ghcr.io/zuno-webapp/zuno-be
    newTag: latest
```

- [ ] **Step 10: Validate the base builds**

Run: `kubectl kustomize infra/skull/base`
Expected: renders all 10 resources with no errors (backend/frontend Deployments, 2 Services, nginx-config, 2 ConfigMaps, 3 ExternalSecrets).

- [ ] **Step 11: Commit**

```bash
git add infra/skull/base/
git commit -m "feat(skull): add base manifests mirroring infra/zuno-app"
```

---

### Task 3: Prod overlay for skull

**Files:**
- Create: `infra/skull/overlays/prod/kustomization.yaml`
- Create: `infra/skull/overlays/prod/clustersecretstore.yaml`
- Create: `infra/skull/overlays/prod/backend-resources-patch.yaml`
- Create: `infra/skull/overlays/prod/frontend-resources-patch.yaml`

**Interfaces:**
- Consumes: `infra/skull/base` (Task 2).
- Produces: fully-rendered `skull` namespace manifests, ready for the ArgoCD Application in Task 4.

- [ ] **Step 1: ClusterSecretStore for skull**

`infra/skull/overlays/prod/clustersecretstore.yaml`:
```yaml
# Cluster-scoped but kept per-overlay, same reasoning as zuno-app's: an
# Infisical path/auth problem here can't degrade zuno-app's Application
# health, and vice versa.
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: infisical-skull-prod
spec:
  provider:
    infisical:
      hostAPI: https://us.infisical.com
      auth:
        universalAuthCredentials:
          clientId:
            name: infisical-universal-auth
            namespace: external-secrets
            key: clientId
          clientSecret:
            name: infisical-universal-auth
            namespace: external-secrets
            key: clientSecret
      secretsScope:
        projectSlug: "externalsecrets-i-rq2"
        environmentSlug: "prod"
        secretsPath: "/zuno-app-prod/skulls-prod"
```

- [ ] **Step 2: Resource patches**

`infra/skull/overlays/prod/backend-resources-patch.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: skull-backend
spec:
  template:
    spec:
      containers:
      - name: skull-backend
        resources:
          requests:
            cpu: 100m
            memory: 384Mi
          limits:
            cpu: 500m
            memory: 512Mi
```

`infra/skull/overlays/prod/frontend-resources-patch.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: skull-frontend
spec:
  template:
    spec:
      containers:
      - name: skull-frontend
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
```

- [ ] **Step 3: Overlay kustomization**

`infra/skull/overlays/prod/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: skull

resources:
  - ../../base
  - clustersecretstore.yaml

images:
  - name: ghcr.io/zuno-webapp/zuno-be
    newName: ojasonw/zuno-be
    newTag: v0.0.5
  - name: ghcr.io/zuno-webapp/zuno-frontend
    newTag: b6fb64899c8afff9fae34065bb699f0ec2a1f5a4

replicas:
  - name: skull-backend
    count: 1
  - name: skull-frontend
    count: 1

patches:
  - path: backend-resources-patch.yaml
    target:
      kind: Deployment
      name: skull-backend
  - path: frontend-resources-patch.yaml
    target:
      kind: Deployment
      name: skull-frontend
```

- [ ] **Step 4: Validate the overlay builds**

Run: `kubectl kustomize infra/skull/overlays/prod`
Expected: renders cleanly, `skull-frontend` Service stays `type: ClusterIP` (no NodePort), all object names carry the `skull` namespace.

- [ ] **Step 5: Commit**

```bash
git add infra/skull/overlays/prod/
git commit -m "feat(skull): add prod overlay (ClusterIP, infisical-skull-prod)"
```

---

### Task 4: ArgoCD Application for skull

**Files:**
- Create: `nodes/zuno-app/apps/skull.yaml`

**Interfaces:**
- Consumes: `infra/skull/overlays/prod` (Task 3).

- [ ] **Step 1: Create the Application manifest**

`nodes/zuno-app/apps/skull.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: skull
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/ojasonw/homelab-gitops.git
    targetRevision: main
    path: infra/skull/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: skull
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('nodes/zuno-app/apps/skull.yaml'))"`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add nodes/zuno-app/apps/skull.yaml
git commit -m "feat(skull): register ArgoCD Application"
```

---

### Task 5: Manual prerequisite — Supabase bucket + Infisical secrets (blocks Tasks 1–4 from going healthy)

Not a file change — one-time manual steps in Supabase and Infisical. Without the Infisical secrets, the ExternalSecrets from Task 2 will report `SecretSyncedError` and no pod will start.

**Supabase — new bucket for skull, isolated from zuno-app's uploads:**

- [ ] **Step 1:** Supabase Dashboard → your existing project (the one behind `SUPABASE_URL`, `ycpxtencdkkwxzdihpqr`) → Storage → **New bucket**.
- [ ] **Step 2:** Name it `skull-bucket` (mirrors `zuno-bucket`'s naming). Set **Public: OFF** — same as `zuno-bucket`; `SupabaseService` issues its own signed URLs (~1 year expiry) rather than relying on public access.
- [ ] **Step 3:** Match `zuno-bucket`'s file size limit / allowed MIME types (Storage → `zuno-bucket` → Configuration, to see current values) so uploads behave identically.
- [ ] **Step 4:** No new API key needed — `SUPABASE_KEY` is a project-level service key, not bucket-scoped, so skull reuses zuno-app's exact same key value. Only the bucket *name* differs (`SUPABASE_BUCKET: "skull-bucket"`, already set in Task 2's ConfigMap step).

One separate bucket per customer (rather than one shared bucket with path prefixes like `zuno-bucket/skull/...`) keeps this consistent with the isolation you've applied everywhere else (own DB, own tunnel, own Infisical path) — an accidental path-traversal bug or a wrong `SUPABASE_BUCKET` value in a *future* third customer can't leak into skull's files, and vice versa.

**Infisical — new path `/zuno-app-prod/skulls-prod` (same project, nested under the existing `zuno-app-prod` folder):**

- [ ] **Step 5:** Create secret `POSTGRES_PASSWORD` under `/zuno-app-prod/skulls-prod` — **new value**, don't reuse zuno-app's (separate DB, separate blast radius if this one leaks).
- [ ] **Step 6:** Create secret `SPRING_JWT_SECRET` under `/zuno-app-prod/skulls-prod` — **new value**. This signs skull's own JWTs; reusing zuno-app's would mean a token minted for one stack authenticates against the other if an attacker ever got a request routed wrong.
- [ ] **Step 7:** Create secrets `EMAIL_USERNAME` / `EMAIL_PASSWORD` under `/zuno-app-prod/skulls-prod` — reusing the same mailbox as zuno-app is fine (it's just SMTP for verification/reset emails), or use a dedicated one if you want skull's emails to come from a different address.
- [ ] **Step 8:** Create secret `SUPABASE_KEY` under `/zuno-app-prod/skulls-prod` — **same value** as zuno-app's (same Supabase project, see above).
- [ ] **Step 9:** Create secrets `GHCR_USERNAME` / `GHCR_TOKEN` under `/zuno-app-prod/skulls-prod` — **same value** as zuno-app's (same image repos, same PAT).
- [ ] **Step 10:** Create secret `CORS_URLS` under `/zuno-app-prod/skulls-prod` with value exactly: `https://skull.zunosite.com` (no wildcard — see Global Constraints).

---

### Task 6: Cloudflare Tunnel ingress — add skull.zunosite.com above the wildcard

Not a repo file — a direct API update to the existing `zunosite` tunnel's remote config (same tunnel used for zuno-app, ID `0e243e71-f43e-45e3-bab8-b3c855ad508e`). Order matters: `skull.zunosite.com` must be listed **before** `*.zunosite.com` since Cloudflare Tunnel ingress is first-match-wins.

- [ ] **Step 1: PUT the updated ingress config**

```bash
TOKEN=$(awk '/Your API Token/{getline; print; exit}' /Users/jason/my-projects/github-ojasonw/personal/homelab-gitops/.env)
ACCT=f141d929299f801ff724b60144e80eff
TUNNEL_ID=0e243e71-f43e-45e3-bab8-b3c855ad508e
curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCT/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X PUT \
  --data '{"config":{"ingress":[
    {"hostname":"skull.zunosite.com","service":"http://skull-frontend.skull.svc.cluster.local:80"},
    {"hostname":"zunosite.com","service":"http://192.168.15.204:30880"},
    {"hostname":"*.zunosite.com","service":"http://192.168.15.204:30880"},
    {"service":"http_status:404"}
  ]}}' | jq '{success, errors}'
```
Expected: `{"success": true, "errors": []}`. The `skull.zunosite.com` target uses the in-cluster Service DNS name (ClusterIP, reachable because `cloudflared-zunosite` runs in the same cluster) — zuno-app's two rules keep their existing NodePort target unchanged.

- [ ] **Step 2: Verify no DNS change was needed**

```bash
dig +short skull.zunosite.com
```
Expected: same Cloudflare proxy IPs as `zunosite.com`/any other subdomain (wildcard CNAME already covers it).

---

### Task 7: End-to-end verification

- [ ] **Step 1: Confirm ArgoCD sync (after Tasks 1–4 are merged to main and root-app re-syncs — may need the same `argocd.argoproj.io/refresh=hard` annotation trick used for the zunosite tunnel rollout if it doesn't pick it up automatically within a few minutes)**

```bash
ssh ubuntu@192.168.15.204 "kubectl get application -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status | grep -i skull"
```
Expected: `skull` and `postgresql-skull-prod` both `Synced`/`Healthy`.

- [ ] **Step 2: Confirm pods are running**

```bash
ssh ubuntu@192.168.15.204 "kubectl get pods -n skull"
```
Expected: `skull-backend-*`, `skull-frontend-*`, and the postgres pod all `Running`.

- [ ] **Step 3: Confirm HTTPS works end-to-end and does NOT hit zuno-app**

```bash
curl -sL -o /dev/null -w "HTTP %{http_code}\n" --max-time 10 https://skull.zunosite.com
```
Expected: `HTTP 200`, served by skull's own nginx (not zuno-app's — different origin per the ingress rule from Task 6).

- [ ] **Step 4: Register skull's own Barber account with username "skull"**

Via the app's existing registration flow (`POST /auth/register` against `https://skull.zunosite.com/api/auth/register`, `username: "skull"`), then confirm via `/auth/confirm-code/{code}`. This is what makes `TenantResolver` resolve `skull.zunosite.com` → this specific barber for the public booking flow.

---

## Note: the shared Infisical Identity behind every ClusterSecretStore

You asked about the credentials in the `ClusterSecretStore` — two things worth knowing, since they cut against the per-customer isolation this plan otherwise builds:

**1. It's a plaintext-in-annotation exposure.** The `infisical-universal-auth` Secret (`external-secrets` namespace) was created via plain `kubectl apply` with `stringData`, so its clientId/clientSecret sit in the `last-applied-configuration` annotation as readable plaintext JSON — `kubectl get secret infisical-universal-auth -n external-secrets -o yaml` shows both values with no base64 decoding needed, unlike a normal Secret's `.data` fields. Anyone who can read Secrets in that namespace already gets the credential for free. Fix: recreate it with `kubectl apply --server-side` (doesn't write that annotation) or `kubectl create secret generic ... --dry-run=client -o yaml | kubectl apply -f - --save-config=false`, and rotate the clientSecret in Infisical afterward since the old one already leaked into that annotation.

**2. Every store — `infisical-prod`, `infisical-dev`, `infisical-zuno-app-prod`, and the new `infisical-skull-prod` — authenticates with this *same* Identity.** `secretsPath` on each `ClusterSecretStore` (e.g. `/zuno-app-prod/skulls-prod`) is a filter the External Secrets Operator applies when it queries — it is **not** enforced by Infisical itself unless the Identity's own policy in the Infisical dashboard is scoped to match. `infisical-prod` is configured with `secretsPath: "/"` — the whole project root — using this same Identity, which suggests its Infisical-side policy is broad, not path-restricted. If that's the case, the path-per-app convention you've been using organizes secrets well but doesn't actually stop a compromised store (or a leaked clientSecret) from reading every other app's secrets too.

To close that gap and match the isolation you built for zunosite's Cloudflare token: in the Infisical dashboard, go to **Project → Access Control → Identities**, open this machine identity, and check its assigned policy. If it's broad, the fix is either (a) scope that one policy down to read-only per-path access, or (b) create a **separate** Machine Identity per app — e.g. one for `skulls-prod` only — each with its own narrowly-scoped policy and its own k8s Secret (`infisical-universal-auth-skull` in `external-secrets`), referenced only by that app's `ClusterSecretStore`. (b) is more setup but means a leaked skull credential can't read zuno-app's secrets, or vice versa — this plan doesn't do that by default; it reuses the existing shared Identity, consistent with how `infisical-zuno-app-prod` already works today.
