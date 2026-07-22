#!/bin/sh
# Deployment doctor. Verifies the things that actually break on first contact
# with a dataspace, in dependency order, and prints one PASS/FAIL line each:
#
#   [env]     .env present, required values filled, no <placeholders> left
#   [stack]   containers running and healthy
#   [vault]   vault reachable and unsealed
#   [mgmt]    management API answers a query (localhost)
#   [dsp]     public DSP endpoint serves the protocol versions
#   [public]  public data plane rejects unauthenticated requests (= routed)
#   [sts]     operator STS mints a token that carries the inner scope token
#
# Usage:
#   ./scripts/check.sh          # run everything
#   ./scripts/check.sh --env    # only the .env validation (used by up.sh)
#
# Exit code: 0 if every executed check passed, 1 otherwise.
set -u

cd "$(dirname "$0")/.."

FAILED=0

pass() { printf 'PASS  [%s] %s\n' "$1" "$2"; }
fail() { printf 'FAIL  [%s] %s\n' "$1" "$2"; FAILED=1; }

envval() {
    # LAST occurrence wins, matching docker compose's .env parsing (verified:
    # a duplicate key later in the file overrides an earlier one). This keeps
    # "paste the portal env block at the end of .env" working.
    sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1
}

# --- [env] -------------------------------------------------------------------
if [ ! -f .env ]; then
    fail env ".env not found — run ./scripts/setup.sh first"
    exit 1
fi

REQUIRED="EDC_PUBLIC_HOST EDC_BPN EDC_DID EDC_PARTICIPANT_CONTEXT_ID \
STS_TOKEN_URL CREDENTIAL_SERVICE_URL BDRS_URL TRUSTED_ISSUER_DID \
STS_CLIENT_SECRET POSTGRES_PASSWORD EDC_API_KEY"

ENV_OK=1
for key in ${REQUIRED}; do
    v="$(envval "${key}")"
    case "${v}" in
        "")   fail env "${key} is empty — fill it in .env"; ENV_OK=0 ;;
        *"<"*) fail env "${key} still contains a <placeholder>: ${v}"; ENV_OK=0 ;;
    esac
done
[ "${ENV_OK}" = 1 ] && pass env "all required values filled, no placeholders"

if [ "${1:-}" = "--env" ]; then
    exit "${FAILED}"
fi

EDC_PUBLIC_HOST="$(envval EDC_PUBLIC_HOST)"
EDC_API_KEY="$(envval EDC_API_KEY)"
EDC_DID="$(envval EDC_DID)"
STS_CLIENT_SECRET="$(envval STS_CLIENT_SECRET)"
STS_TOKEN_URL="$(envval STS_TOKEN_URL)"
TRUSTED_ISSUER_DID="$(envval TRUSTED_ISSUER_DID)"
MGMT_PORT="$(envval EDC_MANAGEMENT_HOST_PORT)"
MGMT_PORT="${MGMT_PORT:-29181}"

# --- [stack] -----------------------------------------------------------------
STACK_OK=1
for svc in vault vault-unseal controlplane dataplane postgres; do
    cid="$(docker compose ps -q "${svc}" 2>/dev/null)"
    if [ -z "${cid}" ]; then
        fail stack "${svc} is not running — start with ./scripts/up.sh"
        STACK_OK=0
        continue
    fi
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${cid}" 2>/dev/null)"
    case "${health}" in
        healthy|running) ;;
        *) fail stack "${svc} is ${health:-unknown}"; STACK_OK=0 ;;
    esac
done
[ "${STACK_OK}" = 1 ] && pass stack "all services running and healthy"

# --- [vault] -----------------------------------------------------------------
if docker compose exec -T vault vault status > /dev/null 2>&1; then
    pass vault "reachable and unsealed"
else
    # vault status exits 2 when sealed, 1 on connection errors.
    fail vault "sealed or unreachable — vault-unseal should self-heal in <30s; check: docker compose logs vault-unseal"
fi

# --- [mgmt] ------------------------------------------------------------------
code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
    -H "X-Api-Key: ${EDC_API_KEY}" -H 'Content-Type: application/json' \
    -X POST "http://127.0.0.1:${MGMT_PORT}/management/v3/assets/request" \
    -d '{"@context":{"@vocab":"https://w3id.org/edc/v0.0.1/ns/"},"@type":"QuerySpec"}' 2>/dev/null)"
if [ "${code}" = "200" ]; then
    pass mgmt "management API answers on 127.0.0.1:${MGMT_PORT}"
else
    fail mgmt "management API returned HTTP ${code:-000} (expected 200)"
fi

# --- [dsp] -------------------------------------------------------------------
code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' \
    "https://${EDC_PUBLIC_HOST}/api/v1/dsp/.well-known/dspace-version" 2>/dev/null)"
if [ "${code}" = "200" ]; then
    pass dsp "https://${EDC_PUBLIC_HOST}/api/v1/dsp reachable from here"
else
    fail dsp "DSP version endpoint returned HTTP ${code:-000} (expected 200) — DNS / TLS / routing"
fi

# --- [public] ----------------------------------------------------------------
# Unauthenticated requests must be REJECTED with 401 — that both proves the
# route reaches the data plane and that it is not wide open.
code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' \
    "https://${EDC_PUBLIC_HOST}/api/public" 2>/dev/null)"
if [ "${code}" = "401" ]; then
    pass public "data plane routed and requires auth (401)"
else
    fail public "public data plane returned HTTP ${code:-000} (expected 401) — routing or path-strip issue"
fi

# --- [sts] -------------------------------------------------------------------
# Mint a real token against the operator STS and verify the response embeds
# the inner scope token (proves client_id/secret AND the DCP scope config).
resp="$(curl -sS -m 20 -X POST \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "audience=${TRUSTED_ISSUER_DID}" \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "client_id=${EDC_DID}" \
    --data-urlencode "client_secret=${STS_CLIENT_SECRET}" \
    --data-urlencode 'bearer_access_scope=org.eclipse.tractusx.vc.type:MembershipCredential:read' \
    "${STS_TOKEN_URL}" 2>/dev/null)"
access_token="$(printf '%s' "${resp}" | sed -n 's/.*"access_token" *: *"\([^"]*\)".*/\1/p')"
if [ -z "${access_token}" ]; then
    fail sts "no access_token from ${STS_TOKEN_URL} — client_id (must be your DID) / secret: $(printf '%s' "${resp}" | head -c 160)"
else
    # base64url-decode the JWT payload and look for the inner "token" claim.
    payload="$(printf '%s' "${access_token}" | cut -d. -f2 | tr '_-' '/+')"
    while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="${payload}="; done
    if printf '%s' "${payload}" | base64 -d 2>/dev/null | grep -q '"token"'; then
        pass sts "STS mints tokens with the inner scope token"
    else
        fail sts "STS token has NO inner token — DCP scopes not applied (see ONBOARDING §6.3)"
    fi
fi

# -----------------------------------------------------------------------------
if [ "${FAILED}" = 0 ]; then
    printf '\nAll checks passed. The connector is ready to interact with the dataspace.\n'
else
    printf '\nSome checks FAILED — see docs/ONBOARDING.md §6 (troubleshooting).\n'
fi
exit "${FAILED}"
