#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/homelab/config.env"

echo "== Homelab install script =="
echo "Deploying local Helm chart (Gitea) into your K3s cluster."
echo

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: $CONFIG_FILE not found."
  echo "Please run bootstrap.sh first, so it can generate the config template."
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# ------------------------------------------------------------
# Force use of the correct K3s kubeconfig
# ------------------------------------------------------------
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ------------------------------------------------------------
# Validate config
# ------------------------------------------------------------
: "${GITEA_URL:?GITEA_URL must be set in $CONFIG_FILE}"
: "${GITEA_NAMESPACE:=gitea}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$SCRIPT_DIR/charts/gitea"
MANIFEST_DIR="$SCRIPT_DIR/manifests"

# ------------------------------------------------------------
# Ensure k3s / kubectl ready
# ------------------------------------------------------------
echo "== Step 1: Ensuring Kubernetes API is reachable =="

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not available — K3s is not installed or PATH is broken."
  exit 1
fi

# Wait for API
timeout=60
while ! kubectl get nodes >/dev/null 2>&1; do
  echo "Waiting for Kubernetes API..."
  sleep 2
  timeout=$((timeout - 2))
  if [ $timeout -le 0 ]; then
    echo "ERROR: Kubernetes API did not become ready in time."
    exit 1
  fi
done

echo "K3s API reachable."

# ------------------------------------------------------------
# Ensure Helm installed
# ------------------------------------------------------------
echo "== Step 2: Checking Helm =="
if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: Helm not installed."
  echo "Please install Helm 3 and re-run this script."
  exit 1
fi

helm version >/dev/null 2>&1 || {
  echo "ERROR: helm version check failed."
  exit 1
}

# ------------------------------------------------------------
# Verify local chart
# ------------------------------------------------------------
echo "== Step 3: Verifying local Gitea chart at $CHART_DIR =="

if [ ! -f "$CHART_DIR/Chart.yaml" ]; then
  echo "ERROR: Local chart not found at $CHART_DIR"
  echo "Expected: charts/gitea/Chart.yaml"
  exit 1
fi

# ------------------------------------------------------------
# Create namespace
# ------------------------------------------------------------
echo "== Step 4: Ensuring namespace '$GITEA_NAMESPACE' exists =="

kubectl create namespace "$GITEA_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ------------------------------------------------------------
# Install / upgrade Gitea
# ------------------------------------------------------------
echo "== Step 5: Installing or upgrading Gitea from local chart =="

helm upgrade --install gitea "$CHART_DIR" \
  --namespace "$GITEA_NAMESPACE" \
  --create-namespace \
  --set-string ingress.host="$GITEA_URL"

echo
echo "Gitea deployment applied."
echo "Helm releases:"
helm list -n "$GITEA_NAMESPACE" || true

# ------------------------------------------------------------
# Apply additional manifests
# ------------------------------------------------------------
echo
echo "== Step 6: Applying additional manifests (if present) =="

if [ -d "$MANIFEST_DIR" ]; then
  find "$MANIFEST_DIR" -type f -name "*.yaml" -print0 | while IFS= read -r -d '' file; do
    echo "Applying: $file"
    kubectl apply -f "$file"
  done
else
  echo "No manifests directory found."
fi

# ------------------------------------------------------------
# Done
# ------------------------------------------------------------
echo
echo "== Homelab installation complete =="
echo "Check Gitea pods with:"
echo "  kubectl get pods -n $GITEA_NAMESPACE"
echo
echo "Ingress should expose:"
echo "  https://$GITEA_URL"
echo
