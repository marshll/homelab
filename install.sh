#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/homelab/config.env"

echo "== Homelab install script =="
echo "Deploying local Helm charts into your K3s cluster."
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
# Validate minimal config
# ------------------------------------------------------------
: "${GITEA_URL:?GITEA_URL must be set in $CONFIG_FILE}"
: "${GITEA_NAMESPACE:=gitea}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# MANIFEST_DIR kann in der Config relativ gesetzt werden (z. B. "manifests")
MANIFEST_DIR="${MANIFEST_DIR:-manifests}"
MANIFEST_DIR="$SCRIPT_DIR/$MANIFEST_DIR"

# CHARTS muss in der Config definiert sein
if [ "${CHARTS+x}" != "x" ]; then
  echo "ERROR: CHARTS array is not defined in $CONFIG_FILE"
  echo "Please define CHARTS=() with your Helm releases in the config."
  exit 1
fi

# Fallback-Defaults für Step-Issuer Namespace
: "${STEP_ISSUER_NAMESPACE:=step-issuer}"

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
# Ensure Helm installed + repos
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

# Helm-Repos für Remote-Charts (z. B. smallstep/step-issuer) sicherstellen
# (lokale Charts bleiben davon unberührt)
if ! helm repo list 2>/dev/null | grep -q '^smallstep'; then
  echo "Adding smallstep Helm repo (for step-issuer)..."
  helm repo add smallstep https://smallstep.github.io/helm-charts
fi

# Optional: jetstack, falls du irgendwann cert-manager als Remote-Chart nutzt
if ! helm repo list 2>/dev/null | grep -q '^jetstack'; then
  echo "Adding jetstack Helm repo (for cert-manager, if needed)..."
  helm repo add jetstack https://charts.jetstack.io
fi

helm repo update

# ------------------------------------------------------------
# Helper: configure step-issuer (Secret + StepClusterIssuer)
# ------------------------------------------------------------
configure_step_issuer() {
  echo
  echo "== Step 4: Configuring step-issuer & StepClusterIssuer =="

  # Wenn Step-CA nicht konfiguriert ist, alles überspringen
  if [ -z "${STEP_CA_URL:-}" ] || [ -z "${STEP_CA_PROVISIONER:-}" ]; then
    echo "STEP_CA_URL oder STEP_CA_PROVISIONER nicht gesetzt – skipping step-issuer configuration."
    return 0
  fi

  # Key- und Passwort-Dateien prüfen (wie in config.env konfiguriert)
  if [ -z "${STEP_CA_PROVISIONER_KEY_FILE:-}" ] || [ ! -f "${STEP_CA_PROVISIONER_KEY_FILE}" ]; then
    echo "WARN: STEP_CA_PROVISIONER_KEY_FILE '${STEP_CA_PROVISIONER_KEY_FILE:-<unset>}' nicht gefunden."
    echo "      step-issuer Secret wird nicht erstellt."
    return 0
  fi

  if [ -z "${STEP_CA_PROVISIONER_PASSWORD_FILE:-}" ] || [ ! -f "${STEP_CA_PROVISIONER_PASSWORD_FILE}" ]; then
    echo "WARN: STEP_CA_PROVISIONER_PASSWORD_FILE '${STEP_CA_PROVISIONER_PASSWORD_FILE:-<unset>}' nicht gefunden."
    echo "      step-issuer Secret wird nicht erstellt."
    return 0
  fi

  echo "Ensuring namespace '${STEP_ISSUER_NAMESPACE}' exists for step-issuer..."
  kubectl create namespace "${STEP_ISSUER_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  echo "Creating/updating secret 'step-issuer-credentials' in namespace ${STEP_ISSUER_NAMESPACE} ..."
  kubectl -n "${STEP_ISSUER_NAMESPACE}" delete secret step-issuer-credentials >/dev/null 2>&1 || true

  kubectl -n "${STEP_ISSUER_NAMESPACE}" create secret generic step-issuer-credentials \
    --from-literal=CA_URL="${STEP_CA_URL}" \
    --from-literal=PROVISIONER_NAME="${STEP_CA_PROVISIONER}" \
    --from-file=PROVISIONER_KEY="${STEP_CA_PROVISIONER_KEY_FILE}" \
    --from-file=PROVISIONER_PASSWORD="${STEP_CA_PROVISIONER_PASSWORD_FILE}"

  # *** HIER: Template mit envsubst anwenden ***
  local tpl_dir="$MANIFEST_DIR/step-issuer"
  local tpl_file="$tpl_dir/step-clusterissuer.yaml.tpl"

  echo "Looking for StepClusterIssuer template at: $tpl_file"

  if [ ! -f "$tpl_file" ]; then
    echo "WARN: StepClusterIssuer template '$tpl_file' not found – skipping issuer apply."
    echo "      Bitte lege die Datei an oder passe MANIFEST_DIR an."
    return 0
  fi

  echo "Applying StepClusterIssuer 'step-ca-issuer' from template ..."

  # envsubst ersetzt ${STEP_CA_URL} und ${STEP_CA_PROVISIONER} im Template
  STEP_CA_URL="${STEP_CA_URL}" STEP_CA_PROVISIONER="${STEP_CA_PROVISIONER}" \
    envsubst < "$tpl_file" | kubectl apply -f -

  echo "step-issuer configuration finished."
}

