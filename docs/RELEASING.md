# Releasing

Trunk-based: `main` is always releasable, releases are annotated tags on
`main`, and only the latest release is supported.

## Version bump rules (the operator contract)

The version number is a promise about what the operator has to do to upgrade
(see the [README](../README.md#versioning--upgrades) table). Rule of thumb:
**if a change forces the operator to edit `.env` or run a manual step, it is
MAJOR** — even a one-line diff. New optional capability = MINOR. Everything
else = PATCH.

## Cutting a release

1. CI green on `main`.
2. In `CHANGELOG.md`, move the `[Unreleased]` items into a new
   `## [X.Y.Z] - YYYY-MM-DD` section. For MAJOR releases write an
   **Upgrade notes** subsection with the exact operator steps. Update the
   compare links at the bottom.
3. Commit and push:

   ```bash
   git commit -am "docs: release vX.Y.Z"
   git push origin main
   ```

4. Tag and publish, using the changelog section as the release notes:

   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   gh release create vX.Y.Z --title "vX.Y.Z" --notes "<changelog section>"
   ```

## Hotfixes

Normally: fix on `main`, release a PATCH from `main`. Only if `main` already
carries unreleased work you do not want to ship: branch from the last tag,
cherry-pick the fix, tag there, and merge the branch back so `main` keeps the
fix too:

```bash
git switch -c release/X.Y.x vX.Y.Z
git cherry-pick <fix-sha>
git tag -a vX.Y.Z+1 -m "vX.Y.Z+1"
git push origin release/X.Y.x vX.Y.Z+1
git switch main && git merge release/X.Y.x
```
