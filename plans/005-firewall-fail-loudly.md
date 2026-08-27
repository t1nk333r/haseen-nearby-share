# Plan 005: Stop the firewall script reporting success after a failed rule

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- scripts/setup_firewall.sh tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW — the change turns silent failures into loud ones
- **Depends on**: none (plan 006 builds on this file; land 005 first)
- **Category**: bug
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

`scripts/setup_firewall.sh` opens the four ports this plugin needs. It applies
each rule with a separate `sudo` call and then tells the user "Firewall rules
applied successfully." That message is printed even when rules failed.

The script sets `set -euo pipefail`, so it looks like any failing command aborts
it. It does not, because the rule-applying functions are invoked as the
*condition of an `if`*. Bash suppresses `errexit` for the entire dynamic extent
of a condition command — including inside functions it calls. Verified in
isolation before this plan was written:

```
  rule1 ok
  rule3 STILL RAN
  RESULT: reported SUCCESS
```

So a failure on rule two lets rules three through five run anyway, and the
function's exit status is whichever the *last* command returned — `sudo ufw
reload` or `sudo firewall-cmd --reload`, both of which succeed regardless of
whether the preceding rules were added.

The user-visible consequence is the hardest kind of bug to diagnose: transfers
work for LocalSend and silently time out for Quick Share (or discovery never
resolves), while the tool that exists to prevent exactly that has already
reported the firewall is fine. The `exit "$status"` error branches further down
the script are effectively unreachable.

## Current state

File: `scripts/setup_firewall.sh`, 114 lines. It defines four ports as
`readonly` constants, prints a banner, then dispatches on which firewall tool is
installed.

The UFW rule block (inside `apply_ufw`):

```bash
  echo "Applying UFW firewall rules with root privileges..."
  sudo ufw allow "${LOCALSEND_PORT}/tcp" comment 'Nearby Share (LocalSend)'
  sudo ufw allow "${LOCALSEND_PORT}/udp" comment 'Nearby Share (LocalSend)'
  sudo ufw allow "${MDNS_PORT}/udp" comment 'Nearby Share (mDNS)'
  sudo ufw allow "${QUICKSHARE_PORT}/tcp" comment 'Nearby Share (Quick Share)'
  sudo ufw reload
}
```

`apply_firewalld` has the identical shape, ending in `sudo firewall-cmd --reload`.

The dispatcher that defeats `errexit`:

```bash
if command -v ufw >/dev/null 2>&1; then
  if apply_ufw; then
    echo
    echo "Firewall rules applied successfully."
    sleep 1.5
  else
    status=$?
    echo
    echo "Failed to configure UFW rules (exit code: $status)."
    sleep 2.5
    exit "$status"
  fi
elif command -v firewall-cmd >/dev/null 2>&1; then
  if apply_firewalld; then
```

Note also `status=$?` inside the `else` branch: by that point `$?` is the `if`'s
own evaluation, not the function's, so the reported exit code is unreliable too.

**Repo conventions:**

- Comments explain *why* in full sentences. The file's header comment (explaining
  why Quick Share needs one pinned port rather than a high-port range) is the
  register to match.
- `scripts/dependencies.sh` uses `set -uo pipefail` (no `-e`) and checks failures
  explicitly; this file uses `set -euo pipefail`. Keep this file's `-e`.
- The repo's shell test exemplar is `tests/updater.test.sh` — stub binaries on
  `PATH`, one `mktemp` sandbox per case, `announce`/`report`/`assert_eq`/
  `assert_contains` helpers, exit non-zero if `failures` is non-zero.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Syntax check | `bash -n scripts/setup_firewall.sh` | exit 0, no output |
| New tests | `bash tests/firewall.test.sh` | pass line, exit 0 |
| Other shell tests | `bash tests/updater.test.sh` | pass line, exit 0 |

**Never run `scripts/setup_firewall.sh` directly.** It invokes `sudo ufw` and
would modify this machine's live firewall. All verification goes through the
stubbed harness, which puts a fake `ufw` on `PATH`.

## Scope

**In scope**:
- `scripts/setup_firewall.sh` — the two `apply_*` functions and the dispatcher
- `tests/firewall.test.sh` (create)

**Out of scope** (do NOT touch):
- The rule *contents* — which ports, and whether they should be scoped to the
  local subnet, is plan 006. This plan changes only failure propagation. Do not
  add a `from` clause here; it would make plan 006's fixtures ambiguous.
- The banner text — also plan 006.
- `scripts/dependencies.sh`, `.githooks/post-merge`, `scripts/setup.sh`.

## Git workflow

- Branch: `advisor/005-firewall-fail-loudly`
- Conventional commits; `fix:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Accumulate and report per-rule status in `apply_ufw`

Replace the rule block in `apply_ufw` so each rule's failure is captured and
named, and the function returns non-zero if any failed:

```bash
  echo "Applying UFW firewall rules with root privileges..."
  # These run as the condition of an `if` in the dispatcher below, and bash
  # suppresses errexit for the whole dynamic extent of a condition -- including
  # inside called functions. Each rule therefore has to report for itself, or a
  # failed rule is announced as a success.
  local rc=0
  local rule
  for rule in \
    "${LOCALSEND_PORT}/tcp|Nearby Share (LocalSend)" \
    "${LOCALSEND_PORT}/udp|Nearby Share (LocalSend)" \
    "${MDNS_PORT}/udp|Nearby Share (mDNS)" \
    "${QUICKSHARE_PORT}/tcp|Nearby Share (Quick Share)"; do
    local port=${rule%%|*}
    local label=${rule#*|}
    if ! sudo ufw allow "$port" comment "$label"; then
      echo "  FAILED: $port ($label)" >&2
      rc=1
    fi
  done
  if ! sudo ufw reload; then
    echo "  FAILED: ufw reload" >&2
    rc=1
  fi
  return "$rc"
```