# ------------------------------------------------------------
# Charts to install (from config)
# ------------------------------------------------------------
echo "== Step 3: Verifying and installing charts from configuration =="

for desc in "${CHARTS[@]}"; do
  # Split descriptor into 4 parts at most
  IFS=':' read -r release chart_ref_raw namespace extra <<< "$desc"

  echo
  echo "-- Chart: $release"
  echo "   Raw reference: $chart_ref_raw"
  echo "   Namespace:     $namespace"

  # chart_ref kann entweder:
  # - lokaler Pfad (relativ zum Repo)
  # - absoluter Pfad
  # - Remote-Chart (z. B. jetstack/cert-manager oder smallstep/step-issuer)
  chart_ref="$chart_ref_raw"
  local_path=""

  # Wenn kein Slash vorne ist und das Verzeichnis unter SCRIPT_DIR existiert,
  # behandeln wir es als lokalen Chart-Pfad relativ zum Repo.
  if [[ "$chart_ref_raw" != /* ]] && [ -d "$SCRIPT_DIR/$chart_ref_raw" ]; then
    local_path="$SCRIPT_DIR/$chart_ref_raw"
    chart_ref="$local_path"
  elif [ -d "$chart_ref_raw" ]; then
    # Absoluter (oder bereits aufgelöster) Pfad
    local_path="$chart_ref_raw"
  fi

  if [ -n "$local_path" ]; then
    echo "   Detected local chart directory: $local_path"
    if [ ! -f "$local_path/Chart.yaml" ]; then
      echo "ERROR: Local chart for release '$release' not found at $local_path"
      echo "Expected: $local_path/Chart.yaml"
      exit 1
    fi
    echo "   Local chart verified."
  else
    echo "   Using chart reference as-is (assuming Helm repo is configured)."
  fi

  # Ensure namespace exists
  echo "   Ensuring namespace '$namespace' exists..."
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -

  # Install or upgrade
  echo "   Installing/upgrading release '$release'..."
  if [ -n "${extra:-}" ]; then
    # `extra` kann mehrere Optionen enthalten; unquoted expanden, damit sie als einzelne Args ankommen
    helm upgrade --install "$release" "$chart_ref" \
      --namespace "$namespace" --create-namespace $extra
  else
    helm upgrade --install "$release" "$chart_ref" \
      --namespace "$namespace" --create-namespace
  fi

  echo "   Release '$release' applied."
  echo "   Helm releases in namespace '$namespace':"
  helm list -n "$namespace" || true
done

# ------------------------------------------------------------
# Step 4: configure step-issuer (Secret + StepClusterIssuer)
# ------------------------------------------------------------
configure_step_issuer

# ------------------------------------------------------------
# Apply additional manifests
# ------------------------------------------------------------
echo
echo "== Step 5: Applying additional manifests (if present) =="

if [ -d "$MANIFEST_DIR" ]; then
  find "$MANIFEST_DIR" -type f -name "*.yaml" -print0 | while IFS= read -r -d '' file; do
    echo "Applying: $file"
    kubectl apply -f "$file"
  done
else
  echo "No manifests directory found at $MANIFEST_DIR."
fi

# ------------------------------------------------------------
# Done
# ------------------------------------------------------------
echo
echo "== Homelab installation complete =="

echo "Check Gitea pods with (if Gitea is part of CHARTS):"
echo "  kubectl get pods -n ${GITEA_NAMESPACE}"
echo
echo "Ingress (if configured) should expose e.g.:"
echo "  https://${GITEA_URL}"
echo
echo "If you use step-ca + step-issuer, you now have a ClusterIssuer 'step-ca-issuer'."
echo "You can reference it in Ingress/Credentials via:"
echo "  cert-manager.io/cluster-issuer: step-ca-issuer"
