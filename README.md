# 📘 Homelab

Automated provisioning of a complete homelab server, including:

-   **System preparation**
-   **Fetching configuration**
-   **Installing K3s (lightweight Kubernetes)**
-   **Deploying applications (e.g. Gitea) into the cluster**

The goal is full reproducibility:\
A fresh Debian/Ubuntu system can be transformed into a fully working
homelab with **one command**.

## 🚀 Quick Start (Fresh Server)

Run this command on a clean Debian/Ubuntu host:

``` bash
curl -fsSL https://raw.githubusercontent.com/marshll/homelab/main/bootstrap.sh | sudo bash
```

The script will:

1.  Check required tools\
2.  Clone or update this repository\
3.  Create `/etc/homelab/config.env` if missing\
4.  Install K3s\
5.  Deploy all Kubernetes manifests from `manifests/`

If this is the first run, the script will generate a config file and ask
you to edit it before proceeding.

## 📁 Repository Structure

    homelab/
    ├── bootstrap.sh
    ├── install.sh
    ├── config.env.example
    └── charts/

## ⚙️ Requirements

-   Debian or Ubuntu system
-   Internet connectivity
-   `sudo` privileges

## 🛠️ First-Time Setup

1.  Run the bootstrap script\
2.  Edit `/etc/homelab/config.env`
3.  Run bootstrap again

## 🔄 Updating the Homelab

``` bash
cd /opt/homelab
sudo ./install.sh
```

## 🔒 Local Configuration

Stored at:

    /etc/homelab/config.env

## Configuration & Environment Variables

The bootstrap process can be controlled via environment variables.  
These variables are **optional** and are mostly intended for testing, CI, or advanced setups.

### Bootstrap-related variables

| Variable         | Default | Used by       | Description |
|------------------|---------|---------------|-------------|
| `REPO_BRANCH`    | `main`  | `bootstrap.sh`| Git branch to clone into `/opt/homelab`. Useful for testing feature branches. |
| `K3S_FORCE_RESET`| `0`     | `bootstrap.sh`| If set to `1`, an unhealthy existing k3s installation will be **uninstalled without asking**. Use with care. |

#### `REPO_BRANCH`

Controls which Git branch is checked out to `/opt/homelab`.

Examples:

```bash
# Run bootstrap from main (default)
curl -fsSL https://raw.githubusercontent.com/marshll/homelab/main/bootstrap.sh \
  | sudo REPO_BRANCH=main bash

# Run bootstrap from init branch for testing
curl -fsSL https://raw.githubusercontent.com/marshll/homelab/init/bootstrap.sh \
  | sudo REPO_BRANCH=init bash
```

## 📝 License

MIT License.
