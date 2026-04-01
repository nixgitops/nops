#!/usr/bin/env bash
# Enrolls a new node into the fleet: creates the nops user, clones the repo, scaffolds node config, configures SOPS, and pushes the enrollment commit.
set -e

HOSTNAME=$(hostname)
TEMPLATES_DIR="${NOPS_TEMPLATES_DIR:-../templates}"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    cat <<'EOF'
Usage:
  setup.sh [--config config.json] [--clean]
  setup.sh --repo-url URL --git-user USER --git-token TOKEN --node-group GROUP --admin USER --admin-pass PASS [OPTIONS]

Config file mode:
  --config PATH            Read enrollment values from a JSON file.

Direct flag mode:
    --hostname NAME          Node hostname to write into the generated config.
  --repo-url URL           Fleet repository URL (HTTPS).
  --git-user USER          Git username for clone/push operations.
  --git-token TOKEN        Git token or password for clone/push operations.
  --node-group GROUP       Group/tier for this node.
  --group GROUP            Alias for --node-group.
  --admin USER             Primary admin username to create on this node.
  --node-admin USER        Alias for --admin.
  --admin-pass PASS        Password for the node admin user.
  --node-admin-pass PASS   Alias for --admin-pass.
  --trigger MODE           Trigger mode: matrix or webhook.
  --trigger-choice VALUE   Trigger mode: 1 or 2.
  --fleet-private-key KEY  Shared Age private key for the fleet.
  --matrix-bot-token TOK   Matrix bot token.
  --matrix-room-id ROOM    Matrix room ID.
  --matrix-homeserver HS   Matrix homeserver.
  --webhook-secret SECRET  Shared webhook secret.

Optional:
  --clean                  Remove previous nops state before enrollment.
  -h, --help               Show this help text.

Notes:
  - If both --config and direct flags are provided, direct flags take precedence.
  - If neither --config nor direct flags are provided, the installer prompts interactively.
    - If --hostname is omitted, the installer uses the current system hostname.
EOF
}

require_value() {
    local option="$1"
    local value="${2:-}"

    [[ -n "$value" ]] || {
        usage
        echo "Error: missing value for $option" >&2
        exit 1
    }
}

normalize_trigger_choice() {
    local value="$1"

    case "$value" in
        "") printf '%s' "" ;;
        1|matrix|MATRIX|Matrix) printf '1' ;;
        2|webhook|WEBHOOK|Webhook) printf '2' ;;
        *)
            usage
            echo "Error: unsupported trigger choice '$value' (use matrix|webhook or 1|2)" >&2
            exit 1 ;;
    esac
}

normalize_bool() {
    local value="$1"

    case "$value" in
        "") printf '%s' "" ;;
        true|TRUE|True|1|yes|YES|on|ON) printf 'true' ;;
        false|FALSE|False|0|no|NO|off|OFF) printf 'false' ;;
        *)
            usage
            echo "Error: unsupported boolean value '$value' (use true|false)" >&2
            exit 1 ;;
    esac
}

format_dns_list() {
    local raw="$1"
    local -a dns_entries=()
    local formatted=""

    raw="${raw//,/ }"
    # shellcheck disable=SC2206
    dns_entries=($raw)

    for dns in "${dns_entries[@]}"; do
        [ -n "$dns" ] || continue
        formatted="$formatted \"$dns\""
    done

    printf '%s' "${formatted# }"
}

CONFIG_FILE=""
NON_INTERACTIVE=false
CLEAN=false
DIRECT_INPUT=false

HOSTNAME_OVERRIDE=""

GIT_USER=""
GIT_TOKEN=""
REPO_URL=""
NODE_GROUP=""
NODE_ADMIN=""
NODE_ADMIN_PASS=""
TRIGGER_CHOICE=""
FLEET_PRIVATE_KEY=""
MATRIX_BOT_TOKEN=""
MATRIX_ROOM_ID=""
MATRIX_HOMESERVER=""
WEBHOOK_SECRET=""

