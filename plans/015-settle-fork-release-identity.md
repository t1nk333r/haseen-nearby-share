# Plan 015: Settle the fork's release identity

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- manifest.json backend/Cargo.toml backend/Cargo.lock install.sh bin/nearby-update-helper .github/workflows/release.yml CHANGELOG.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED — changing the plugin id changes the on-disk install directory;
  repointing the updater means the fork must actually publish a release
- **Depends on**: none, but **blocked on a maintainer decision** — see below
- **Category**: docs / release
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

Four findings share one root cause: the fork never decided whether it is a
downstream consumer of upstream's releases or a project that publishes its own.
Every artifact currently answers differently.

- `manifest.json` says version `1.1.1` — **identical to upstream's last stable
  release** — while four commits of runtime source changes have landed on top of
  it. The repo's own policy in `AGENTS.md` forbids this.
- `manifest.json`'s `homepage` points at **upstream's** repository, while
  `Panel.qml` shows users the **fork's** URL in its recovery action.
- `bin/nearby-update-helper` downloads release assets from **upstream's**
  repository, while `.github/workflows/release.yml` builds and publishes assets
  to the **fork's** releases that nothing ever consumes.
- `install.sh` installs a **different plugin entirely** — hardcoded
  `plugin_id="oma.nearby"`, with an origin allow-list that rejects this fork.

Today the version collision is masked because the backend is byte-identical to
upstream and `1.1.1` exists there. The moment the fork picks any version upstream
has not tagged, the panel's "Update helper" button resolves upstream's
`v<version>`, gets a 404, and reports "no published helper" — a dead-end recovery
path with no working alternative, because `README.md` tells users to install by
`git clone`, not via `install.sh`.

## The decision (must be made before executing)

**Option A — the fork consumes upstream's helper.** The fork never changes
`backend/`, so it keeps using upstream's published binaries. `install.sh` is
deleted; `release.yml` is deleted or reduced to CI-only; the manifest version
tracks upstream's with a fork-distinguishing suffix. Cheapest, and honest about
what the fork actually is today: a frontend fork.

**Option B — the fork publishes its own helper.** `bin/nearby-update-helper` and
`install.sh` repoint at the fork; `release.yml` stays; the fork tags and
publishes its own releases. Necessary if the fork ever wants to change
`backend/`. Costs: the fork must publish a release before "Update helper" works
at all, and it must keep building the Rust helper.

**This plan implements Option A**, because `git log 3f54d18..HEAD -- backend/`
is empty — the fork has not touched the backend and has no stated intention to.
Option A is also reversible: adopting B later is a constant change plus a tag.

Do **not** proceed if the maintainer wants B. See STOP conditions.

## Current state

`manifest.json`:

```json
  "id": "t1nk33r.nearby-share",
  "version": "1.1.1",
  "minHelperVersion": "1.1.0",
  "homepage": "https://github.com/jfg96/omarchy-nearby",
```

`backend/Cargo.toml` is `version = "1.1.1"`, and `backend/Cargo.lock`'s
`omarchy-nearby-helper` entry likewise.

`bin/nearby-update-helper` — the repository it fetches from, and the gate that
makes a non-stable version disable the button:

```bash
readonly repository="jfg96/omarchy-nearby"
```

```bash
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "Nearby $version is a development build with no published helper. Build it with ./build.sh."
```

`install.sh`:

```bash
readonly plugin_id="oma.nearby"
readonly repository="jfg96/omarchy-nearby"
```

with an origin allow-list accepting only the three `jfg96/omarchy-nearby`
spellings.

`.github/workflows/release.yml` verifies tag == manifest == cargo version, but
**not** `Cargo.lock` and **not** a matching changelog heading — both of which
`AGENTS.md` requires:

```yaml
          manifest_version=$(jq -r '.version' manifest.json)
          cargo_version=$(cargo metadata --no-deps --format-version 1 --manifest-path backend/Cargo.toml | jq -r '.packages[0].version')
          [[ "$version" == "$manifest_version" ]]
          [[ "$version" == "$cargo_version" ]]
```

The policy, from `AGENTS.md`:

> Runtime source changes after a stable release must advance the manifest and
> helper to the next `-dev` version together.

> Stable releases require matching versions in `manifest.json`,
> `backend/Cargo.toml`, and `backend/Cargo.lock`, plus a matching changelog
> heading and `vX.Y.Z` tag.

