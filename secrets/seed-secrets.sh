#!/bin/bash
# Processes a YAML list of secret definitions and writes each secret into Azure Key Vault.
#
# Required environment variables:
#   ENV           Deployment environment (e.g. dev, staging, prod)
#   REPO_NAME     Repository name — used as the default KV secret namespace
#   KV_NAME       Azure Key Vault name
#   SECRETS_INPUT YAML list of secret definitions (passed via action input)
#
# Supported secret types:
#
#   - rsa-key:
#     length:      RSA key size in bits (optional, default: 2048)
#     private-key: path for the private key  (e.g. MY_PRIVATE_KEY or repo/MY_PRIVATE_KEY)
#     public-key:  path for the public key   (e.g. common/MY_PUBLIC_KEY)
#     overwrite:   regenerate even if the private key already exists (optional, default: false)
#
#   - password:
#     length:      password length in characters (optional, default: 20)
#     name:        path for the password value   (e.g. common/MY_PASSWORD)
#     overwrite:   regenerate even if the key already exists (optional, default: false)
#
#   - random:
#     length:      number of random bytes to generate (optional, default: 32)
#     encoding:    output encoding — 'hex' or 'base64' (optional, default: hex)
#     name:        path for the encoded value
#     overwrite:   regenerate even if the key already exists (optional, default: false)
#
# Path format: "[namespace/]KEY_NAME"
#   With namespace:    writes to KV secret "{ENV}--{namespace}", key "{KEY_NAME}"
#   Without namespace: writes to KV secret "{ENV}--{REPO_NAME}", key "{KEY_NAME}"
#
# Each KV secret is fetched at most once and written at most once (only when changed).

set -euo pipefail

: "${ENV:?}"
: "${REPO_NAME:?}"
: "${KV_NAME:?}"
: "${SECRETS_INPUT:?}"

# Associative arrays used as a per-secret cache.
#   FETCHED[secret] = original JSON fetched from KV (used for change detection)
#   PENDING[secret] = accumulated JSON after all staged updates
declare -A FETCHED
declare -A PENDING