BOOTSTRAP_MODE=""
IS_CONTROLLER=""
NODE_ROLE=""
NODE_SSH_PUB_KEY=""
STATIC_IP=""
STATIC_GATEWAY=""
STATIC_PREFIX_LENGTH=""
STATIC_DNS=""
STATIC_INTERFACE=""

ARG_GIT_USER=""
ARG_GIT_TOKEN=""
ARG_REPO_URL=""
ARG_NODE_GROUP=""
ARG_NODE_ADMIN=""
ARG_NODE_ADMIN_PASS=""
ARG_TRIGGER_CHOICE=""
ARG_FLEET_PRIVATE_KEY=""
ARG_MATRIX_BOT_TOKEN=""
ARG_MATRIX_ROOM_ID=""
ARG_MATRIX_HOMESERVER=""
ARG_WEBHOOK_SECRET=""

ARG_BOOTSTRAP_MODE=""
ARG_IS_CONTROLLER=""
ARG_NODE_ROLE=""
ARG_NODE_SSH_PUB_KEY=""
ARG_STATIC_IP=""
ARG_STATIC_GATEWAY=""
ARG_STATIC_PREFIX_LENGTH=""
ARG_STATIC_DNS=""
ARG_STATIC_INTERFACE=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --config)
            require_value "$1" "${2:-}"
            CONFIG_FILE="$2"
            NON_INTERACTIVE=true
            shift 2 ;;
        --clean)
            CLEAN=true
            shift ;;
        --git-user)
            require_value "$1" "${2:-}"
            ARG_GIT_USER="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --hostname)
            require_value "$1" "${2:-}"
            HOSTNAME_OVERRIDE="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --git-token)
            require_value "$1" "${2:-}"
            ARG_GIT_TOKEN="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --repo-url)
            require_value "$1" "${2:-}"
            ARG_REPO_URL="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --node-group|--group)
            require_value "$1" "${2:-}"
            ARG_NODE_GROUP="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --node-admin|--admin)
            require_value "$1" "${2:-}"
            ARG_NODE_ADMIN="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --node-admin-pass|--admin-pass)
            require_value "$1" "${2:-}"
            ARG_NODE_ADMIN_PASS="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --trigger|--trigger-choice)
            require_value "$1" "${2:-}"
            ARG_TRIGGER_CHOICE="$(normalize_trigger_choice "$2")"
            DIRECT_INPUT=true
            shift 2 ;;
        --fleet-private-key)
            require_value "$1" "${2:-}"
            ARG_FLEET_PRIVATE_KEY="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --matrix-bot-token)
            require_value "$1" "${2:-}"
            ARG_MATRIX_BOT_TOKEN="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --matrix-room-id)
            require_value "$1" "${2:-}"
            ARG_MATRIX_ROOM_ID="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --matrix-homeserver)
            require_value "$1" "${2:-}"
            ARG_MATRIX_HOMESERVER="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --webhook-secret)
            require_value "$1" "${2:-}"
            ARG_WEBHOOK_SECRET="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --bootstrap-mode)
            require_value "$1" "${2:-}"
            ARG_BOOTSTRAP_MODE="$(normalize_bool "$2")"
            DIRECT_INPUT=true
            shift 2 ;;
        --is-controller)
            require_value "$1" "${2:-}"
            ARG_IS_CONTROLLER="$(normalize_bool "$2")"
            DIRECT_INPUT=true
            shift 2 ;;
        --node-role)
            require_value "$1" "${2:-}"
            ARG_NODE_ROLE="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --node-ssh-pub-key|--ssh-key)
            require_value "$1" "${2:-}"
            ARG_NODE_SSH_PUB_KEY="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --static-ip)
            require_value "$1" "${2:-}"
            ARG_STATIC_IP="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --static-gateway|--gateway)
            require_value "$1" "${2:-}"
            ARG_STATIC_GATEWAY="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --static-prefix-length|--prefix-length)
            require_value "$1" "${2:-}"
            ARG_STATIC_PREFIX_LENGTH="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --static-dns|--dns)
            require_value "$1" "${2:-}"
            ARG_STATIC_DNS="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        --static-interface|--interface)
            require_value "$1" "${2:-}"
            ARG_STATIC_INTERFACE="$2"
            DIRECT_INPUT=true
            shift 2 ;;
        -h|--help)
            usage
            exit 0 ;;
        *)
            usage
            echo "Unknown parameter passed: $1" >&2
            exit 1 ;;
    esac
