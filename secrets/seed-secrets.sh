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
#
#   - password:
#     length:      password length in characters (optional, default: 20)
#     name:        path for the password value   (e.g. common/MY_PASSWORD)
#
# Path format: "[namespace/]KEY_NAME"
#   With namespace:    writes to KV secret "{ENV}--{namespace}", key "{KEY_NAME}"
#   Without namespace: writes to KV secret "{ENV}--{REPO_NAME}", key "{KEY_NAME}"

set -euo pipefail

: "${ENV:?}"
: "${REPO_NAME:?}"
: "${KV_NAME:?}"
: "${SECRETS_INPUT:?}"

# Resolve "[namespace/]KEY" → prints "<kv-secret-name> <json-key>" on one line.
resolve_path() {
  local path="$1"
  if [[ "$path" == */* ]]; then
    echo "${ENV}--${path%%/*} ${path#*/}"
  else
    echo "${ENV}--${REPO_NAME} ${path}"
  fi
}

# Fetch the existing JSON object from a KV secret (defaulting to {}),
# set the given key to the given value, and write the result back.
# Pass overwrite=true (5th arg) to replace an existing key; otherwise the key is skipped.
update_kv_secret() {
  local kv="$1" secret="$2" json_key="$3" value="$4" overwrite="${5:-false}"
  local existing
  existing=$(az keyvault secret show \
    --vault-name "$kv" --name "$secret" \
    --query 'value' -o tsv 2>/dev/null || echo '')
  if [ -z "$existing" ] || ! echo "$existing" | jq empty 2>/dev/null; then
    existing='{}'
  fi
  if [ "$overwrite" != "true" ] && echo "$existing" | jq -e --arg k "$json_key" 'has($k)' >/dev/null 2>&1; then
    echo "::notice::Key '$json_key' in secret '$secret' already exists — skipping. Set overwrite: true to regenerate."
    return 0
  fi
  local updated
  updated=$(echo "$existing" | jq --arg k "$json_key" --arg v "$value" '.[$k] = $v')
  az keyvault secret set \
    --vault-name "$kv" --name "$secret" \
    --value "$updated" --output none
  echo "::notice::Updated '$json_key' in Key Vault secret '$secret'."
}

COUNT=$(echo "$SECRETS_INPUT" | yq '. | length')

for i in $(seq 0 $((COUNT - 1))); do
  ITEM=$(echo "$SECRETS_INPUT" | yq ".[$i]")

  # ── rsa-key ────────────────────────────────────────────────────────────────
  if [ "$(echo "$ITEM" | yq 'has("rsa-key")')" = "true" ]; then
    LENGTH=$(echo "$ITEM" | yq '.length // 2048')
    OVERWRITE=$(echo "$ITEM" | yq '.overwrite // "false"')
    PRIVATE_KEY_PATH=$(echo "$ITEM" | yq '.["private-key"]')
    PUBLIC_KEY_PATH=$(echo  "$ITEM" | yq '.["public-key"]')

    read -r PRIV_SECRET PRIV_JSON_KEY <<< "$(resolve_path "$PRIVATE_KEY_PATH")"

    # Skip key generation entirely when not overwriting and the private key already exists,
    # since the public key must remain paired with the private key.
    if [ "$OVERWRITE" != "true" ]; then
      PRIV_EXISTING=$(az keyvault secret show \
        --vault-name "$KV_NAME" --name "$PRIV_SECRET" \
        --query 'value' -o tsv 2>/dev/null || echo '')
      if echo "$PRIV_EXISTING" | jq -e --arg k "$PRIV_JSON_KEY" 'has($k)' >/dev/null 2>&1; then
        echo "::notice::RSA key '$PRIV_JSON_KEY' in secret '$PRIV_SECRET' already exists — skipping. Set overwrite: true to regenerate."
        continue
      fi
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

    update_kv_secret "$KV_NAME" "$PRIV_SECRET" "$PRIV_JSON_KEY" "$PRIVATE_KEY" "$OVERWRITE"

    read -r PUB_SECRET PUB_JSON_KEY <<< "$(resolve_path "$PUBLIC_KEY_PATH")"
    update_kv_secret "$KV_NAME" "$PUB_SECRET" "$PUB_JSON_KEY" "$PUBLIC_KEY" "$OVERWRITE"

  # ── random ─────────────────────────────────────────────────────────────────
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
    update_kv_secret "$KV_NAME" "$RND_SECRET" "$RND_JSON_KEY" "$VALUE" "$OVERWRITE"

  # ── password ───────────────────────────────────────────────────────────────
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
    update_kv_secret "$KV_NAME" "$PWD_SECRET" "$PWD_JSON_KEY" "$PASSWORD" "$OVERWRITE"
  fi
done
