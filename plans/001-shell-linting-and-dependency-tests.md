# Plan 001: Put the shell scripts under CI verification

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- .github/workflows/ci.yml scripts/ .githooks/ tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

This repository's shell scripts are the only code that invokes `sudo`, edits the
system firewall, and runs automatically from a git hook on every plugin update —
and they are the only code with no automated verification whatsoever. CI runs
three Node suites and four `cargo` steps, and touches none of the four shell
scripts added to this repo.

The concrete cost is already paid: `scripts/dependencies.sh` contains a bug that
makes its entire package-installation path a no-op (fixed in plan 002), and it
merged green. A single argv-assertion test would have caught it. This plan
establishes the gate so that plan 002's fix is verifiable and so the next such
bug cannot merge silently.

## Current state

Files involved:

- `.github/workflows/ci.yml` — the only CI workflow that runs on push/PR. Seven
  steps, none of which look at a shell script.
- `scripts/dependencies.sh` — 196 lines. Emits JSON for the UI (`--json`),
  reports missing programs (`--check`), installs them (`--install`).
- `scripts/setup_firewall.sh`, `scripts/setup.sh`, `.githooks/post-merge`,
  `install.sh`, `build.sh`, `bin/nearby-update-helper` — the rest of the shell
  surface. `bin/nearby-update-helper` is a shell script despite its location.
- `tests/updater.test.sh` — **the exemplar to follow.** An offline harness that
  tests `bin/nearby-update-helper` by putting stub binaries on `PATH`.

`.github/workflows/ci.yml` as it exists today (the full `steps:` list):

```yaml
    steps:
      - name: Check out source
        uses: actions/checkout@v5

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt

      - name: Test frontend model
        run: node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js

      - name: Test helper updater
        run: bash tests/updater.test.sh

      - name: Check Rust formatting
        run: cargo fmt --manifest-path backend/Cargo.toml --all -- --check

      - name: Check Nearby helper builds
        run: cargo check --locked --manifest-path backend/Cargo.toml

      - name: Test Nearby helper
        run: cargo test --locked --manifest-path backend/Cargo.toml

      - name: Test vendored localsend-rs
        run: cargo test --locked --manifest-path backend/vendor/localsend-rs/Cargo.toml --features https
```

**Repo convention for shell tests** — match `tests/updater.test.sh`. Its shape,
which your new test file must follow:

```bash
#!/usr/bin/env bash
# <one paragraph explaining what this covers and why it is not covered elsewhere>
# Run: bash tests/<name>.test.sh

set -uo pipefail

tests_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

failures=0
current=""

announce() { current="$1"; }
report() {
  echo "  FAIL: $current" >&2
  echo "        $1" >&2
  failures=$((failures + 1))
}
assert_eq() {
  [[ $1 == "$2" ]] || report "expected '$2', got '$1'${3:+ ($3)}"
}
assert_contains() {
  [[ $1 == *"$2"* ]] || report "expected output to contain '$2', got: $1"
}

# A sandbox per case: stub binaries on PATH ahead of the real ones.
setup() {
  sandbox=$(mktemp -d "${TMPDIR:-/tmp}/nearby-deps-test.XXXXXX")
  ...
}
```

`tests/updater.test.sh` ends by exiting non-zero when `failures` is non-zero and
printing a pass line otherwise — read its final ~15 lines and copy that
structure exactly.

**Style note**: this repo's comments explain *why*, not *what*, and are written
in full sentences. Match that register; do not add narration comments.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Syntax check one script | `bash -n scripts/dependencies.sh` | exit 0, no output |
| Lint (if installed) | `shellcheck -S warning scripts/*.sh` | exit 0 |
| Existing shell test | `bash tests/updater.test.sh` | prints a pass line, exit 0 |
| New shell test | `bash tests/dependencies.test.sh` | prints a pass line, exit 0 |
| Node suites (must stay green) | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |

`shellcheck` is **not** installed on the development machine this plan was
written on. Do not install it. Write the CI step regardless (CI runners have it
or can install it via `apt-get`), and rely on `bash -n` locally.

## Scope

**In scope** (the only files you may modify or create):
- `.github/workflows/ci.yml`
- `tests/dependencies.test.sh` (create)

**Out of scope** (do NOT touch, even though they look related):
- `scripts/dependencies.sh` — plan 002 fixes its logic. This plan only *tests*
  it. Your new test must describe the behaviour that exists **today**, including
  the broken behaviour; plan 002 will flip those assertions. If you "helpfully"
  fix the script here, plan 002 conflicts and the bug has no failing test.
- `.github/workflows/release.yml` — release gating is a separate concern.
- Every `.qml` and `.js` file, and all of `backend/`.

## Git workflow

- Branch: `advisor/001-shell-linting-and-dependency-tests`
- Commit style is conventional commits — from `git log`: `fix: keep helper
  recovery actionable in development`, `docs: define stacked pull request
  workflow`. Use `test:` or `ci:` for this plan.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a syntax + lint step to CI, placed first so it fails fast

In `.github/workflows/ci.yml`, insert a new step immediately **after** the
`Check out source` step and **before** `Install Rust` (so a shell typo fails in
seconds rather than after a Rust toolchain install):

```yaml
      - name: Check shell scripts
        run: |
          set -euo pipefail
          scripts=(scripts/*.sh .githooks/post-merge bin/nearby-update-helper install.sh build.sh)
          for script in "${scripts[@]}"; do bash -n "$script"; done
          shellcheck -S warning "${scripts[@]}"
```

