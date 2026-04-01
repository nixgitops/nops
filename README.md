# nops (Nix Operations Daemon) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**nops** is a lightweight, asynchronous GitOps deployment library for NixOS. It allows you to manage an entire "Fleet" of NixOS machines—and external infrastructure—from a single centralized Git repository. 

`nops` gives you the flexibility to trigger asynchronous updates via two methods:
1. **Matrix Pub/Sub:** Nodes connect to a secure Matrix room. When your Git host posts a push notification to the room, your nodes intelligently pull the changes. Zero open firewall ports required.
2. **Webhooks:** Nodes run a lightweight `aiohttp` web server to receive standard JSON push event payloads directly from Forgejo, GitLab, or GitHub. 

When a trigger is received, the nodes pull the repository, determine if their specific configurations are affected, and apply the updates automatically via systemd.

---

## ✨ Key Features
* **Zero-Touch Node Enrollment:** Run a single `nix run` command on a fresh NixOS install to instantly bootstrap the daemon, generate secrets, and join the fleet.
* **Unified Infrastructure Controller:** Designate a single "Controller" node to safely execute pre-build infrastructure scripts (like Terraform) in a multi-node High Availability cluster.
* **Infinite Loop Prevention:** Built-in `[skip nops]` commit detection ensures automated bot commits from your Controller node do not trigger recursive rebuild loops across your fleet.
* **Smart Fleet Management:** One repository rules them all. Nodes only rebuild if their specific `nodes/$HOSTNAME/` directory, shared `modules/`, or global secrets change.
* **Native SOPS Integration:** Built-in secret management using `sops-nix` and Age keys.

---

## 📋 Prerequisites
1. **A Git Host:** A private repository on Forgejo (or GitLab/GitHub).
2. **Update Trigger:** * *For Matrix:* A Matrix homeserver, a dedicated room for updates, a Bot Access Token, and a Git hook configured to message the room.
   * *For Webhooks:* The ability for your Git host to reach the node's IP/Domain on your configured port (default `8080`).

---

## 🚀 Quick Start Guide

### Step 1: Create Your Fleet Repository
Create a new **empty private repository** (e.g., `fleet`) on your Forgejo server. 
* If this is your first node, the installer will populate the initial structure. 
* If the fleet already exists, the installer will dynamically join it.

### Step 2: Run the nops Installer
Run the following command on the target NixOS node to begin fleet enrollment. The installer will automatically bootstrap the required service users, generate Age keys, and build the initial system.

```bash
sudo nix run git+https://github.com/nixgitops/nops.git#install --refresh
```

For non-interactive enrollment:

```bash
sudo nix run git+https://github.com/nixgitops/nops.git#install -- --config config.json
```

Typical post-install flow on a new node:

```bash
sudo hostnamectl set-hostname PBX-Asterisk-001
sudo nix run git+https://github.com/nixgitops/nops.git#install --refresh
```

Example service configuration after enrollment:

```nix
services.nops = {
  enable = true;
  repoPath = "/home/nops/fleet";

  # To use Matrix triggers
  matrix.enable = true;

  # To use Webhook triggers
  webhook.enable = true;
  webhook.port = 8080;

  # Advanced: Designate this node as the Infrastructure Controller
  isController = true;
  controllerScript = ''
    # Run Terraform, generate secrets, and push back to Git!
    # Follower nodes will automatically pause and wait for this to finish.
    # Be sure to use [skip nops] in your automated commit messages.
  '';
};
```