done

if [ -n "$CONFIG_FILE" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Config file $CONFIG_FILE not found!"
        exit 1
    fi
    NON_INTERACTIVE=true
fi

[ -n "$HOSTNAME_OVERRIDE" ] && HOSTNAME="$HOSTNAME_OVERRIDE"

LOG_FILE="/home/nops/log/main.log"

# Writes a timestamped INFO entry to both stdout and the log file.
log() { 
    echo -e "${BLUE}[nops-setup]${NC} $1"
    sudo mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [nops-setup] [INFO] $1" | sudo tee -a "$LOG_FILE" > /dev/null
}

# Prints a yellow warning to stdout only.
warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log "Initializing nops Fleet Enrollment for $HOSTNAME..."

# Wipes the nops user, home directory, and age key to allow a clean re-enrollment.
if [ "$CLEAN" = true ]; then
    log "--clean flag detected. Wiping previous nops state..."
    if id "nops" &>/dev/null; then
        sudo userdel -r nops 2>/dev/null || true
        sudo groupdel nops 2>/dev/null || true
    fi
    sudo rm -rf /home/nops
    sudo rm -f /var/lib/sops-nix/key.txt
    sudo git config --global --unset-all safe.directory 2>/dev/null || true
    log "Clean complete."
fi

# Creates the nops service user and group if absent; ensures correct home directory ownership.
if ! id "nops" &>/dev/null; then
    log "User 'nops' does not exist. Creating temporary service user..."
    sudo groupadd nops || true
    sudo useradd -m -g nops -s /run/current-system/sw/bin/bash nops
fi
sudo mkdir -p /home/nops
sudo chown -R nops:nops /home/nops

command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for nops enrollment." >&2
    exit 1
}

# Reads git credentials, repo URL, group, admin user, trigger mode, and secrets from a JSON config file, direct command-line flags, or interactive prompts.
if [ "$NON_INTERACTIVE" = true ]; then
    log "Non-interactive mode enabled. Reading from $CONFIG_FILE..."
    GIT_USER=$(jq -r '.git_user // empty' "$CONFIG_FILE")
    GIT_TOKEN=$(jq -r '.git_token // empty' "$CONFIG_FILE")
    REPO_URL=$(jq -r '.repo_url // empty' "$CONFIG_FILE")
    NODE_GROUP=$(jq -r '.node_group // "default"' "$CONFIG_FILE")
    NODE_ADMIN=$(jq -r '.node_admin // empty' "$CONFIG_FILE")
    NODE_ADMIN_PASS=$(jq -r '.node_admin_pass // empty' "$CONFIG_FILE")
    TRIGGER_CHOICE=$(normalize_trigger_choice "$(jq -r '.trigger_choice // "1"' "$CONFIG_FILE")")
    FLEET_PRIVATE_KEY=$(jq -r '.fleet_private_key // empty' "$CONFIG_FILE")
    
    MATRIX_BOT_TOKEN=$(jq -r '.matrix_bot_token // ""' "$CONFIG_FILE")
    MATRIX_ROOM_ID=$(jq -r '.matrix_room_id // ""' "$CONFIG_FILE")
    MATRIX_HOMESERVER=$(jq -r '.matrix_homeserver // ""' "$CONFIG_FILE")
    WEBHOOK_SECRET=$(jq -r '.webhook_secret // ""' "$CONFIG_FILE")
    BOOTSTRAP_MODE=$(normalize_bool "$(jq -r '.bootstrap_mode // empty' "$CONFIG_FILE")")
    IS_CONTROLLER=$(normalize_bool "$(jq -r '.is_controller // empty' "$CONFIG_FILE")")
    NODE_ROLE=$(jq -r '.node_role // "worker"' "$CONFIG_FILE")
    NODE_SSH_PUB_KEY=$(jq -r '.node_ssh_pub_key // empty' "$CONFIG_FILE")
    STATIC_IP=$(jq -r '.static_ip // empty' "$CONFIG_FILE")
    STATIC_GATEWAY=$(jq -r '.static_gateway // empty' "$CONFIG_FILE")
    STATIC_PREFIX_LENGTH=$(jq -r '.static_prefix_length // empty' "$CONFIG_FILE")
    STATIC_DNS=$(jq -r '.static_dns // empty | if type == "array" then join(" ") else . end' "$CONFIG_FILE")
    STATIC_INTERFACE=$(jq -r '.static_interface // empty' "$CONFIG_FILE")

    if [ -z "$GIT_USER" ] || [ -z "$GIT_TOKEN" ] || [ -z "$REPO_URL" ] || [ -z "$NODE_ADMIN" ] || [ -z "$NODE_ADMIN_PASS" ]; then
        echo "Error: Missing required fields in config file."
        exit 1
    fi
