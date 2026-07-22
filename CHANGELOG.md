# Changelog

All notable changes to this stack, written for the operator running it.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning:
[Semantic Versioning](https://semver.org/) with the upgrade contract described
in the [README](README.md#versioning--upgrades) — in short: PATCH and MINOR
mean `git pull && ./scripts/up.sh`, MAJOR means read the **Upgrade notes** in
the release entry first.

## [Unreleased]

## [1.0.0] - 2026-07-22

First stable release. Verified end to end against a live dataspace: catalog
request, contract negotiation, transfer, data pull, token expiry and refresh.

### Added

- Deployment doctor `scripts/check.sh`: one PASS/FAIL line per real-world
  failure mode — `.env` completeness, container health, vault seal state,
  management API, both public endpoints peers dial, and a live STS token mint
  that also proves the DCP scope configuration.
- Fail-fast `.env` validation in `scripts/up.sh`: a missing value fails in one
  second with a clear list instead of a Java stack trace minutes later.
- Data-plane signer key self-generated in vault on first boot; no key material
  is ever exchanged with the operator (bring-your-own-key still supported via
  `TOKEN_SIGNER_KEY_JWK`).
- Vault auto-unseal sidecar: the stack self-heals its vault seal across host
  reboots.
- EDR token refresh functional out of the box
  (`tx.edc.dataplane.token.refresh.endpoint` advertised on the public
  data-plane URL), so transfers outliving the 300 s access token no longer
  break.

### Changed

- Public DSP and data-plane URLs are derived from `EDC_PUBLIC_HOST`; the
  presets shrink to the values only the operator can know. Explicit `.env`
  values still override everything.
- First-run flow collapsed to: `setup.sh` → edit `.env` → `up.sh` → back up
  `init.json` → `check.sh`.

[Unreleased]: https://github.com/hankadotai/edc-docker/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/hankadotai/edc-docker/releases/tag/v1.0.0
