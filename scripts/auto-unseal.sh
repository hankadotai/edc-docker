#!/bin/sh
###############################################################################
# Keep Vault unsealed across restarts.
#
# vault-init unseals Vault on `docker compose up`, but it is a one-shot
# (restart: "no"). On a HOST REBOOT, Docker's restart policy brings the EDC
# controlplane/dataplane back up via their restart policy WITHOUT re-running
# the one-shot vault-init (depends_on only gates `compose up`, not the daemon's
# restart). Vault therefore comes back SEALED and the connector can't read its
# signing/STS secrets — DSP auth then fails with 401 and health goes 503.
#
# This long-running sidecar watches Vault and re-unseals it from the persisted
# init.json (in the vault-state volume) whenever it is sealed, so the stack
# self-heals across restarts. Requires that vault-init has run at least once
# (it creates /vault/state/init.json). No jq/apk needed.
###############################################################################
set -u

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
export VAULT_ADDR
INIT_FILE="/vault/state/init.json"
INTERVAL="${UNSEAL_INTERVAL:-15}"

is_sealed() {
    vault status 2>/dev/null | grep -q '^Sealed[[:space:]]*true'
}

# Print the unseal_keys_b64 entries, one per line, without jq.
unseal_keys() {
    sed -n 's/.*"unseal_keys_b64":\[\([^]]*\)\].*/\1/p' "${INIT_FILE}" \
        | tr ',' '\n' | sed 's/[" ]//g'
}

echo "[auto-unseal] watcher started (interval=${INTERVAL}s)"
while true; do
    if [ -f "${INIT_FILE}" ] && is_sealed; then
        echo "[auto-unseal] Vault is sealed — unsealing from ${INIT_FILE}"
        i=0
        for key in $(unseal_keys); do
            [ "${i}" -ge 3 ] && break
            [ -n "${key}" ] && vault operator unseal "${key}" >/dev/null 2>&1
            i=$((i + 1))
        done
        if is_sealed; then
            echo "[auto-unseal] STILL sealed after 3 keys — check init.json"
        else
            echo "[auto-unseal] Vault unsealed"
        fi
    fi
    sleep "${INTERVAL}"
done
