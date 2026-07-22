# Standalone Tractus-X EDC in Docker

A single [Eclipse Tractus-X EDC](https://github.com/eclipse-tractusx/tractusx-edc) connector (control-plane + data-plane) packaged as a minimal but production-grade Docker Compose stack. Pre-configured to plug into **[Hanka](https://hanka.ai)** as the dataspace operator, and compatible with any other Tractus-X dataspace.

> **Going to deploy this?** Read [`docs/ONBOARDING.md`](docs/ONBOARDING.md). The README below is a high-level summary.
> **Wondering what won't work?** [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) is the honest list.

## Why this exists

Operating a Tractus-X EDC end-to-end normally requires running multiple supporting services in addition to the connector itself. This repo collapses your side to one Compose stack — control-plane, data-plane, postgres, vault, and Caddy for HTTPS — and delegates the dataspace operation to your operator. With [Hanka](https://hanka.ai), onboarding takes about as long as filling in `.env`.

## What's bundled, what isn't

| Component | Bundled | Image | Purpose |
|---|---|---|---|
| Caddy | yes | `caddy:2.11.2-alpine` | TLS termination + Let's Encrypt |
| EDC Control Plane | yes | `tractusx/edc-controlplane-postgresql-hashicorp-vault:0.12.0` | DSP, management API, contracts |
| EDC Data Plane | yes | `tractusx/edc-dataplane-hashicorp-vault:0.12.0` | data transfer |
| PostgreSQL | yes | `postgres:17.9-alpine` | EDC state, persistent volume |
| HashiCorp Vault | yes | `hashicorp/vault:1.21.4` | raft storage, scoped EDC token |
| Dataspace services (identity, directory, credential issuance) | **no** | — | provided by the operator |

For a **full local dataspace** (everything self-contained) for offline experimentation, use the sibling repo [`felipebustillo/tractus-x-docker`](https://github.com/felipebustillo/tractus-x-docker) instead.

## What you (the developer) own

The repo handles HTTPS, vault, postgres, and the EDC wiring. **Your only job at the network level** is to expose two endpoints publicly:

```
https://<your-public-host>/api/v1/dsp     <- DSP protocol (catalog / negotiation / transfer)
https://<your-public-host>/api/public     <- public data plane (the actual data transfer)
```

Concretely, on your side:

- A public DNS `A` (or `AAAA`) record for `<your-public-host>`.
- Inbound TCP `:80` and `:443` to the host.
- Outbound HTTPS to the dataspace operator's services and to peer EDCs.

Caddy in this stack will issue the cert automatically as long as `:80` is reachable. If you already have a reverse proxy at the edge, you can drop the bundled Caddy — see [`docs/ONBOARDING.md`](docs/ONBOARDING.md) §4.

## Production posture

- **HTTPS by default** via Caddy + Let's Encrypt.
- **Vault in production raft mode** with persistent volume; no dev-mode root tokens. Auto-unseals on restart.
- **Scoped EDC token** — connectors get a periodic, policy-restricted token (read-only on two specific paths), not the root.
- **Strong random secrets** — `setup.sh` generates `POSTGRES_PASSWORD`, `EDC_API_KEY`, and `EDC_PARTICIPANT_CONTEXT_ID` (UUID).
- **Management API on `127.0.0.1` only**. Never exposed publicly.

## TL;DR

```bash
git clone https://github.com/hankadotai/edc-docker.git
cd edc-docker

./scripts/setup.sh                             # defaults to the Hanka preset
$EDITOR .env                                   # fill in the values from your operator
./scripts/up.sh                                # bootstraps vault + starts everything

# One time: back up the vault unseal keys, then shred the local copy
docker compose cp vault-unseal:/vault/state/init.json ./vault-init.json
shred -u vault-init.json                       # after saving it in a password manager

./scripts/check.sh                             # PASS/FAIL: env, vault, APIs, STS
```

Detailed walkthrough — including optionally bringing your own signer key, smoke-tests, backup recipes, and how to verify compatibility with Hanka — in [`docs/ONBOARDING.md`](docs/ONBOARDING.md).

## Day-to-day

```bash
./scripts/up.sh                      # safe in any state (cold start, after long stop, after restart)
./scripts/check.sh                   # deployment doctor: one PASS/FAIL line per check
docker compose logs -f controlplane
docker compose down                  # stop, keep volumes
```

`scripts/up.sh` exists because Compose reads `env_file` once at the start of `up`, before any container runs — so a plain `docker compose up -d` on a cold start would launch the EDC services with no vault token. The wrapper does it in two phases. See [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) for the full reasoning.

## Versioning & upgrades

Releases follow [semantic versioning](https://semver.org/), and the version
number is a promise about what **you** have to do to upgrade:

| Bump | What it means for you |
|---|---|
| **PATCH** (1.0.x) | `git pull && ./scripts/up.sh` — nothing else. Fixes and security bumps. |
| **MINOR** (1.x.0) | Same — new optional capabilities, existing behavior unchanged. |
| **MAJOR** (x.0.0) | Read the **Upgrade notes** in the [CHANGELOG](CHANGELOG.md) first — something requires action on your side (an `.env` change, a migration step). |

For production, deploy from a release tag rather than `main`:

```bash
git clone --branch v1.0.0 https://github.com/hankadotai/edc-docker.git

# upgrading later:
git fetch --tags
git checkout vX.Y.Z
./scripts/up.sh
./scripts/check.sh
```

What changed in each release: [CHANGELOG.md](CHANGELOG.md). Only the latest
release is supported. Maintainers: the release procedure lives in
[`docs/RELEASING.md`](docs/RELEASING.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
