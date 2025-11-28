#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/marshll/homelab.git"
REPO_DIR="/opt/homelab"
CONFIG_FILE="/etc/homelab/config.env"

# Standard-Branch (kann mit REPO_BRANCH=<branch> beim Aufruf überschrieben werden)
REPO_BRANCH="${REPO_BRANCH:-main}"

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
  echo "Using branch: $REPO_BRANCH"

  if [ -d "$REPO_DIR/.git" ]; then
    echo "Repository already exists at $REPO_DIR."
    cd "$REPO_DIR"

    echo "Fetching branch '$REPO_BRANCH' from origin..."
    if ! git fetch origin "$REPO_BRANCH"; then
      echo "ERROR: Could not fetch branch '$REPO_BRANCH' from origin." >&2
      exit 1
    fi

    echo "Resetting local working tree to origin/$REPO_BRANCH (discarding ALL local changes)..."

    # 1. Verwirft ALLE Änderungen in tracked Dateien
    git reset --hard HEAD

    # 2. Löscht untracked Dateien und Ordner
    git clean -xfd

    # 3. Checke den Branch von origin komplett neu aus
    git checkout -B "$REPO_BRANCH" "origin/$REPO_BRANCH"

    # 4. Und setze erneut hart auf den Remote-Stand – absolute Sicherheit
    git reset --hard "origin/$REPO_BRANCH"

  else
    echo "Cloning $REPO_URL (branch: $REPO_BRANCH) to $REPO_DIR..."
    mkdir -p "$REPO_DIR"
    git clone --branch "$REPO_BRANCH" --single-branch "$REPO_URL" "$REPO_DIR"
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

  echo "No config found at $CONFIG_FILE"
  echo "Please copy the template:"
  echo "  cp $REPO_DIR/example.config.env $CONFIG_FILE"
  echo "and edit it accordingly."
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

check_existing_k3s() {
  echo "== Step 6: Checking existing K3s installation =="

  if ! command -v k3s >/dev/null 2>&1; then
    echo "No k3s binary found. Nothing to check."
    return
  fi

  echo "k3s binary is present."

  # Wenn systemctl verfügbar ist, k3s-Status prüfen
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet k3s; then
      echo "k3s service is active and healthy."
      echo "I will NOT modify the existing installation."
      return
    else
      echo "k3s is installed but not active/healthy."
    fi
  else
    echo "systemctl not found; cannot verify k3s state reliably."
  fi

  echo
  echo "WARNING: There is an existing k3s installation that is not running cleanly."
  echo "Resetting k3s will:"
  echo "  - Stop and uninstall k3s"
  echo "  - Delete /var/lib/rancher/k3s and /etc/rancher/k3s"
  echo "  - Allow this script to install a fresh cluster"
  echo

  #
  # === FORCE OPTION ===
  #
  if [ "${K3S_FORCE_RESET:-0}" = "1" ]; then
    echo "K3S_FORCE_RESET=1 is set."
    echo "Proceeding with automatic k3s reset WITHOUT prompting."
    if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
      /usr/local/bin/k3s-uninstall.sh
      echo "k3s has been force-reset."
      return
    else
      echo "ERROR: /usr/local/bin/k3s-uninstall.sh not found."
      exit 1
    fi
  fi

  #
  # === INTERAKTIVER MODUS ===
  #
  if [ -t 0 ] || [ -t 1 ]; then
    read -r -p "Do you want to uninstall and reinstall k3s now? [y/N]: " answer </dev/tty || answer=""
  else
    echo "Non-interactive environment detected (e.g. curl | bash)."
    echo "For safety, automatic reset is disabled."
    echo "If you really want to reset k3s non-interactively, run again with:"
    echo "  K3S_FORCE_RESET=1"
    exit 1
  fi

  case "$answer" in
    [yY][eE][sS]|[yY])
      echo "User confirmed reset. Running k3s-uninstall.sh ..."
      if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
        /usr/local/bin/k3s-uninstall.sh
        echo "k3s has been uninstalled. A clean installation will follow."
      else
        echo "ERROR: /usr/local/bin/k3s-uninstall.sh not found."
        exit 1
      fi
      ;;
    *)
      echo "User chose NOT to reset k3s."
      echo "Bootstrap aborted to protect this server."
      exit 1
      ;;
  esac
}

install_k3s_if_missing() {
  echo "== Step 7: Checking K3s installation =="

  if command -v k3s >/dev/null 2>&1; then
    echo "K3s is already installed. Skipping k3s install."
    return
  fi

  echo "K3s not found. Installing K3s server node..."

  local extra_args=()

  # Nur dann --node-ip setzen, wenn die Adresse wirklich auf einem Interface existiert
  if [ -n "${K3S_ADVERTISE_ADDRESS:-}" ]; then
    if ip addr | grep -q " ${K3S_ADVERTISE_ADDRESS}/"; then
      echo "Using K3S_ADVERTISE_ADDRESS=${K3S_ADVERTISE_ADDRESS}"
      extra_args+=(--node-ip "${K3S_ADVERTISE_ADDRESS}")
    else
      echo "WARNING: K3S_ADVERTISE_ADDRESS=${K3S_ADVERTISE_ADDRESS} not found on any interface. Ignoring this setting."
    fi
  fi

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
  echo "== Step 8: Checking install.sh =="

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
  echo "== Step 9: Running install.sh (deploying apps to K3s) =="
  cd "$REPO_DIR"
  ./install.sh
}

# ===== main =====

main() {
  echo "Homelab bootstrap – this will prepare the system, install K3s and then deploy Gitea/manifests."
  echo
  echo "Repository branch: $REPO_BRANCH"
  echo

  need_root
  ensure_basic_tools
  install_helm_if_missing
  clone_or_update_repo
  ensure_config
  check_ports
  check_existing_k3s
  install_k3s_if_missing
  ensure_install_script
  run_install

  echo
  echo "Bootstrap process completed."
}

main "$@"