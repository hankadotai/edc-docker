#!/bin/sh
# One-time bootstrap helper.
#
# Generates strong random secrets for postgres and the EDC management API,
# preserves the dataspace-specific values that were already filled in, and
# writes the result to .env. Re-running it is safe: it never overwrites a
# value that's already populated.
#
# Usage:
#   ./scripts/setup.sh                  # uses presets/hanka.env.example
#   ./scripts/setup.sh cofinity         # uses presets/cofinity.env.example
#   ./scripts/setup.sh - .env.example   # uses the generic template
set -eu

cd "$(dirname "$0")/.."

PRESET="${1:-hanka}"

case "${PRESET}" in
    -)             SOURCE=".env.example" ;;
    hanka|cofinity) SOURCE="presets/${PRESET}.env.example" ;;
    *)             SOURCE="${PRESET}" ;;
esac

if [ ! -f "${SOURCE}" ]; then
    echo "preset not found: ${SOURCE}" >&2
    exit 1
fi

if [ -f .env ]; then
    echo ".env already exists. Refusing to overwrite — edit it directly or remove it first." >&2
    exit 1
fi

echo "Using preset: ${SOURCE}"

random32() {
    head -c 24 /dev/urandom | base64 | tr -d '/+=\n' | head -c 32
}

uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-Z' 'a-z'
    else
        python3 -c 'import uuid;print(uuid.uuid4())'
    fi
}

POSTGRES_PASSWORD="$(random32)"
EDC_API_KEY="$(random32)"
PARTICIPANT_CONTEXT_ID="$(uuid)"

# Stream the preset into .env, replacing placeholder lines for the values we
# generated. Everything else stays as the preset wrote it.
sed \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" \
    -e "s|^EDC_API_KEY=.*|EDC_API_KEY=${EDC_API_KEY}|" \
    -e "s|^EDC_PARTICIPANT_CONTEXT_ID=.*|EDC_PARTICIPANT_CONTEXT_ID=${PARTICIPANT_CONTEXT_ID}|" \
    "${SOURCE}" > .env

chmod 600 .env

mkdir -p runtime
# placeholder so docker compose env_file doesn't trip on first parse
[ -f runtime/edc-vault.env ] || : > runtime/edc-vault.env

cat <<EOF

.env created with:
  - strong random POSTGRES_PASSWORD
  - strong random EDC_API_KEY
  - fresh UUID for EDC_PARTICIPANT_CONTEXT_ID

Next steps:
  1. Edit .env and fill in every empty value (your operator provides them;
     with Hanka they come from the portal registration bundle):
       \$EDITOR .env
  2. Bring up the stack — bootstraps and unseals vault automatically
     (use this every time, not plain docker compose up):
       ./scripts/up.sh
  3. First time only — back up the vault unseal keys:
       docker compose cp vault-unseal:/vault/state/init.json ./vault-init.json
       # *** copy vault-init.json into a password manager / encrypted backup ***
       shred -u vault-init.json
  4. Verify the deployment end to end:
       ./scripts/check.sh

EOF