fi

if [ "$DIRECT_INPUT" = true ]; then
    NON_INTERACTIVE=true
    [ -n "$ARG_GIT_USER" ] && GIT_USER="$ARG_GIT_USER"
    [ -n "$ARG_GIT_TOKEN" ] && GIT_TOKEN="$ARG_GIT_TOKEN"
    [ -n "$ARG_REPO_URL" ] && REPO_URL="$ARG_REPO_URL"
    [ -n "$ARG_NODE_GROUP" ] && NODE_GROUP="$ARG_NODE_GROUP"
    [ -n "$ARG_NODE_ADMIN" ] && NODE_ADMIN="$ARG_NODE_ADMIN"
    [ -n "$ARG_NODE_ADMIN_PASS" ] && NODE_ADMIN_PASS="$ARG_NODE_ADMIN_PASS"
    [ -n "$ARG_TRIGGER_CHOICE" ] && TRIGGER_CHOICE="$ARG_TRIGGER_CHOICE"
    [ -n "$ARG_FLEET_PRIVATE_KEY" ] && FLEET_PRIVATE_KEY="$ARG_FLEET_PRIVATE_KEY"
    [ -n "$ARG_MATRIX_BOT_TOKEN" ] && MATRIX_BOT_TOKEN="$ARG_MATRIX_BOT_TOKEN"
    [ -n "$ARG_MATRIX_ROOM_ID" ] && MATRIX_ROOM_ID="$ARG_MATRIX_ROOM_ID"
    [ -n "$ARG_MATRIX_HOMESERVER" ] && MATRIX_HOMESERVER="$ARG_MATRIX_HOMESERVER"
    [ -n "$ARG_WEBHOOK_SECRET" ] && WEBHOOK_SECRET="$ARG_WEBHOOK_SECRET"
    [ -n "$ARG_BOOTSTRAP_MODE" ] && BOOTSTRAP_MODE="$ARG_BOOTSTRAP_MODE"
    [ -n "$ARG_IS_CONTROLLER" ] && IS_CONTROLLER="$ARG_IS_CONTROLLER"
    [ -n "$ARG_NODE_ROLE" ] && NODE_ROLE="$ARG_NODE_ROLE"
    [ -n "$ARG_NODE_SSH_PUB_KEY" ] && NODE_SSH_PUB_KEY="$ARG_NODE_SSH_PUB_KEY"
    [ -n "$ARG_STATIC_IP" ] && STATIC_IP="$ARG_STATIC_IP"
    [ -n "$ARG_STATIC_GATEWAY" ] && STATIC_GATEWAY="$ARG_STATIC_GATEWAY"
    [ -n "$ARG_STATIC_PREFIX_LENGTH" ] && STATIC_PREFIX_LENGTH="$ARG_STATIC_PREFIX_LENGTH"
    [ -n "$ARG_STATIC_DNS" ] && STATIC_DNS="$ARG_STATIC_DNS"
    [ -n "$ARG_STATIC_INTERFACE" ] && STATIC_INTERFACE="$ARG_STATIC_INTERFACE"

    NODE_GROUP=${NODE_GROUP:-default}
    TRIGGER_CHOICE=${TRIGGER_CHOICE:-1}
    NODE_ROLE=${NODE_ROLE:-worker}
    STATIC_PREFIX_LENGTH=${STATIC_PREFIX_LENGTH:-24}

    if [ -n "$CONFIG_FILE" ]; then
        log "Applying command-line flag overrides on top of $CONFIG_FILE..."
    else
        log "Non-interactive mode enabled. Reading from command-line flags..."
    fi

    if [ -z "$GIT_USER" ] || [ -z "$GIT_TOKEN" ] || [ -z "$REPO_URL" ] || [ -z "$NODE_ADMIN" ] || [ -z "$NODE_ADMIN_PASS" ]; then
        echo "Error: Missing required enrollment fields. Provide them via --config, direct flags, or interactive prompts."
        exit 1
    fi
