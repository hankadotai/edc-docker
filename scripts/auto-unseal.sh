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
# (it creates /vault/state/init.json). Runs as root so it can read the
# root:root 0600 init.json and apk-install jq (matching vault-init.sh).
###############################################################################
set -u

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
export VAULT_ADDR
INIT_FILE="/vault/state/init.json"
INTERVAL="${UNSEAL_INTERVAL:-15}"

command -v jq >/dev/null 2>&1 || apk add --no-cache jq >/dev/null 2>&1 || true

is_sealed() {
    vault status 2>/dev/null | grep -q '^Sealed[[:space:]]*true'
}

echo "[auto-unseal] watcher started (interval=${INTERVAL}s)"
while true; do
    if [ -f "${INIT_FILE}" ] && is_sealed; then
        echo "[auto-unseal] Vault is sealed — unsealing from ${INIT_FILE}"
        command -v jq >/dev/null 2>&1 || apk add --no-cache jq >/dev/null 2>&1 || true
        i=0
        while [ "${i}" -lt 3 ]; do
            key="$(jq -r ".unseal_keys_b64[${i}]" "${INIT_FILE}" 2>/dev/null)"
            [ -n "${key}" ] && [ "${key}" != "null" ] && \
                vault operator unseal "${key}" >/dev/null 2>&1
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