`CHANGELOG.md`'s newest heading is `## 1.1.1`, written by upstream. Nothing about
the fork's work appears in it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Updater tests | `bash tests/updater.test.sh` | pass line, exit 0 |
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |
| Manifest is valid JSON | `jq -e . manifest.json` | exit 0 |
| Plugin validates | `omarchy plugin validate .` | exit 0 |

## Scope

**In scope**:
- `manifest.json` — `version`, `homepage`
- `backend/Cargo.toml`, `backend/Cargo.lock` — version, in lockstep
- `CHANGELOG.md` — a heading for the fork's work
- `install.sh` — delete (Option A)
- `.github/workflows/release.yml` — tighten the gate, or remove if Option A
  means no releases
- `README.md` — remove references to the deleted installer
- `tests/updater.test.sh` — assert the updater's repository matches the manifest

**Out of scope** (do NOT touch):
- `backend/src/**`. The backend is byte-identical to upstream and must stay that
  way for Option A to hold.
- `Panel.qml`'s `repositoryUrl` — it already points at the fork correctly.
- `AGENTS.md` and `README.md` prose beyond the installer references — plan 016.

## Git workflow

- Branch: `advisor/015-settle-fork-release-identity`
- Conventional commits; `chore:` for the version bump, `fix:` for the identity
  corrections. Keep them as separate commits.
- Do NOT push, tag, or open a PR unless the operator instructed it.
  **Never create or move a release tag** — `AGENTS.md` forbids tagging a commit
  that has not passed CI.

## Steps

### Step 1: Advance the version to a fork-distinguishable dev version

Set all three to `1.1.2-dev`:

- `manifest.json` → `"version": "1.1.2-dev"`
- `backend/Cargo.toml` → `version = "1.1.2-dev"`
- `backend/Cargo.lock` → the `omarchy-nearby-helper` package entry

This deliberately disables the in-panel "Update helper" button, because
`bin/nearby-update-helper` refuses a non-`X.Y.Z` version with a message telling
the user to run `./build.sh`. That is the correct behaviour for a tree that is
not a published release, and `tests/updater.test.sh` already covers that path.

**Verify**: `jq -r .version manifest.json` → `1.1.2-dev`;
`grep -c '^version = "1.1.2-dev"' backend/Cargo.toml` → `1`;
`bash tests/updater.test.sh` → pass line, exit 0;
`omarchy plugin validate .` → exit 0.

### Step 2: Point the manifest homepage at the fork

```json
  "homepage": "https://github.com/t1nk333r/omarchy-nearby-share",
```

Note the owner is spelled `t1nk333r` (three digits) while the plugin id is
`t1nk33r.nearby-share` (two). That asymmetry is real and intentional to preserve
here — the URL must match the actual repository. Renaming the plugin id is a
separate, larger change (it resets stored widget settings) and is **not** part of
this plan.

**Verify**: `jq -r .homepage manifest.json` → the fork URL;
`jq -e . manifest.json` → exit 0.

### Step 3: Delete `install.sh`

Under Option A the fork installs by `git clone` plus `scripts/setup.sh`, which is
what `README.md` already documents. `install.sh` installs upstream's plugin under
a different id into a different directory, and its origin allow-list rejects this
repository — it cannot be made to work here without becoming Option B.

```
git rm install.sh
```

Then remove every reference to it: search `README.md` and `Panel.qml`.
`Panel.qml`'s `installerCommand` already points at `build.sh` if plan 003's
sibling change landed; confirm it does not name `install.sh`.

**Verify**: `test ! -f install.sh && echo GONE` → `GONE`;
`grep -rn 'install\.sh' --include='*.md' --include='*.qml' . | grep -v '^./plans/'`
→ no matches.

### Step 4: Tighten the release gate to match stated policy

In `.github/workflows/release.yml`'s "Verify release versions" step, add the two
checks `AGENTS.md` requires and the workflow omits:

```bash
          lock_version=$(awk '/^name = "omarchy-nearby-helper"$/{found=1;next} found&&/^version = /{gsub(/[version = "]/,"");print;exit}' backend/Cargo.lock)
          [[ "$version" == "$lock_version" ]]
          grep -q "^## ${version}$" CHANGELOG.md
```