fi

if [ "$NON_INTERACTIVE" != true ]; then
    NODE_ROLE="worker"
fi

if [ -n "$NODE_ROLE" ] && [ -z "$IS_CONTROLLER" ]; then
    if [ "$NODE_ROLE" = "controller" ]; then
        IS_CONTROLLER="true"
    else
        IS_CONTROLLER="false"
    fi
fi

if [ -n "$STATIC_IP" ] || [ -n "$STATIC_GATEWAY" ] || [ -n "$STATIC_PREFIX_LENGTH" ] || [ -n "$STATIC_DNS" ] || [ -n "$STATIC_INTERFACE" ]; then
    [ -n "$STATIC_IP" ] || { echo "Error: --static-ip is required with static networking flags."; exit 1; }
    [ -n "$STATIC_GATEWAY" ] || { echo "Error: --static-gateway is required with static networking flags."; exit 1; }
    [ -n "$STATIC_PREFIX_LENGTH" ] || { echo "Error: --static-prefix-length is required with static networking flags."; exit 1; }
    [ -n "$STATIC_DNS" ] || { echo "Error: --static-dns is required with static networking flags."; exit 1; }
    [ -n "$STATIC_INTERFACE" ] || { echo "Error: --static-interface is required with static networking flags."; exit 1; }
    STATIC_DNS="$(format_dns_list "$STATIC_DNS")"
fi

if [ -n "$BOOTSTRAP_MODE" ]; then
    log "bootstrap_mode=$BOOTSTRAP_MODE requested. This flag is accepted for config parity but does not currently change installer behavior."
fi

if [ "$NON_INTERACTIVE" != true ]; then
    read -p "Enter Git Host Admin/Deploy Username: " GIT_USER
    read -s -p "Enter Git Access Token: " GIT_TOKEN
    echo ""
    read -p "Enter Fleet Repository URL (HTTPS): " REPO_URL

    read -p "Enter the group/tier for this node (e.g., media, signaling, db) [default]: " NODE_GROUP
    NODE_GROUP=${NODE_GROUP:-default}

    read -p "SETUP ADMIN USERNAME (for this node): " NODE_ADMIN
    read -s -p "SETUP PASSWORD FOR $NODE_ADMIN: " NODE_ADMIN_PASS
    echo ""
    read -s -p "Enter Shared Fleet Private Age Key (Leave blank to generate a new unique key): " FLEET_PRIVATE_KEY
    echo ""
    echo "Select Update Trigger Method:"
    echo "1) Matrix Pub/Sub (Default)"
    echo "2) Webhook (Forgejo/GitLab/GitHub)"
    read -p "Enter choice [1 or 2]: " TRIGGER_CHOICE
    if [ "$TRIGGER_CHOICE" != "2" ]; then
        TRIGGER_CHOICE="1"
    fi
    echo ""
fi

REPO_NAME=$(basename "$REPO_URL" .git)
TARGET_DIR="/home/nops/$REPO_NAME"