**Verify**: `bash -n scripts/setup_firewall.sh` → exit 0.

### Step 2: Do the same for `apply_firewalld`

Apply the identical treatment to `apply_firewalld`: check each
`sudo firewall-cmd --permanent --add-port=` / `--add-service=` call, print a
`  FAILED: <what>` line to stderr on failure, set `rc=1`, check the final
`--reload`, and `return "$rc"`.

**Verify**: `bash -n scripts/setup_firewall.sh` → exit 0, and
`grep -c 'return "$rc"' scripts/setup_firewall.sh` → `2`.

### Step 3: Capture the function's real exit status in the dispatcher

`status=$?` inside the `else` branch of an `if` does not hold the function's
status. Restructure both dispatcher arms to run the function first and capture
immediately:

```bash
if command -v ufw >/dev/null 2>&1; then
  status=0
  apply_ufw || status=$?
  if (( status == 0 )); then
    echo
    echo "Firewall rules applied successfully."
    sleep 1.5
  else
    echo
    echo "Failed to configure UFW rules (exit code: $status)."
    echo "Some ports may be open and others closed; re-run this script after fixing the cause."
    sleep 2.5
    exit "$status"
  fi
elif command -v firewall-cmd >/dev/null 2>&1; then
```

Apply the same shape to the `firewall-cmd` arm. Note `apply_ufw || status=$?`
is still a condition context, so `errexit` stays suppressed inside — which is
exactly why Steps 1 and 2 made the functions report for themselves.

**Verify**: `bash -n scripts/setup_firewall.sh` → exit 0, and
`grep -c 'status=\$?$' scripts/setup_firewall.sh` → `0` (the old bare form is gone).

### Step 4: Create `tests/firewall.test.sh`

Follow `tests/updater.test.sh`'s structure. Put a stub `ufw` on `PATH` that
records its argv and whose exit code is controlled by an environment variable,
then assert the script's behaviour. Feed the script from `/dev/null` so its
`[[ -t 0 ]]` prompt is skipped, and stub `sudo` as a script that simply execs
its arguments (so `sudo ufw ...` reaches the stub `ufw`).

Cases:

1. **The regression gate.** Stub `ufw` to fail on the *second* `allow` call and
   succeed otherwise. Run the script. Assert: exit status is non-zero, stdout
   does **not** contain `applied successfully`, and stderr contains `FAILED:`.
   *This fails against the pre-fix script* — verify by stashing your change.
2. All rules succeed → exit 0, stdout contains `applied successfully`, and the
   recorded argv shows four `allow` calls plus one `reload`.
3. `reload` fails, all rules succeed → non-zero exit, no `applied successfully`.
4. Neither `ufw` nor `firewall-cmd` on `PATH` → exit 0 and stdout names the four
   ports for manual configuration (this branch is advisory, not a failure).

**Verify**: `bash tests/firewall.test.sh` → pass line, exit 0.

### Step 5: Register the test in CI

If `plans/001-shell-linting-and-dependency-tests.md` has landed, add
`bash tests/firewall.test.sh` to the `Test shell scripts` step in
`.github/workflows/ci.yml`, and add `scripts/setup_firewall.sh` to the `scripts`
array of the `Check shell scripts` step if it is not already covered by the
`scripts/*.sh` glob (it is — confirm rather than duplicate).

If plan 001 has **not** landed, skip this step and say so in your report; do not
invent a CI step, because plan 001 owns that file's structure.

**Verify**: if applied, `python3 -c "import yaml; d=yaml.safe_load(open('.github/workflows/ci.yml')); print(open('.github/workflows/ci.yml').read().count('firewall.test.sh'))"` → `1`.

## Test plan

- New file `tests/firewall.test.sh`, modelled on `tests/updater.test.sh`.
- Cases: the four in Step 4. Case 1 is the regression gate and must fail before
  Steps 1–3.
- The harness must never touch the real firewall: `ufw` and `firewall-cmd` are
  stubs on `PATH`, and `sudo` is a stub that execs its arguments.
- Verification: `bash tests/firewall.test.sh` → all pass.

## Done criteria

ALL must hold:

- [ ] `bash -n scripts/setup_firewall.sh` exits 0
- [ ] `bash tests/firewall.test.sh` exits 0 with four cases
- [ ] `bash tests/updater.test.sh` exits 0
- [ ] `grep -c 'return "$rc"' scripts/setup_firewall.sh` returns `2`
- [ ] `grep -c 'status=\$?$' scripts/setup_firewall.sh` returns `0`
- [ ] Case 1 fails when the Step 1–3 changes are reverted (verified, then restored)
- [ ] `git status --porcelain` lists only `scripts/setup_firewall.sh`, `tests/firewall.test.sh`, and possibly `.github/workflows/ci.yml`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `apply_ufw`, `apply_firewalld`, or the dispatcher do not match the excerpts in
  "Current state".
- Any verification would run the real `ufw` or `firewall-cmd`. It must not — if
  a stub is being bypassed, stop and fix the harness before continuing.
- The test harness requires `sudo` for real. It must not.
- Case 1 passes before the fix is applied.

## Maintenance notes

- The `if apply_x; then` shape is what defeated `errexit` here. Any future
  function in this repo called from a condition context must report its own
  failures; `set -e` will not do it. Worth stating in a comment at any new call
  site.
- A reviewer should confirm the script still exits non-zero on partial failure
  *and* that the success message is unreachable in that case — those are two
  separate assertions and case 1 covers both.
- Plan 006 changes the rule contents in this same file. Land this plan first so
  006 inherits working failure propagation and its own tests can rely on it.
