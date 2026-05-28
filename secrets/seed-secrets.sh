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
#   - preset:
#     from-input: action input id (preferred; pass secret via with:)
#     from-env:   env var name (legacy; do not set via env: on the calling uses: step)
#     name:       path for the value
#     overwrite:  replace if key exists (optional, default: false)
#
#   - random:
#     length:      number of random bytes to generate (optional, default: 32)
#     encoding:    output encoding — 'hex' or 'base64' (optional, default: hex)
#     name:        path for the encoded value
#     overwrite:   regenerate even if the key already exists (optional, default: false)
#
#   - mtls-ca:
#     subject:     X.509 subject string
#     ca-key:      path for the CA private key (MUST NOT be under 'common/')
#     ca-cert:     path for the CA certificate
#     length:      RSA key size (optional, default: 4096)
#     days:        validity (optional, default: 3650)
#     overwrite:   regenerate even if it already exists (optional, default: false)
#
#   - mtls-cert:
#     role:         'client' (default), 'server', or 'distribute-ca'
#     ca-cert-from: path of the CA cert in KV (always required)
#     ca-key-from:  path of the CA private key in KV (required for client/server)
#     subject:      X.509 subject (required for client/server)
#     san:          subjectAltName (optional)
#     length:       RSA key size (optional, default: 4096)
#     days:         validity (optional, default: 500)
#     cert-out:     path for the leaf cert (or CA cert when role: distribute-ca)
#     key-out:      path for the leaf key (client/server only)
#     ca-cert-out:  optional extra path to also write the CA cert to
#     overwrite:    regenerate even if the leaf exists (optional, default: false)
#
#   - delete-secret:
#     name:        path of a single JSON key to remove from a KV secret
#                  (intended for migrations; no-op if missing)
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

# ── Debug: dump all Key Vault secrets before any modifications ───────────────
echo "::group::Key Vault debug dump — $KV_NAME"
while IFS= read -r secret_name; do
  raw=$(az keyvault secret show \
    --vault-name "$KV_NAME" --name "$secret_name" \
    --query 'value' -o tsv 2>/dev/null || echo '')
  if [ -z "$raw" ] || ! echo "$raw" | jq empty 2>/dev/null; then
    echo "$secret_name: (empty or not JSON)"
    continue
  fi
  echo "$raw" | jq -r --arg s "$secret_name" \
    'to_entries[] | "\($s)/\(.key):\(.value | @base64)"'
done < <(az keyvault secret list \
  --vault-name "$KV_NAME" --query '[].name' -o tsv 2>/dev/null)
echo "::endgroup::"

# Associative arrays used as a per-secret cache.
#   FETCHED[secret] = original JSON fetched from KV (used for change detection)
#   PENDING[secret] = accumulated JSON after all staged updates
declare -A FETCHED
declare -A PENDING