`shellcheck` is preinstalled on `ubuntu-latest`. If the run reports pre-existing
warnings, do **not** silence them by lowering `-S warning` to `-S error`. Fix
them only if the fix is confined to `.github/workflows/ci.yml` — which it will
not be — otherwise add a narrowly-targeted `# shellcheck disable=SCxxxx` line
with a one-sentence justification comment in the offending script, and note each
one in your final report. Note that `scripts/dependencies.sh` already carries one
such directive (`# shellcheck disable=SC2064`), so this pattern is established.

**Verify**: `bash -n .github/workflows/ci.yml` is not meaningful for YAML. Instead:
`python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo YAML-OK`
→ prints `YAML-OK`.

Also confirm locally that the loop body itself is sound:
`for s in scripts/*.sh .githooks/post-merge bin/nearby-update-helper install.sh build.sh; do bash -n "$s" || echo "SYNTAX FAIL: $s"; done`
→ no `SYNTAX FAIL` lines.

### Step 2: Create `tests/dependencies.test.sh` covering `--json` and `--check`

Create the file following the exemplar structure quoted in "Current state".
Cover these cases, each with `announce` + assertions:

1. `--json` emits parseable JSON. Run `bash scripts/dependencies.sh --json` and
   pipe it to `python3 -c "import json,sys; json.load(sys.stdin)"`; assert exit 0.
2. `--json` lists every id from the table. Assert the output contains each of:
   `wl-clipboard`, `libnotify`, `bluez`, `protobuf`, `pkgconf`, `cc`, `cargo`, `qs`.
3. `--json` marks a program absent when it is not on `PATH`. Create a sandbox
   with an empty `PATH` entry ordering such that `wl-copy` is not findable, run
   the script with that `PATH`, and assert the JSON has `"id":"wl-clipboard"`
   paired with `"present":false`. Parse with `python3` rather than substring
   matching, so field order cannot break the test.
4. `--check` exits 0 when nothing is missing and 1 when something is. Stub every
   probe binary into a sandbox `PATH` for the exit-0 case; remove one for the
   exit-1 case and assert its id appears on stdout.
5. Unknown flag is rejected: `bash scripts/dependencies.sh --nonsense` exits 2.

For the `qs` probe specifically: the script tests `[[ -x $QS_BIN ]]` where
`QS_BIN` is `<plugin_dir>/bin/nearby-qs`. Because `plugin_dir` is derived from
the script's own location, you cannot relocate it via `PATH`. Drive that case by
asserting only what is stable: that the `qs` entry is present in the `--json`
output with a boolean `present` field. Do **not** create or delete
`bin/nearby-qs` — it is a real user artifact on the development machine.

**Verify**: `bash tests/dependencies.test.sh` → prints the pass line, exit 0.
Confirm with `echo $?` → `0`.

### Step 3: Register the new test in CI

In `.github/workflows/ci.yml`, extend the existing `Test helper updater` step to
run both shell suites, and rename it:

```yaml
      - name: Test shell scripts
        run: |
          bash tests/updater.test.sh
          bash tests/dependencies.test.sh
```

**Verify**: `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/ci.yml')); names=[s.get('name') for s in d['jobs']['test']['steps']]; print(names)"`
→ the printed list contains `Check shell scripts` and `Test shell scripts`, and
no longer contains `Test helper updater`.

### Step 4: Confirm nothing else regressed

**Verify**: `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js && bash tests/updater.test.sh`
→ exit 0, each prints its pass line.

## Test plan

- New file: `tests/dependencies.test.sh`, structured after `tests/updater.test.sh`.
- Cases: the five listed in Step 2 — JSON validity, table completeness, absent-program
  detection, `--check` exit codes both ways, unknown-flag rejection.
- These tests describe **current** behaviour. Plan 002 adds the argv assertions
  for `--install`, which cannot pass until its bug is fixed.
- Verification: `bash tests/dependencies.test.sh` → all pass.

## Done criteria

ALL must hold:

- [ ] `bash tests/dependencies.test.sh` exits 0
- [ ] `bash tests/updater.test.sh` exits 0
- [ ] `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` exits 0
- [ ] `for s in scripts/*.sh .githooks/post-merge bin/nearby-update-helper install.sh build.sh; do bash -n "$s"; done` exits 0
- [ ] `.github/workflows/ci.yml` parses as YAML and contains steps named `Check shell scripts` and `Test shell scripts`
- [ ] `git status --porcelain` lists only `.github/workflows/ci.yml` and `tests/dependencies.test.sh`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `steps:` list in `.github/workflows/ci.yml` does not match the excerpt in
  "Current state" — the workflow has changed since this plan was written.
- `shellcheck -S warning` reports warnings that cannot be resolved without
  editing a file outside this plan's scope. Report the exact warnings and stop;
  do not edit `scripts/*.sh` to satisfy the linter, because plan 002 is
  concurrently rewriting part of `scripts/dependencies.sh`.
- You conclude a test can only pass if `scripts/dependencies.sh` is modified.
  That is plan 002's job. Write the test to assert current behaviour instead,
  and note it in your report.
- `bash tests/dependencies.test.sh` needs `sudo`, network access, or writes
  anywhere outside its own `mktemp` sandbox. It must not. Redesign or stop.

## Maintenance notes

- Every future shell script added to this repo must be appended to the `scripts`
  array in the `Check shell scripts` CI step. It is a literal list, not a glob
  over the whole tree, because `bin/` holds compiled binaries that `bash -n`
  would choke on.
- A reviewer should check that `tests/dependencies.test.sh` never invokes `sudo`,
  `pacman`, or `cargo` for real — all three must be stubbed onto `PATH`.
- Deliberately deferred: `shfmt` formatting enforcement, and testing
  `scripts/setup_firewall.sh` (plans 005 and 006 change it; test it after those
  land, not before).
