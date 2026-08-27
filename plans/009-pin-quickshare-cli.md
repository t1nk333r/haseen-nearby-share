# Plan 009: Pin the Quick Share CLI to a reviewed revision

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- scripts/dependencies.sh THIRD_PARTY_NOTICES.md README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED — pinning freezes users on a known revision, so someone must
  now bump it deliberately; a stale pin against a moving protocol is its own
  failure mode
- **Depends on**: none (but land before plan 010, which writes fixtures against
  this CLI's output)
- **Category**: security
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

`scripts/dependencies.sh` builds the Quick Share CLI on the user's machine with
`cargo install --git`, against a third-party repository, with **no `--rev`, no
`--tag`, and no `--locked`**. Three consequences:

1. Every user gets whatever that repository's default branch HEAD happens to be
   at the moment they run the installer. Two users on the identical plugin commit
   can have behaviourally different Quick Share panes.
2. `cargo install` compiles and **executes** `build.rs` for the target and every
   transitive dependency, as the invoking user. Without a pin, an unreviewed push
   to a single-maintainer branch becomes code execution on every machine that
   installs afterwards.
3. Without `--locked`, the whole transitive crate graph is re-resolved from
   crates.io on each run, so even a fixed revision would not reproduce.

The contrast inside this repo is stark: the LocalSend helper is fetched as a
published release asset and verified against a SHA256 in `bin/nearby-update-helper`.
The Quick Share binary gets no equivalent.

This also matters for testability. `QuickShare.qml` recovers the confirmation PIN
and the transfer progress by parsing this CLI's **human-readable stderr**, and
maps its exit codes to user-facing verdicts. Fixtures written against a moving
target are worthless, which is why plan 010 depends on this one.

## Current state

File: `scripts/dependencies.sh`.

The repository constant near the top:

```bash
readonly QS_REPO="https://github.com/martinalderson/qs"
```

The build invocation inside `install_missing`:

```bash
    cargo install --git "$QS_REPO" --root "$stage" || {
      local status=$?
      echo "Building qs failed (exit code: $status)."
      sleep 2.5
      return "$status"
    }
```

The only post-build check:

```bash
    [[ -x $stage/bin/qs ]] || { echo "Build produced no qs binary."; sleep 2.5; return 1; }
```

The pre-install banner that describes what will be built:

```bash
Quick Share CLI will be built from source:
  cargo install --git $QS_REPO --root <staging>
  installed as: $QS_BIN

This compiles ~300 crates and takes several minutes on first run.
It is GPL-3.0 software from a third party, built on your machine.
```

`THIRD_PARTY_NOTICES.md` records the dependency chain and currently names a
branch rather than a revision:

```
- Project: https://github.com/martinalderson/qs
- License: GPL-3.0-or-later
- Underlying library: https://github.com/Martichou/rquickshare (`rqs_lib`),
  via the fork https://github.com/martinalderson/rquickshare, branch
  `feat/ble-receiver-connect-back`
```

**A known-good revision exists.** The binary currently installed on the
development machine was built from `qs` commit `a63bc7b3`. That is the revision
this plan pins, because it is the one the plugin's existing parser was written
and observed against.

**Conventions**: `scripts/dependencies.sh` runs under `set -uo pipefail` (no
`-e`); failures that matter are checked explicitly. Comments explain *why* in
full sentences.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Syntax check | `bash -n scripts/dependencies.sh` | exit 0 |
| Dependency tests | `bash tests/dependencies.test.sh` | pass line, exit 0 |
| Confirm the pinned rev exists | `git ls-remote https://github.com/martinalderson/qs` | lists refs; network required |

**Never run `scripts/dependencies.sh --install`.** It compiles ~300 crates.
Verification goes through the stubbed harness.

## Scope

**In scope**:
- `scripts/dependencies.sh` — the constants, the build invocation, the banner
- `THIRD_PARTY_NOTICES.md` — record the pinned revision
- `README.md` — mention the pin in the dependencies section
- `tests/dependencies.test.sh` — assert the pin reaches the cargo argv

**Out of scope** (do NOT touch):
- The lookup/quoting logic in `install_missing` — plan 002 owns it. If plan 002
  has not landed, work around its bug; do not fix it here.
- `bin/nearby-update-helper` and `install.sh` — the LocalSend helper's fetch path
  is separate and already verified.
- `QuickShare.qml` — the parser is plan 010/011.

## Git workflow

- Branch: `advisor/009-pin-quickshare-cli`
- Conventional commits; `fix:` or `build:` — `fix:` is fine.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the revision constant

Beside `QS_REPO`, add:

```bash
# Pinned deliberately. `cargo install --git` with no --rev tracks the default
# branch, so two users on the same plugin commit could build different binaries
# -- and cargo runs each crate's build.rs during that build. This is also the
# revision QuickShare.qml's stderr parser and exit-code mapping were written
# against, so moving it without re-checking that parser is a behaviour change.
readonly QS_REV="a63bc7b3"
```

If a newer revision is deliberately wanted, that is a maintainer decision — see
STOP conditions.

**Verify**: `bash -n scripts/dependencies.sh` → exit 0;
`grep -c 'readonly QS_REV=' scripts/dependencies.sh` → `1`.

### Step 2: Pin and lock the build

Change the invocation to:

```bash
    cargo install --git "$QS_REPO" --rev "$QS_REV" --locked --root "$stage" || {
```

`--locked` makes cargo honour the upstream `Cargo.lock` instead of re-resolving,
which is what makes the build reproducible rather than merely repeatable.

**Verify**: `bash -n scripts/dependencies.sh` → exit 0;
`grep -c -- '--rev "$QS_REV" --locked' scripts/dependencies.sh` → `1`.

### Step 3: Show the pin in the consent banner

The banner is what the user reads before agreeing to a multi-minute build of
third-party code. Update it so the revision is visible:

```bash
Quick Share CLI will be built from source:
  cargo install --git $QS_REPO --rev $QS_REV --locked --root <staging>
  installed as: $QS_BIN

This compiles ~300 crates and takes several minutes on first run.
It is GPL-3.0 software from a third party, built on your machine at the
pinned revision above.
```

**Verify**: `grep -c 'rev \$QS_REV' scripts/dependencies.sh` → at least `1`.

### Step 4: Record what was built, so a later run can tell

After the successful `mv` of the binary into place, write the revision beside it:

```bash
    printf '%s\n' "$QS_REV" > "${QS_BIN}.rev"
```

`bin/*` is gitignored, so this file is local state, not a tracked artifact.

**Verify**: `grep -c 'QS_BIN}.rev' scripts/dependencies.sh` → `1`.

### Step 5: Update the notices and the README

In `THIRD_PARTY_NOTICES.md`, change the `qs` entry to name the pinned revision
as well as the project, and state that the build is pinned and locked. Keep the
existing GPL-boundary paragraph — it is the reasoning that keeps this repo MIT
and must not be weakened.

In `README.md`, in the dependencies section, add one sentence: that `qs` is
built from a pinned revision recorded in `scripts/dependencies.sh`, and that
bumping it requires re-checking `QuickShare.qml`'s stderr parser.

**Verify**: `grep -c 'a63bc7b3' THIRD_PARTY_NOTICES.md` → at least `1`.

### Step 6: Assert the pin reaches the argv

Extend `tests/dependencies.test.sh` (plan 001 created it) with a case that stubs
`cargo` to record argv, runs `--install` with only `qs` missing, and asserts the
recorded argv contains `--rev`, the pinned SHA, and `--locked`.

If plan 001 has not landed, skip this step and say so in your report rather than
inventing a test file — plan 001 owns that file's structure.

**Verify**: `bash tests/dependencies.test.sh` → pass line, exit 0.

## Test plan

- One new case in `tests/dependencies.test.sh` asserting the cargo argv carries
  `--rev <sha> --locked`.
- Structural pattern: the other stub-and-assert-argv cases in that file.
- Verification: `bash tests/dependencies.test.sh` → all pass.

## Done criteria

ALL must hold:

- [ ] `bash -n scripts/dependencies.sh` exits 0
- [ ] `grep -c -- '--rev "$QS_REV" --locked' scripts/dependencies.sh` returns `1`
- [ ] `grep -c 'cargo install --git "$QS_REPO" --root' scripts/dependencies.sh` returns `0` (the unpinned form is gone)
- [ ] `grep -c 'a63bc7b3' THIRD_PARTY_NOTICES.md` returns at least `1`
- [ ] `bash tests/dependencies.test.sh` exits 0 (or the step is documented as skipped because plan 001 has not landed)
- [ ] `git status --porcelain` lists only the in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `git ls-remote https://github.com/martinalderson/qs` shows revision `a63bc7b3`
  no longer exists, or the repository is gone. Do not silently substitute
  another revision — the whole point is that a human chose this one.
- The maintainer wants to pin a *newer* revision. That is fine, but it requires
  re-verifying `QuickShare.qml`'s stderr parser against the new output first, and
  that verification is plan 010's work. Report and stop.
- The build invocation does not match the excerpt in "Current state".
- You cannot make the test pass without editing `install_missing`'s lookup logic
  (plan 002's territory).

## Maintenance notes

- Bumping `QS_REV` is a behaviour change, not a chore. `QuickShare.qml` recovers
  the PIN and progress from this binary's stderr prose and maps its exit codes;
  a wording or exit-code change upstream silently breaks the pane. Re-run plan
  010's fixtures against any new revision before bumping.
- Longer-term alternative, deliberately not attempted here: build `qs` in this
  repository's own `release.yml` and fetch it as a SHA256-verified release
  asset, the way `bin/nearby-update-helper` already fetches the LocalSend helper.
  That removes the user-machine build entirely but requires deciding the fork's
  release model first — see plan 015.
- A reviewer should confirm the GPL-boundary paragraph in
  `THIRD_PARTY_NOTICES.md` is unchanged. It is what keeps this repository MIT.
