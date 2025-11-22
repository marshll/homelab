#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/marshll/homelab.git"
REPO_DIR="/opt/homelab"
CONFIG_FILE="/etc/homelab/config.env"

# ===== helper functions =====

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "$ID"
  else
    echo "unknown"
  fi
}

need_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root (use sudo)."
    exit 1
  fi
}

pkg_install_debian() {
  apt-get update -y
  apt-get install -y "$@"
}

ensure_basic_tools() {
  echo "== Step 1: Checking required tools (git, curl) =="

  local missing=()
  for cmd in git curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    echo "All required tools found."
    return
  fi

  echo "Missing required tools: ${missing[*]}"
  local os
  os="$(detect_os)"

  case "$os" in
    debian|ubuntu)
      echo "Installing missing tools via apt: ${missing[*]}"
      pkg_install_debian "${missing[@]}"
      ;;
    *)
      echo "Automatic installation for OS '$os' is not implemented."
      echo "Please install: ${missing[*]} and run this script again."
      exit 1
      ;;
  esac
}

install_helm_if_missing() {
  echo "== Step 2: Checking Helm installation =="

  if command -v helm >/dev/null 2>&1; then
    echo "Helm is already installed."
    return
  fi

  echo "Helm not found. Attempting to install Helm (helm 3+)..."

  local os
  os="$(detect_os)"

  case "$os" in
    debian|ubuntu)
      echo "Installing Helm using official install script..."
      curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash -
      ;;
    *)
      echo "Automatic Helm installation for OS '$os' is not implemented."
      echo "Please install Helm manually: https://helm.sh/docs/intro/install/"
      exit 1
      ;;
  esac

  if command -v helm >/dev/null 2>&1; then
    echo "Helm installation completed."
  else
    echo "Helm installation failed or helm not found after install." >&2
    exit 1
  fi
}

clone_or_update_repo() {
  echo "== Step 3: Fetching homelab repository =="

  if [ -d "$REPO_DIR/.git" ]; then
    echo "Repository already exists at $REPO_DIR. Updating..."
    cd "$REPO_DIR"
    git pull --ff-only
  else
    echo "Cloning $REPO_URL to $REPO_DIR..."
    mkdir -p "$REPO_DIR"
    git clone "$REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
  fi
}

ensure_config() {
  echo "== Step 4: Checking local configuration =="

  if [ -f "$CONFIG_FILE" ]; then
    echo "Found local config: $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    return
  fi

  echo "No local config found. Creating a template at $CONFIG_FILE ..."
  mkdir -p "$(dirname "$CONFIG_FILE")"

  cat > "$CONFIG_FILE" <<'EOF'
# Homelab base configuration
# Adjust these values before re-running bootstrap.sh

# Public domain or local DNS name for your homelab
HOMELAB_DOMAIN=homelab.example.com
GITEA_URL=gitea.homelab.example.com

# Initial Gitea admin account
GITEA_ADMIN_USER=admin
GITEA_ADMIN_PASSWORD=changeme
GITEA_ADMIN_EMAIL=you@example.com

# Basic K3s configuration
K3S_NODE_ROLE=server
K3S_ADVERTISE_ADDRESS=192.168.1.10

# Optional: pin a specific K3s version, e.g. "v1.30.4+k3s1"
# K3S_VERSION=v1.30.4+k3s1
EOF

  echo
  echo "A template config has been created."
  echo "Please edit $CONFIG_FILE to match your environment and run this script again."
  exit 1
}

check_ports() {
  echo "== Step 5: Checking important ports (80, 443) =="

  if ! command -v ss >/dev/null 2>&1; then
    echo "Command 'ss' not found, skipping port checks."
    return
  fi

  for p in 80 443; do
    if ss -lnt "( sport = :$p )" 2>/dev/null | grep -q ":$p"; then
      echo "WARNING: Port $p is currently in use. Ingress/Traefik/NGINX may not be able to bind."
    else
      echo "Port $p is free."
    fi
  done
}

install_k3s_if_missing() {
  echo "== Step 6: Checking K3s installation =="

  if command -v k3s >/dev/null 2>&1; then
    echo "K3s is already installed."
    return
  fi

  echo "K3s not found. Installing K3s server node..."

  local extra_args=()

  if [ "${K3S_ADVERTISE_ADDRESS:-}" != "" ]; then
    extra_args+=(--node-ip "${K3S_ADVERTISE_ADDRESS}")
  fi

  # Optional: allow pinning a version via config.env
  if [ "${K3S_VERSION:-}" != "" ]; then
    echo "Using K3s version: $K3S_VERSION"
    INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="${extra_args[*]}" \
      sh -s - < <(curl -sfL https://get.k3s.io)
  else
    echo "No K3S_VERSION set. Installing latest K3s from get.k3s.io"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="${extra_args[*]}" sh -
  fi

  echo "K3s installation finished."
}

ensure_install_script() {
  echo "== Step 7: Checking install.sh =="

  local script="$REPO_DIR/install.sh"

  if [ ! -f "$script" ]; then
    echo "ERROR: $script not found."
    echo "The repository might be incomplete."
    exit 1
  fi

  if [ ! -x "$script" ]; then
    echo "install.sh is not executable. Fixing permissions..."
    chmod +x "$script"
  fi

  echo "install.sh is ready."
}

run_install() {
  echo "== Step 8: Running install.sh (deploying apps to K3s) =="
  cd "$REPO_DIR"
  ./install.sh
}

# ===== main =====

main() {
  echo "Homelab bootstrap – this will prepare the system, install K3s and then deploy Gitea/manifests."
  echo

  need_root
  ensure_basic_tools
  install_helm_if_missing
  clone_or_update_repo
  ensure_config
  check_ports
  install_k3s_if_missing
  ensure_install_script
  run_install

  echo
  echo "Bootstrap process completed."
}

main "$@"