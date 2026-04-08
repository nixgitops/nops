#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  migrate-legacy-passwords.sh --repo PATH

Options:
  --repo PATH      Path to the Fleet repository to migrate.
  -h, --help       Show this help text.

This command migrates legacy node configs that still use users.users.<name>.initialPassword.
For each matching nodes/<hostname>/configuration.nix file it:
  - replaces initialPassword with hashedPasswordFile
  - adds the required sops.secrets entry with neededForUsers = true
  - stores a SHA-512 password hash in secrets/secrets.yaml under admin_password_hash_<hostname>

The original plaintext password value is read from the checked-in node config, hashed locally,
and then removed from the node config as part of the migration.
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

hash_password() {
    local plaintext_password="$1"
    local -a openssl_cmd=()

    if command -v openssl >/dev/null 2>&1; then
        openssl_cmd=(openssl)
    elif command -v nix >/dev/null 2>&1; then
        openssl_cmd=(nix shell nixpkgs#openssl -c openssl)
    else
        echo "Error: openssl is required to hash passwords." >&2
        exit 1
    fi

    printf '%s' "$plaintext_password" | "${openssl_cmd[@]}" passwd -6 -stdin
}

upsert_yaml_string_key() {
    local target_file="$1"
    local yaml_key="$2"
    local raw_value="$3"

    local rendered_value
    local temp_file

    rendered_value=$(jq -Rn --arg value "$raw_value" '$value')
    temp_file=$(mktemp)

    awk -v key="$yaml_key" -v value="$rendered_value" '
        BEGIN { updated = 0 }
        index($0, key ":") == 1 {
            print key ": " value
            updated = 1
            next
        }
        { print }
        END {
            if (!updated) {
                print key ": " value
            }
        }
    ' "$target_file" > "$temp_file"

    cat "$temp_file" > "$target_file"
    rm -f "$temp_file"
}

ensure_needed_for_users_secret() {
    local config_file="$1"
    local secret_name="$2"

    if grep -Fq "\"$secret_name\" = { neededForUsers = true; };" "$config_file"; then
        return 0
    fi

    perl -0pi -e 's/sops\.secrets\s*=\s*\{\n/sops.secrets = {\n    "'"$secret_name"'" = { neededForUsers = true; };\n/s or die "failed to insert sops secret entry\n"' "$config_file"
}

extract_initial_password() {
    local config_file="$1"

    perl -ne 'if (/initialPassword\s*=\s*"([^"]*)";/) { print $1; exit 0 }' "$config_file"
}

replace_password_reference() {
    local config_file="$1"
    local secret_name="$2"

    perl -0pi -e 's/initialPassword\s*=\s*"[^"]*";/hashedPasswordFile = config.sops.secrets."'"$secret_name"'".path;/s or die "failed to replace initialPassword\n"' "$config_file"
}

REPO_PATH=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --repo)
            require_value "$1" "${2:-}"
            REPO_PATH="$2"
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

if [ -z "$REPO_PATH" ]; then
    usage
    exit 1
fi

if [ ! -d "$REPO_PATH" ]; then
    echo "Error: repo path $REPO_PATH not found." >&2
    exit 1
fi

SECRETS_FILE="$REPO_PATH/secrets/secrets.yaml"
SOPS_CONFIG="$REPO_PATH/.sops.yaml"

if [ ! -f "$SECRETS_FILE" ]; then
    echo "Error: expected secrets file at $SECRETS_FILE" >&2
    exit 1
fi

if [ ! -f "$SOPS_CONFIG" ]; then
    echo "Error: expected SOPS config at $SOPS_CONFIG" >&2
    exit 1
fi

temp_secrets=$(mktemp)
cleanup() {
    rm -f "$temp_secrets"
}
trap cleanup EXIT

if ! sops --decrypt "$SECRETS_FILE" > "$temp_secrets"; then
    echo "Error: unable to decrypt $SECRETS_FILE. Ensure your age key is authorized first." >&2
    exit 1
fi

shopt -s nullglob
migrated_nodes=0

for config_file in "$REPO_PATH"/nodes/*/configuration.nix; do
    hostname=$(basename "$(dirname "$config_file")")
    secret_name="admin_password_hash_${hostname}"

    if ! grep -Eq 'initialPassword[[:space:]]*=' "$config_file"; then
        continue
    fi

    plaintext_password=$(extract_initial_password "$config_file")
    if [ -z "$plaintext_password" ]; then
        echo "Warning: unable to extract initialPassword from $config_file; skipping." >&2
        continue
    fi

    password_hash=$(hash_password "$plaintext_password")
    upsert_yaml_string_key "$temp_secrets" "$secret_name" "$password_hash"
    replace_password_reference "$config_file" "$secret_name"
    ensure_needed_for_users_secret "$config_file" "$secret_name"
    migrated_nodes=$((migrated_nodes + 1))
done

if [ "$migrated_nodes" -eq 0 ]; then
    echo "No legacy nodes found. Nothing to migrate."
    exit 0
fi

sops --config "$SOPS_CONFIG" --encrypt --in-place "$temp_secrets"
mv "$temp_secrets" "$SECRETS_FILE"
trap - EXIT

echo "Migrated $migrated_nodes legacy node(s). Review the repo diff, then commit and push the changes."