# Installs a shared fleet age key if provided, or generates a unique node key if none exists at /var/lib/sops-nix/key.txt.
KEY_FILE="/var/lib/sops-nix/key.txt"
sudo mkdir -p "$(dirname "$KEY_FILE")"

if [ -n "$FLEET_PRIVATE_KEY" ]; then
    log "FLEET_PRIVATE_KEY environment variable detected. Using shared fleet key..."
    echo "$FLEET_PRIVATE_KEY" | sudo tee "$KEY_FILE" > /dev/null
    sudo chmod 600 "$KEY_FILE"
    sudo chown root:root "$KEY_FILE"
elif [ ! -f "$KEY_FILE" ]; then
    log "No shared key provided. Generating new Age key..."
    sudo age-keygen -o "$KEY_FILE"
    sudo chmod 600 "$KEY_FILE"
    sudo chown root:root "$KEY_FILE"
    warn "A unique key was generated. Manual SOPS authorization will be required on another node."
fi

PUB_KEY=$(sudo age-keygen -y "$KEY_FILE")
log "Active Public Key: $PUB_KEY"

# Clones the fleet repository with URL-encoded credentials into /home/nops/<repo-name>. Marks the directory safe for root rebuilds.
if [ -d "$TARGET_DIR" ]; then
    log "Cleaning existing fleet directory..."
    sudo rm -rf "$TARGET_DIR"
fi

log "Cloning Fleet Repository into $TARGET_DIR..."

ENCODED_TOKEN=$(jq -nr --arg v "$GIT_TOKEN" '$v | @uri')
CLEAN_REPO_URL=$(echo "$REPO_URL" | sed 's|https://||')

sudo env GIT_CONFIG_NOSYSTEM=1 git clone "https://$GIT_USER:$ENCODED_TOKEN@$CLEAN_REPO_URL" "$TARGET_DIR"
sudo chown -R nops:nops "$TARGET_DIR"

sudo git config --global --add safe.directory "$TARGET_DIR"
sudo -u nops git config --global --add safe.directory "$TARGET_DIR"

cd "$TARGET_DIR"

# Ensures the standard fleet directory structure exists and bootstraps a base flake.nix if the repo is empty.
log "Ensuring fleet root directory structure..."
sudo -u nops mkdir -p modules secrets scripts groups nodes
sudo -u nops touch modules/.keep secrets/.keep scripts/.keep groups/.keep nodes/.keep

if [ ! -f "flake.nix" ]; then
    log "Empty fleet repository detected. Initializing base flake..."
    sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/flake.nix" "$TARGET_DIR/flake.nix"
    sudo -u nops chmod u+w "$TARGET_DIR/flake.nix"
fi

# Creates the group and node config directories from templates if they don't already exist.
GROUP_DIR="$TARGET_DIR/groups/$NODE_GROUP"
if [ ! -d "$GROUP_DIR" ]; then
    log "Group '$NODE_GROUP' not found. Initializing group templates..."
    sudo -u nops mkdir -p "$GROUP_DIR"

    echo "{ config, pkgs, ... }: {
  # Group-level NixOS options for the $NODE_GROUP tier.
}" | sudo -u nops tee "$GROUP_DIR/configuration.nix" > /dev/null

    sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/imports.nix" "$GROUP_DIR/imports.nix"
    sudo -u nops chmod -R u+w "$GROUP_DIR"
fi

NODE_DIR="$TARGET_DIR/nodes/$HOSTNAME"
log "Creating node directory at $NODE_DIR linked to group '$NODE_GROUP'..."
sudo -u nops mkdir -p "$NODE_DIR"

sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/configuration.nix" "$NODE_DIR/configuration.nix"

# Generate the node's imports.nix pointing to the selected group
echo "{ config, pkgs, ... }: {
  imports = [
    ../../groups/$NODE_GROUP/configuration.nix
    ../../groups/$NODE_GROUP/imports.nix
  ];
}" | sudo -u nops tee "$NODE_DIR/imports.nix" > /dev/null
sudo -u nops chmod u+w "$NODE_DIR/imports.nix"

