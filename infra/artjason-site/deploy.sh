#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="artjason-site"
APP_NAME="artjason-site"
HTML_FILE="$(dirname "$0")/index.html"

echo "==> Namespace"
kubectl apply -f "$(dirname "$0")/base/00-namespace.yaml"

echo "==> ConfigMap nginx"
kubectl apply -f "$(dirname "$0")/base/01-configmap-nginx.yaml"

echo "==> ConfigMap HTML"
kubectl create configmap "${APP_NAME}-html" \
  --from-file=index.html="${HTML_FILE}" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Deployment"
kubectl apply -f "$(dirname "$0")/base/02-deployment.yaml"

echo "==> Service"
kubectl apply -f "$(dirname "$0")/base/03-service.yaml"

echo "==> Aguardando rollout..."
kubectl rollout status deployment/"${APP_NAME}" -n "${NAMESPACE}" --timeout=120s

echo ""
echo "==> Status"
kubectl get pods,svc -n "${NAMESPACE}"