If the `awk` proves fragile, any equivalent extraction is fine — the requirement
is that a stale lockfile and a missing changelog heading both fail the release
rather than surfacing later as a confusing `--locked` error.

Keep the workflow itself: it is the CI that would validate a future release, and
under Option A it simply never fires because the fork does not tag.

**Verify**: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml'))" && echo YAML-OK`
→ `YAML-OK`.

### Step 5: Write the fork's changelog entry

Add a heading above the existing `## 1.1.1`:

```markdown
## 1.1.2-dev

Fork of jfg96/omarchy-nearby. Changes on top of upstream 1.1.1:

- Added a Quick Share pane beside LocalSend, selected by two buttons at the top
  of the popup. Quick Share is driven by the `qs` CLI as short-lived
  subprocesses; it sends files only and does not receive.
- Added `scripts/dependencies.sh` (detect and install what Quick Share needs)
  and `scripts/setup_firewall.sh` (open the four ports both protocols use).
- Added a tracked `post-merge` git hook that reports missing dependencies after
  an update.
- The Quick Share CLI is GPL-3.0 and is built from source on the user's machine;
  it is not vendored or linked. See THIRD_PARTY_NOTICES.md.
- The plugin id is `t1nk33r.nearby-share` and the IPC target matches it.
```

Adjust the bullets to match whichever plans have actually landed — do not claim
behaviour that is not in the tree.

**Verify**: `grep -c '^## 1.1.2-dev$' CHANGELOG.md` → `1`.

### Step 6: Assert the updater and manifest cannot drift again

Extend `tests/updater.test.sh` with a case asserting that
`bin/nearby-update-helper`'s `repository` constant is consistent with the
release model — under Option A, that it is upstream's, **and** that the manifest
version is a `-dev` form so the button is disabled rather than resolving an
upstream tag that does not describe this tree.

**Verify**: `bash tests/updater.test.sh` → pass line, exit 0.

## Test plan

- Extend `tests/updater.test.sh` with the consistency case in Step 6.
- Structural pattern: the existing cases in that file.
- The version bump is verified by the existing updater test that covers the
  "development build with no published helper" branch — confirm it exercises it.
- Verification: `bash tests/updater.test.sh`, all Node suites, and
  `omarchy plugin validate .` → all green.

## Done criteria

ALL must hold:

- [ ] `jq -r .version manifest.json` returns `1.1.2-dev`
- [ ] `manifest.json`, `backend/Cargo.toml`, `backend/Cargo.lock` all say `1.1.2-dev`
- [ ] `jq -r .homepage manifest.json` returns the fork URL
- [ ] `install.sh` no longer exists and nothing outside `plans/` references it
- [ ] `grep -c '^## 1.1.2-dev$' CHANGELOG.md` returns `1`
- [ ] `.github/workflows/release.yml` checks `Cargo.lock` and the changelog heading
- [ ] `bash tests/updater.test.sh` exits 0
- [ ] `omarchy plugin validate .` exits 0
- [ ] `git diff --stat backend/src/` shows no changes
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- **The maintainer has not confirmed Option A.** This plan deletes `install.sh`
  and leaves the updater pointed at upstream. Option B is the opposite. Do not
  guess.
- `git log 3f54d18..HEAD -- backend/` is **not** empty — the fork has started
  changing the backend, which invalidates Option A's premise entirely.
- `omarchy plugin validate .` fails after the version bump.
- Deleting `install.sh` breaks a test or a documented workflow you cannot update
  within this plan's scope.
- You are tempted to create or move a git tag. Do not; `AGENTS.md` forbids
  tagging before CI has passed on the exact commit, and tagging is not part of
  this plan.

## Maintenance notes

- Under Option A the invariant is: **`backend/` stays byte-identical to
  upstream.** The moment a fix lands there, Option A is void and the fork must
  publish its own helper. `git diff 3f54d18..HEAD -- backend/` being empty is the
  check.
- The version must be advanced again on the next runtime change after any
  release, per `AGENTS.md`. The release workflow now enforces the lockfile and
  changelog halves of that policy; the `-dev` discipline is still manual.
- The `t1nk33r` / `t1nk333r` spelling asymmetry is deliberate here — the URL
  matches the real account. If the plugin id is ever renamed to match, it resets
  stored widget settings in `shell.json` and needs its own migration note.