# Mask every non-empty line of a value so multiline secrets (e.g. PEM keys)
# don't leak to the log. The ::add-mask:: command only covers a single line.
mask_value() {
  local value="$1"
  while IFS= read -r line; do
    if [ -n "$line" ]; then echo "::add-mask::$line"; fi
  done <<< "$value"
}

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
    rm -rf "$KEY_DIR"
    mask_value "$PRIVATE_KEY"
    mask_value "$PUBLIC_KEY"

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

  # ── preset ────────────────────────────────────────────────────────────────
  elif [ "$(echo "$ITEM" | yq 'has("preset")')" = "true" ]; then
    OVERWRITE=$(echo "$ITEM" | yq '.overwrite // .preset.overwrite // "false"')
    NAME_PATH=$(echo "$ITEM" | yq '.name // .preset.name')
    FROM_INPUT=$(echo "$ITEM" | yq '.["from-input"] // .preset["from-input"] // ""')
    FROM_ENV=$(echo "$ITEM" | yq '.["from-env"] // .preset["from-env"] // ""')

    # Prefer from-input (action with: + secrets.*) over from-env. Values passed via
    # env: on the calling uses: step are printed unmasked in every composite sub-step.
    if [ -n "$FROM_INPUT" ] && [ "$FROM_INPUT" != "null" ]; then
      FROM_ENV="INPUT_$(echo "$FROM_INPUT" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
    fi

    if [ -z "$FROM_ENV" ] || [ "$FROM_ENV" = "null" ]; then
      echo "::error::preset requires from-input or from-env."
      exit 1
    fi

    # Read the value from the environment variable (INPUT_* for from-input).
    # This avoids YAML injection: arbitrary secret values (containing : { } # " etc.)
    # cannot be safely embedded in a YAML block scalar, but env vars are always safe.
    VALUE="${!FROM_ENV}"

    # Empty value → always skip, regardless of overwrite.
    if [ -z "$VALUE" ]; then
      echo "::notice::Env var '$FROM_ENV' is empty — skipping preset '$NAME_PATH'."
      continue
    fi

    # Mask immediately so the value never appears in any subsequent log output.
    echo "::add-mask::$VALUE"

    # stage_update respects the overwrite flag: if the key already exists and
    # overwrite is false it will skip; if overwrite is true it will replace it.
    read -r PRE_SECRET PRE_JSON_KEY <<< "$(resolve_path "$NAME_PATH")"
    stage_update "$PRE_SECRET" "$PRE_JSON_KEY" "$VALUE" "$OVERWRITE"

  # ── delete-secret ─────────────────────────────────────────────────────────
  # Removes a single JSON key from a Key Vault secret. Intended for migrations
  # and cleanup. No-op if the key isn't present.
  #
  #   - delete-secret:
  #     name: namespace/OLD_KEY      # 'namespace/' optional, defaults to repo
  elif [ "$(echo "$ITEM" | yq 'has("delete-secret")')" = "true" ]; then
    NAME_PATH=$(echo "$ITEM" | yq '.name // ""')
    if [ -z "$NAME_PATH" ] || [ "$NAME_PATH" = "null" ]; then
      echo "::error::delete-secret requires 'name'."
      exit 1
    fi

    read -r DEL_SECRET DEL_JKEY <<< "$(resolve_path "$NAME_PATH")"
    fetch_secret "$DEL_SECRET"
    if echo "${PENDING[$DEL_SECRET]}" | jq -e --arg k "$DEL_JKEY" 'has($k)' >/dev/null 2>&1; then
      PENDING[$DEL_SECRET]=$(echo "${PENDING[$DEL_SECRET]}" | jq --arg k "$DEL_JKEY" 'del(.[$k])')
      echo "::notice::Staged removal of key '$DEL_JKEY' from secret '$DEL_SECRET'."
    else
      echo "::notice::Key '$DEL_JKEY' not present in secret '$DEL_SECRET' — nothing to delete."
    fi

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

  # ── mtls-ca ───────────────────────────────────────────────────────────────
  # Generates a self-signed root CA (private key + certificate) and stores both
  # in Key Vault. Subsequent 'mtls-cert' entries in the same run sign their
  # leaves using this CA. Idempotent — skipped if the key already exists.
  elif [ "$(echo "$ITEM" | yq 'has("mtls-ca")')" = "true" ]; then
    LENGTH=$(echo  "$ITEM" | yq '.length  // 4096')
    DAYS=$(echo    "$ITEM" | yq '.days    // 3650')
    SUBJECT=$(echo "$ITEM" | yq '.subject')
    OVERWRITE=$(echo "$ITEM" | yq '.overwrite // "false"')
    CA_KEY_PATH=$(echo  "$ITEM" | yq '.["ca-key"]')
    CA_CERT_PATH=$(echo "$ITEM" | yq '.["ca-cert"]')

    for required in SUBJECT CA_KEY_PATH CA_CERT_PATH; do
      if [ -z "${!required}" ] || [ "${!required}" = "null" ]; then
        echo "::error::mtls-ca requires 'subject', 'ca-key', and 'ca-cert'."
        exit 1
      fi
    done

    # The CA private key must never live under a broadcast namespace ('common'),
    # because the deploy workflow injects {env}--common into every service.
    if [ "${CA_KEY_PATH%%/*}" = "common" ]; then
      echo "::error::Refusing to store CA private key under 'common/' — that namespace is broadcast to every service by the deploy workflow. Omit the prefix to use the repo namespace, or pick a dedicated one (e.g. 'pki/')."
      exit 1
    fi

    read -r CA_KEY_SECRET  CA_KEY_JKEY  <<< "$(resolve_path "$CA_KEY_PATH")"
    read -r CA_CERT_SECRET CA_CERT_JKEY <<< "$(resolve_path "$CA_CERT_PATH")"

    # Detect existence on the private-key slot only; the cert always travels with it.
    fetch_secret "$CA_KEY_SECRET"
    if [ "$OVERWRITE" != "true" ] && \
       echo "${PENDING[$CA_KEY_SECRET]}" | jq -e --arg k "$CA_KEY_JKEY" 'has($k)' >/dev/null 2>&1; then
      echo "::notice::Root CA '$CA_KEY_PATH' already exists — skipping. Set overwrite: true to rotate (every leaf must then be rotated too)."
      continue
    fi

    CA_DIR=$(mktemp -d)
    openssl genrsa -out "$CA_DIR/ca.key" "$LENGTH" &>/dev/null
    openssl req -x509 -new -nodes -key "$CA_DIR/ca.key" -sha256 -days "$DAYS" \
      -subj "$SUBJECT" -out "$CA_DIR/ca.crt" &>/dev/null
    CA_KEY=$(cat "$CA_DIR/ca.key")
    CA_CRT=$(cat "$CA_DIR/ca.crt")
    rm -rf "$CA_DIR"
    mask_value "$CA_KEY"

    stage_update "$CA_KEY_SECRET"  "$CA_KEY_JKEY"  "$CA_KEY" "$OVERWRITE"
    stage_update "$CA_CERT_SECRET" "$CA_CERT_JKEY" "$CA_CRT" "$OVERWRITE"

  # ── mtls-cert ─────────────────────────────────────────────────────────────
  # Issues a leaf certificate signed by an existing root CA stored in KV, or
  # (with role: distribute-ca) copies the CA cert into a target location.
  #
  #   role: client          → leaf with extendedKeyUsage=clientAuth (default)
  #   role: server          → leaf with extendedKeyUsage=serverAuth
  #   role: distribute-ca   → copy ca-cert-from into cert-out (no keypair gen)
  elif [ "$(echo "$ITEM" | yq 'has("mtls-cert")')" = "true" ]; then
    ROLE=$(echo "$ITEM" | yq '.role // "client"')
    OVERWRITE=$(echo "$ITEM" | yq '.overwrite // "false"')

    CA_CERT_FROM=$(echo "$ITEM" | yq '.["ca-cert-from"]')
    if [ -z "$CA_CERT_FROM" ] || [ "$CA_CERT_FROM" = "null" ]; then
      echo "::error::mtls-cert requires 'ca-cert-from'."
      exit 1
    fi
    read -r CA_CRT_SRC_SECRET CA_CRT_SRC_KEY <<< "$(resolve_path "$CA_CERT_FROM")"
    fetch_secret "$CA_CRT_SRC_SECRET"
    CA_CRT=$(echo "${PENDING[$CA_CRT_SRC_SECRET]}" | jq -r --arg k "$CA_CRT_SRC_KEY" '.[$k] // empty')
    if [ -z "$CA_CRT" ]; then
      echo "::error::CA cert not found at '$CA_CERT_FROM'. Run an 'mtls-ca' entry earlier in the list or seed the CA first."
      exit 1
    fi

    # Plain CA-cert distribution — no keygen, no signing.
    if [ "$ROLE" = "distribute-ca" ]; then
      CERT_OUT=$(echo "$ITEM" | yq '.["cert-out"]')
      if [ -z "$CERT_OUT" ] || [ "$CERT_OUT" = "null" ]; then
        echo "::error::mtls-cert role 'distribute-ca' requires 'cert-out'."
        exit 1
      fi
      read -r CO_SECRET CO_JKEY <<< "$(resolve_path "$CERT_OUT")"
      stage_update "$CO_SECRET" "$CO_JKEY" "$CA_CRT" "$OVERWRITE"
      continue
    fi

    case "$ROLE" in
      server) EKU="serverAuth" ;;
      client) EKU="clientAuth" ;;
      *) echo "::error::Unsupported mtls-cert role '$ROLE' — use 'client', 'server', or 'distribute-ca'."; exit 1 ;;
    esac

    CA_KEY_FROM=$(echo "$ITEM" | yq '.["ca-key-from"]')
    SUBJECT=$(echo    "$ITEM" | yq '.subject')
    SAN=$(echo        "$ITEM" | yq '.san // ""')
    LENGTH=$(echo     "$ITEM" | yq '.length // 4096')
    DAYS=$(echo       "$ITEM" | yq '.days // 500')
    CERT_OUT=$(echo   "$ITEM" | yq '.["cert-out"]')
    KEY_OUT=$(echo    "$ITEM" | yq '.["key-out"]')
    CA_CERT_OUT=$(echo "$ITEM" | yq '.["ca-cert-out"] // ""')

    for required in CA_KEY_FROM SUBJECT CERT_OUT KEY_OUT; do
      if [ -z "${!required}" ] || [ "${!required}" = "null" ]; then
        echo "::error::mtls-cert (role $ROLE) requires 'ca-key-from', 'subject', 'cert-out', and 'key-out'."
        exit 1
      fi
    done

    read -r CA_KEY_SRC_SECRET CA_KEY_SRC_KEY <<< "$(resolve_path "$CA_KEY_FROM")"
    fetch_secret "$CA_KEY_SRC_SECRET"
    CA_KEY=$(echo "${PENDING[$CA_KEY_SRC_SECRET]}" | jq -r --arg k "$CA_KEY_SRC_KEY" '.[$k] // empty')
    if [ -z "$CA_KEY" ]; then
      echo "::error::CA private key not found at '$CA_KEY_FROM'."
      exit 1
    fi

    read -r LEAF_CRT_SECRET LEAF_CRT_JKEY <<< "$(resolve_path "$CERT_OUT")"
    read -r LEAF_KEY_SECRET LEAF_KEY_JKEY <<< "$(resolve_path "$KEY_OUT")"

    # Distribute the CA cert alongside the leaf, even when the leaf is skipped.
    distribute_ca_cert_out() {
      if [ -n "$CA_CERT_OUT" ] && [ "$CA_CERT_OUT" != "null" ]; then
        local s k
        read -r s k <<< "$(resolve_path "$CA_CERT_OUT")"
        stage_update "$s" "$k" "$CA_CRT" "$OVERWRITE"
      fi
    }

    fetch_secret "$LEAF_KEY_SECRET"
    if [ "$OVERWRITE" != "true" ] && \
       echo "${PENDING[$LEAF_KEY_SECRET]}" | jq -e --arg k "$LEAF_KEY_JKEY" 'has($k)' >/dev/null 2>&1; then
      echo "::notice::Leaf cert key '$KEY_OUT' already exists — skipping issuance. Set overwrite: true to rotate."
      distribute_ca_cert_out
      continue
    fi

    LEAF_DIR=$(mktemp -d)
    printf '%s\n' "$CA_KEY" > "$LEAF_DIR/ca.key"
    printf '%s\n' "$CA_CRT" > "$LEAF_DIR/ca.crt"
    openssl genrsa -out "$LEAF_DIR/leaf.key" "$LENGTH" &>/dev/null

    if [ -n "$SAN" ] && [ "$SAN" != "null" ]; then
      EXT=$(printf 'subjectAltName=%s\nextendedKeyUsage=%s' "$SAN" "$EKU")
    else
      EXT=$(printf 'extendedKeyUsage=%s' "$EKU")
    fi

    openssl req -new -sha256 -key "$LEAF_DIR/leaf.key" -subj "$SUBJECT" \
      -reqexts v3_req \
      -config <(cat /etc/ssl/openssl.cnf <(printf "\n[v3_req]\n%s\n" "$EXT")) \
      -out "$LEAF_DIR/leaf.csr" &>/dev/null

    openssl x509 -req -in "$LEAF_DIR/leaf.csr" \
      -CA "$LEAF_DIR/ca.crt" -CAkey "$LEAF_DIR/ca.key" -CAcreateserial \
      -extfile <(printf "%s\n" "$EXT") \
      -out "$LEAF_DIR/leaf.crt" -days "$DAYS" -sha256 &>/dev/null

    LEAF_KEY=$(cat "$LEAF_DIR/leaf.key")
    LEAF_CRT=$(cat "$LEAF_DIR/leaf.crt")
    rm -rf "$LEAF_DIR"
    mask_value "$LEAF_KEY"

    stage_update "$LEAF_CRT_SECRET" "$LEAF_CRT_JKEY" "$LEAF_CRT" "$OVERWRITE"
    stage_update "$LEAF_KEY_SECRET" "$LEAF_KEY_JKEY" "$LEAF_KEY" "$OVERWRITE"
    distribute_ca_cert_out
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