# Resolve "[namespace/]KEY" → prints "<kv-secret-name> <json-key>" on one line.
resolve_path() {
  local path="$1"
  if [[ "$path" == */* ]]; then
    echo "${ENV}--${path%%/*} ${path#*/}"
  else
    echo "${ENV}--${REPO_NAME} ${path}"
  fi
}

# Fetch a KV secret into the cache (no-op if already cached).
fetch_secret() {
  local secret="$1"
  if [ -z "${FETCHED[$secret]+x}" ]; then
    local val
    val=$(az keyvault secret show \
      --vault-name "$KV_NAME" --name "$secret" \
      --query 'value' -o tsv 2>/dev/null || echo '')
    if [ -z "$val" ] || ! echo "$val" | jq empty 2>/dev/null; then
      val='{}'
    fi
    FETCHED[$secret]="$val"
    PENDING[$secret]="$val"
  fi
}

# Stage a key/value update for a secret.
# Skips if the key already exists and overwrite is not true.
stage_update() {
  local secret="$1" json_key="$2" value="$3" overwrite="${4:-false}"
  fetch_secret "$secret"
  if [ "$overwrite" != "true" ] && \
     echo "${PENDING[$secret]}" | jq -e --arg k "$json_key" 'has($k)' >/dev/null 2>&1; then
    echo "::notice::Key '$json_key' in secret '$secret' already exists — skipping. Set overwrite: true to regenerate."
    return 0
  fi
  PENDING[$secret]=$(echo "${PENDING[$secret]}" | jq --arg k "$json_key" --arg v "$value" '.[$k] = $v')
}

# ── Process secret items ────────────────────────────────────────────────────

COUNT=$(echo "$SECRETS_INPUT" | yq '. | length')

for i in $(seq 0 $((COUNT - 1))); do
  ITEM=$(echo "$SECRETS_INPUT" | yq ".[$i]")

  # ── rsa-key ───────────────────────────────────────────────────────────────
  if [ "$(echo "$ITEM" | yq 'has("rsa-key")')" = "true" ]; then
    LENGTH=$(echo "$ITEM" | yq '.length // 2048')
    OVERWRITE=$(echo "$ITEM" | yq '.overwrite // "false"')
    PRIVATE_KEY_PATH=$(echo "$ITEM" | yq '.["private-key"]')
    PUBLIC_KEY_PATH=$(echo  "$ITEM" | yq '.["public-key"]')

    read -r PRIV_SECRET PRIV_JSON_KEY <<< "$(resolve_path "$PRIVATE_KEY_PATH")"

    # Check before generating to avoid a wasted keygen when not overwriting.
    fetch_secret "$PRIV_SECRET"
    if [ "$OVERWRITE" != "true" ] && \
       echo "${PENDING[$PRIV_SECRET]}" | jq -e --arg k "$PRIV_JSON_KEY" 'has($k)' >/dev/null 2>&1; then
      echo "::notice::RSA key '$PRIV_JSON_KEY' in secret '$PRIV_SECRET' already exists — skipping. Set overwrite: true to regenerate."
      continue
    fi

    KEY_DIR=$(mktemp -d)
    openssl genpkey -out "$KEY_DIR/private.pem" -algorithm RSA \
      -pkeyopt "rsa_keygen_bits:${LENGTH}" &>/dev/null
    openssl pkey -pubout -inform pem -outform pem \
      -in "$KEY_DIR/private.pem" -out "$KEY_DIR/public.pem" &>/dev/null

    PRIVATE_KEY=$(cat "$KEY_DIR/private.pem")
    PUBLIC_KEY=$(cat  "$KEY_DIR/public.pem")
    echo "::add-mask::$PRIVATE_KEY"
    rm -rf "$KEY_DIR"

    stage_update "$PRIV_SECRET" "$PRIV_JSON_KEY" "$PRIVATE_KEY" "$OVERWRITE"

    read -r PUB_SECRET PUB_JSON_KEY <<< "$(resolve_path "$PUBLIC_KEY_PATH")"
    stage_update "$PUB_SECRET" "$PUB_JSON_KEY" "$PUBLIC_KEY" "$OVERWRITE"

  # ── random ────────────────────────────────────────────────────────────────
  elif [ "$(echo "$ITEM" | yq 'has("random")')" = "true" ]; then
    LENGTH=$(echo "$ITEM" | yq '.length // 32')
    OVERWRITE=$(echo "$ITEM" | yq '.overwrite // "false"')
    ENCODING=$(echo "$ITEM" | yq '.encoding // "hex"')
    NAME_PATH=$(echo "$ITEM" | yq '.name')

    case "$ENCODING" in
      hex)    VALUE=$(openssl rand -hex    "$LENGTH") ;;
      base64) VALUE=$(openssl rand -base64 "$LENGTH") ;;
      *)
        echo "::error::Unsupported encoding '$ENCODING' for random secret — use 'hex' or 'base64'."
        exit 1
        ;;
    esac
    echo "::add-mask::$VALUE"

    read -r RND_SECRET RND_JSON_KEY <<< "$(resolve_path "$NAME_PATH")"
    stage_update "$RND_SECRET" "$RND_JSON_KEY" "$VALUE" "$OVERWRITE"

  # ── password ──────────────────────────────────────────────────────────────
  elif [ "$(echo "$ITEM" | yq 'has("password")')" = "true" ]; then
    LENGTH=$(echo "$ITEM" | yq '.length // 20')
    OVERWRITE=$(echo "$ITEM" | yq '.overwrite // "false"')
    NAME_PATH=$(echo "$ITEM" | yq '.name')

    # Retry loop: each iteration may yield fewer than LENGTH alphanumeric
    # characters after filtering, so keep trying until we have exactly enough.
    PASSWORD=''
    while [ ${#PASSWORD} -lt "$LENGTH" ]; do
      PASSWORD=$(openssl rand -base64 $((LENGTH * 2)) | tr -dc 'A-Za-z0-9' | head -c "$LENGTH" || true)
    done
    echo "::add-mask::$PASSWORD"

    read -r PWD_SECRET PWD_JSON_KEY <<< "$(resolve_path "$NAME_PATH")"
    stage_update "$PWD_SECRET" "$PWD_JSON_KEY" "$PASSWORD" "$OVERWRITE"
  fi
done

# ── Flush: write each changed secret exactly once ───────────────────────────

for secret in "${!PENDING[@]}"; do
  original=$(echo "${FETCHED[$secret]}" | jq -c .)
  updated=$(echo  "${PENDING[$secret]}"  | jq -c .)
  if [ "$updated" = "$original" ]; then
    echo "::notice::No changes to Key Vault secret '$secret' — skipping write."
    continue
  fi
  az keyvault secret set \
    --vault-name "$KV_NAME" --name "$secret" \
    --value "$updated" --output none
  echo "::notice::Written updated secret '$secret' to Key Vault '$KV_NAME'."
done