if [ -f "/etc/nixos/hardware-configuration.nix" ]; then
    sudo cp /etc/nixos/hardware-configuration.nix "$NODE_DIR/hardware-configuration.nix"
    sudo chown nops:nops "$NODE_DIR/hardware-configuration.nix"
fi

# Substitutes installer-collected values into the node config: hostname, admin user, repo path, and trigger mode.
log "Hydrating node configuration..."
sudo -u nops sed -i "s|networking.hostName = \".*\";|networking.hostName = \"$HOSTNAME\";|" "$NODE_DIR/configuration.nix"
sudo -u nops sed -i "s|users.users.tdavis|users.users.$NODE_ADMIN|" "$NODE_DIR/configuration.nix"
sudo -u nops sed -i "s|initialPassword = \".*\";|initialPassword = \"$NODE_ADMIN_PASS\";|" "$NODE_DIR/configuration.nix"
sudo -u nops sed -i "s|repoPath = \".*\";|repoPath = \"$TARGET_DIR\";|" "$NODE_DIR/configuration.nix"

if [ -n "$NODE_SSH_PUB_KEY" ]; then
        cat <<EOF | sudo -u nops tee -a "$NODE_DIR/configuration.nix" > /dev/null

    users.users.${NODE_ADMIN}.openssh.authorizedKeys.keys = [
        "${NODE_SSH_PUB_KEY}"
    ];
EOF
fi

if [ -n "$STATIC_IP" ] && [ -n "$STATIC_GATEWAY" ] && [ -n "$STATIC_INTERFACE" ]; then
        log "Configuring static IP: $STATIC_IP on $STATIC_INTERFACE..."
        sudo -u nops sed -i "s|networking.networkmanager.enable = true;|networking.networkmanager.enable = false;|" "$NODE_DIR/configuration.nix"
        cat <<EOF | sudo -u nops tee -a "$NODE_DIR/configuration.nix" > /dev/null

    networking.interfaces.${STATIC_INTERFACE}.ipv4.addresses = [{ address = "${STATIC_IP}"; prefixLength = ${STATIC_PREFIX_LENGTH}; }];
    networking.defaultGateway = "${STATIC_GATEWAY}";
    networking.nameservers = [ ${STATIC_DNS} ];
EOF
fi

if [ -n "$IS_CONTROLLER" ]; then
        cat <<EOF | sudo -u nops tee -a "$NODE_DIR/configuration.nix" > /dev/null

    services.nops.isController = ${IS_CONTROLLER};
EOF
fi

if [ "$TRIGGER_CHOICE" == "2" ]; then
    sudo -u nops sed -i "s|MATRIX_ENABLE_PLACEHOLDER|false|" "$NODE_DIR/configuration.nix"
    sudo -u nops sed -i "s|WEBHOOK_ENABLE_PLACEHOLDER|true|" "$NODE_DIR/configuration.nix"
else
    sudo -u nops sed -i "s|MATRIX_ENABLE_PLACEHOLDER|true|" "$NODE_DIR/configuration.nix"
    sudo -u nops sed -i "s|WEBHOOK_ENABLE_PLACEHOLDER|false|" "$NODE_DIR/configuration.nix"
fi

# Adds this node's age public key to .sops.yaml and injects its nixosConfiguration into flake.nix via NODES_MARKER.
SOPS_CONFIG="$TARGET_DIR/.sops.yaml"
SECRETS_FILE="$TARGET_DIR/secrets/secrets.yaml"

log "Updating Fleet SOPS configuration..."
if [ ! -f "$SOPS_CONFIG" ]; then
    sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/.sops.yaml" "$SOPS_CONFIG"
    sudo -u nops chmod u+w "$SOPS_CONFIG"
fi

if ! grep -q "$PUB_KEY" "$SOPS_CONFIG"; then
    log "Adding public key to SOPS config..."
    if ! grep -q "creation_rules:" "$SOPS_CONFIG"; then
        sudo -u nops sed -i '1icreation_rules:' "$SOPS_CONFIG"
    fi
    sudo -u nops sed -i "/- age:/a \        - $PUB_KEY" "$SOPS_CONFIG"
