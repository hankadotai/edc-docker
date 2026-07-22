#!/bin/sh
# Vault bootstrap + unseal + secret seeding.
#
# Run on every `docker compose up`. Idempotent and self-healing:
#
#   - first run:      initialise vault, generate unseal keys + root token,
#                     enable kv-v2, write the EDC policy, mint a periodic
#                     EDC token, store all secrets and the EDC token file
#   - subsequent run: read the unseal keys from the persistent volume,
#                     unseal the vault, refresh the EDC token if it has
#                     expired, ensure EDC secrets are in sync with .env
#
# Persistent state lives in /vault/state (a named volume that the operator
# is responsible for backing up):
#
#   init.json         output of `vault operator init` (5 unseal keys + root)
#   edc-vault.env     EDC_VAULT_HASHICORP_TOKEN=... (token for the EDC)
#
# The token file is also copied into a host-bind-mounted /host-runtime so the
# EDC services can pick it up via env_file on the next compose call.

set -eu

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
STATE_DIR="/vault/state"
INIT_FILE="${STATE_DIR}/init.json"
EDC_ENV_FILE="${STATE_DIR}/edc-vault.env"
EDC_TOKEN_PERIOD="${EDC_TOKEN_PERIOD:-720h}"

export VAULT_ADDR

mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"

# jq is not in the vanilla hashicorp/vault image — install it on first run.
# apk caches between container recreations within the same volume layer, and
# the install is fast (~3s) anyway.
if ! command -v jq >/dev/null 2>&1; then
    apk add --no-cache jq >/dev/null
fi

wait_for_vault() {
    i=0
    while ! wget -qO- "${VAULT_ADDR}/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200" >/dev/null 2>&1; do
        i=$((i+1))
        if [ "${i}" -gt 60 ]; then
            echo "vault did not become reachable in 60s" >&2
            exit 1
        fi
        sleep 1
    done
}

# Generate an Ed25519 keypair and emit it as a compact private JWK. The EDC
# signs its data-plane tokens with the vault ALIAS ("token-signer-key") as the
# kid, so the JWK's own kid is cosmetic; we set it for readability. The
# PKCS#8 / SPKI DER wrappers for Ed25519 are fixed-length, so the raw 32-byte
# keys are the trailing 32 bytes of each DER encoding.
generate_ed25519_jwk() {
    _tmp="$(mktemp)"
    openssl genpkey -algorithm ed25519 -out "${_tmp}" 2>/dev/null
    _d="$(openssl pkey -in "${_tmp}" -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
    _x="$(openssl pkey -in "${_tmp}" -pubout -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
    rm -f "${_tmp}"
    printf '{"kty":"OKP","crv":"Ed25519","kid":"token-signer-key","x":"%s","d":"%s"}' "${_x}" "${_d}"
}

wait_for_vault

INITIALIZED="$(vault status -format=json 2>/dev/null | jq -r .initialized)"

if [ "${INITIALIZED}" != "true" ]; then
    echo "=== Initialising vault (first boot) ==="
    vault operator init \
        -key-shares=5 \
        -key-threshold=3 \
        -format=json > "${INIT_FILE}"
    chmod 600 "${INIT_FILE}"

    cat <<'WARN'

###############################################################################
# *** ACTION REQUIRED ***
#
# Vault has been initialised. The unseal keys and root token live at
#
#     /vault/state/init.json   (inside the vault-state docker volume)
#
# Copy them out and store them somewhere safe (password manager, encrypted
# backup). If you lose them, the data in vault is unrecoverable.
#
# Copy via the long-running vault-unseal sidecar (this vault-init container is
# a one-shot `run --rm` and is gone the moment it exits):
#
#     docker compose up -d vault-unseal
#     docker compose cp vault-unseal:/vault/state/init.json ./vault-init.json
###############################################################################

WARN
fi

# Always ensure vault is unsealed.
SEALED="$(vault status -format=json 2>/dev/null | jq -r .sealed)"
if [ "${SEALED}" = "true" ]; then
    if [ ! -f "${INIT_FILE}" ]; then
        echo "vault is sealed but ${INIT_FILE} is missing — cannot unseal" >&2
        exit 1
    fi
    echo "=== Unsealing vault ==="
    for i in 0 1 2; do
        KEY="$(jq -r ".unseal_keys_b64[${i}]" "${INIT_FILE}")"
        vault operator unseal "${KEY}" > /dev/null
    done