fi

log "Adding node to Fleet flake.nix..."
if ! grep -q "nixosConfigurations.$HOSTNAME" "$TARGET_DIR/flake.nix"; then
    sudo -u nops sed -i "/# NODES_MARKER/a \    nixosConfigurations.$HOSTNAME = nixpkgs.lib.nixosSystem { system = \"x86_64-linux\"; modules = [ ./nodes/$HOSTNAME/configuration.nix nops.nixosModules.default ]; };" "$TARGET_DIR/flake.nix"
else
    log "Node $HOSTNAME already exists in flake.nix. Skipping insertion."
fi

# Creates and SOPS-encrypts secrets.yaml on first enrollment; updates SOPS keys on subsequent runs.
if [ ! -f "$SECRETS_FILE" ]; then
    log "Initializing global secrets file..."
    sudo -u nops mkdir -p "$(dirname "$SECRETS_FILE")"
    sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/secrets.yaml" "$SECRETS_FILE"
    sudo -u nops sed -i "s|git_username:.*|git_username: \"$GIT_USER\"|" "$SECRETS_FILE"
    sudo -u nops sed -i "s|git_password:.*|git_password: \"$GIT_TOKEN\"|" "$SECRETS_FILE"

    if [ "$NON_INTERACTIVE" = true ]; then
        log "Injecting secrets from config file..."
        sudo -u nops sed -i "s|matrix_bot_token:.*|matrix_bot_token: \"$MATRIX_BOT_TOKEN\"|" "$SECRETS_FILE"
        sudo -u nops sed -i "s|matrix_room_id:.*|matrix_room_id: \"$MATRIX_ROOM_ID\"|" "$SECRETS_FILE"
        sudo -u nops sed -i "s|matrix_homeserver:.*|matrix_homeserver: \"$MATRIX_HOMESERVER\"|" "$SECRETS_FILE"
        sudo -u nops sed -i "s|webhook_secret:.*|webhook_secret: \"$WEBHOOK_SECRET\"|" "$SECRETS_FILE"
    else
        log "Opening secrets/secrets.yaml for Matrix setup..."
        read -p "Press Enter to open editor (Ensure Matrix credentials are set)..."
        sudo -u nops vim "$SECRETS_FILE"
    fi

    sudo -u nops sops --config "$SOPS_CONFIG" --encrypt --in-place "$SECRETS_FILE"
else
    log "Global secrets file exists. Attempting key update..."
    if ! sudo -u nops sops updatekeys -y "$SECRETS_FILE" 2>/dev/null; then
        warn "Manual authorization required on another node for this key."
    fi
fi

# Opens the node config in an editor before committing, allowing manual adjustments such as static IP.
if [ "$NON_INTERACTIVE" != true ]; then
    log "Opening node configuration for manual adjustments (e.g., networking, static IP)..."
    read -p "Press Enter to open editor ($NODE_DIR/configuration.nix)..."
    sudo -u nops vim "$NODE_DIR/configuration.nix"
else
    log "Skipping manual node configuration (Non-interactive mode)."
fi


# Commits all scaffolded files and pushes the enrollment to origin/main.
log "Pushing enrollment to Fleet repository..."
sudo -u nops git config user.email "nops-installer@$HOSTNAME"
sudo -u nops git config user.name "nops Installer"
sudo -u nops git add .
sudo -u nops git commit -m "Enrollment: $HOSTNAME (Group: $NODE_GROUP)" || log "No changes to commit."

sudo -u nops env GIT_CONFIG_NOSYSTEM=1 git push origin main

log "Hardening Git security..."
sudo -u nops git remote set-url origin "$REPO_URL"

# Triggers the initial nixos-rebuild to activate the enrolled configuration.
log "Executing initial system rebuild..."
if ! sudo nixos-rebuild switch --flake "$TARGET_DIR#$HOSTNAME" --upgrade --impure; then
    warn "Initial rebuild failed. Check secrets authorization or syntax errors and run activation manually."
fi

echo -e "${GREEN}[SUCCESS]${NC} Enrollment complete."