fi

# Authenticate as root for setup operations.
ROOT_TOKEN="$(jq -r .root_token "${INIT_FILE}")"
export VAULT_TOKEN="${ROOT_TOKEN}"

# Enable kv-v2 at secret/ (idempotent).
if ! vault secrets list -format=json 2>/dev/null | jq -e '."secret/"' > /dev/null; then
    echo "=== Enabling kv-v2 at secret/ ==="
    vault secrets enable -path=secret -version=2 kv > /dev/null
fi

# Write the EDC policy. `policy write` is upsert.
echo "=== Writing edc policy ==="
vault policy write edc - <<'POLICY' > /dev/null
path "secret/data/sts-oauth-client-secret" { capabilities = ["read"] }
path "secret/data/token-signer-key"        { capabilities = ["read"] }
path "auth/token/renew-self"               { capabilities = ["update"] }
path "auth/token/lookup-self"              { capabilities = ["read"] }
POLICY

# Refresh EDC secrets from environment so .env stays canonical.
if [ -n "${STS_CLIENT_SECRET:-}" ]; then
    echo "=== Writing secret/sts-oauth-client-secret ==="
    vault kv put secret/sts-oauth-client-secret content="${STS_CLIENT_SECRET}" > /dev/null
else
    echo "WARNING: STS_CLIENT_SECRET is empty in environment, skipping" >&2
fi

# Data-plane signer key. The connector's data plane signs the EDR/proxy
# tokens it issues and verifies them itself, so nothing outside this host ever
# needs the key: we generate it locally and never share it (parity with
# managed-wallet dataspaces like Cofinity-X). Precedence:
#   1. operator-provided TOKEN_SIGNER_KEY_JWK        (bring-your-own-key)
#   2. a key already stored in vault from a prior boot (keep it stable)
#   3. otherwise generate a fresh Ed25519 keypair here, once
if [ -n "${TOKEN_SIGNER_KEY_JWK:-}" ]; then
    echo "=== Writing secret/token-signer-key (operator-provided) ==="
    vault kv put secret/token-signer-key content="${TOKEN_SIGNER_KEY_JWK}" > /dev/null
elif vault kv get -field=content secret/token-signer-key >/dev/null 2>&1; then
    echo "=== Data-plane signer key already in vault, keeping it ==="
else
    echo "=== Generating data-plane signer key (Ed25519) ==="
    if ! command -v openssl >/dev/null 2>&1; then
        apk add --no-cache openssl >/dev/null
    fi
    SIGNER_JWK="$(generate_ed25519_jwk)"
    vault kv put secret/token-signer-key content="${SIGNER_JWK}" > /dev/null
fi

# Mint or rotate the EDC token.
need_new_token=1
if [ -f "${EDC_ENV_FILE}" ]; then
    CURRENT_TOKEN="$(sed -n 's/^EDC_VAULT_HASHICORP_TOKEN=//p' "${EDC_ENV_FILE}")"
    if [ -n "${CURRENT_TOKEN}" ] && \
       VAULT_TOKEN="${CURRENT_TOKEN}" vault token lookup >/dev/null 2>&1; then
        need_new_token=0
    fi
fi

if [ "${need_new_token}" -eq 1 ]; then
    echo "=== Minting EDC token (period=${EDC_TOKEN_PERIOD}) ==="
    NEW_TOKEN="$(vault token create \
        -policy=edc \
        -period="${EDC_TOKEN_PERIOD}" \
        -display-name=edc \
        -format=json | jq -r .auth.client_token)"
    umask 077
    printf 'EDC_VAULT_HASHICORP_TOKEN=%s\n' "${NEW_TOKEN}" > "${EDC_ENV_FILE}"
    chmod 600 "${EDC_ENV_FILE}"
else
    echo "=== Existing EDC token is still valid, keeping it ==="
fi

echo "=== Vault is ready ==="
