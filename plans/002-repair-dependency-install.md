# Plan 002: Make `dependencies.sh --install` actually install packages

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- scripts/dependencies.sh tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW (the fix), but see "Why this matters" — it makes a `sudo`
  command execute for the first time, so the quoting fix in Step 2 is not
  optional
- **Depends on**: `plans/001-shell-linting-and-dependency-tests.md`
- **Category**: bug
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

`scripts/dependencies.sh --install` is the plugin's headline "install what's
missing" feature. It is wired to a button in the Quick Share panel and to a git
hook that fires on every `omarchy plugin update`. **Its package-installation
path never runs.** Not "sometimes fails" — never runs, for any input.

The cause is a shell idiom that does not do what it looks like it does. The
package name for each missing program is harvested with a `while read` loop
whose body is empty, relying on the loop variables surviving. They do not: when
`read` hits EOF it returns non-zero **and clears every variable it names**. So
`$pkgs` is empty on every iteration, `pac+=($pkgs)` appends zero elements, and
both `(( ${#pac[@]} ))` guards are false. The user sees "Missing: protobuf
pkgconf cc", no pacman step runs, and the script may still print "Dependencies
installed successfully."

This was reproduced in isolation before this plan was written:

```
  id=bluez -> pkgs=[]
  id=cargo -> pkgs=[]
  FINAL pac count = 0  contents=[]
```

There is a second, latent bug hiding behind the first. `pac+=($pkgs)` is an
**unquoted** expansion, so once `$pkgs` is non-empty its contents are subject to
word splitting *and glob expansion* before landing in an array that is passed to
`sudo pacman`. Word splitting is intended here (the table's package field holds
space-separated names such as `bluez bluez-utils`); glob expansion is not. Fixing
the lookup without fixing the splitting turns a dormant bug into a live one on a
privileged command line, which is why both changes are in this plan and must land
together.

## Current state

Files involved:

- `scripts/dependencies.sh` — the whole script. The `deps()` function at the top
  emits a pipe-delimited table; `install_missing()` consumes it.
- `tests/dependencies.test.sh` — created by plan 001. You will extend it.

The table `deps()` emits (id|label|probe|packages|scope). Note field 4 for
`bluez` holds **two** space-separated package names, and `qs` uses `-` as a
"no pacman package" sentinel:

```
wl-clipboard|Clipboard access|wl-copy|wl-clipboard|core
libnotify|Desktop notifications|notify-send|libnotify|core
bluez|Bluetooth stack|bluetoothctl|bluez bluez-utils|quickshare
protobuf|Protocol buffer compiler|protoc|protobuf|quickshare-build
pkgconf|Build configuration|pkgconf|pkgconf|quickshare-build
cc|C toolchain|cc|base-devel|quickshare-build
cargo|Rust toolchain|cargo|rustup|quickshare-build
qs|Quick Share CLI|qs|-|quickshare
```

The broken block, verbatim from `scripts/dependencies.sh` (the `for` loop begins
at the line reading `for id in "${missing[@]}"; do`):

```bash
  # Collect pacman packages for everything missing except qs, which cargo owns.
  local id label probe pkgs scope
  local -a pac=()
  local want_qs=0
  for id in "${missing[@]}"; do
    if [[ $id == qs ]]; then want_qs=1; continue; fi
    while IFS='|' read -r label probe pkgs scope; do :; done < <(
      deps | awk -F'|' -v id="$id" '$1==id {print $2"|"$3"|"$4"|"$5}'
    )
    [[ $pkgs == "-" ]] || pac+=($pkgs)
  done
```

The consumer, further down the same function:

```bash
  if (( ${#pac[@]} )); then
    echo "Running pacman with root privileges..."
    sudo pacman -S --needed "${pac[@]}" || {
      local status=$?
      echo "Package installation failed (exit code: $status)."
      sleep 2.5
      return "$status"
    }
  fi
```

**Repo conventions that apply here:**

- The script runs under `set -uo pipefail` — note **no `-e`**. Failures do not
  abort; every command whose failure matters must be checked explicitly. Do not
  add `set -e` in this plan: other functions in the file rely on its absence.
- Comments explain *why*, in full sentences. The existing comment block above
  `QS_BIN` (explaining the `/usr/bin/qs` collision with Quickshell's CLI) is the
  register to match.
- `local x=$(cmd)` masks `cmd`'s exit status, because `local` is itself a command
  whose status wins. If you need the status, declare and assign on separate lines.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Syntax check | `bash -n scripts/dependencies.sh` | exit 0, no output |
| JSON mode | `bash scripts/dependencies.sh --json` | valid JSON, exit 0 |
| Check mode | `bash scripts/dependencies.sh --check` | exit 0 or 1; ids on stdout when 1 |
| New tests | `bash tests/dependencies.test.sh` | pass line, exit 0 |
| Existing shell tests | `bash tests/updater.test.sh` | pass line, exit 0 |

**Never run `bash scripts/dependencies.sh --install` directly.** It invokes
`sudo pacman` and a multi-hundred-crate `cargo` build. All verification goes
through the stubbed test harness.

## Scope

**In scope**:
- `scripts/dependencies.sh` — only `install_missing()`
- `tests/dependencies.test.sh` — extend with `--install` argv assertions

**Out of scope** (do NOT touch):
- The `deps()` table contents. Adding or correcting package names is a separate
  finding; changing it here would make the test fixtures ambiguous.
- `.githooks/post-merge` — whether a git hook should launch a privileged
  installer at all is a separate, still-open question. This plan makes the
  installer work; it does not change who may call it.
- `emit_json()` and `missing_ids()` — they are correct.
- `scripts/setup_firewall.sh` — plans 005 and 006.

## Git workflow

- Branch: `advisor/002-repair-dependency-install`
- Conventional commits; `fix:` is correct for this change.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Replace the lookup loop with a direct field extraction

Replace the whole `for id in "${missing[@]}"; do ... done` block quoted above
with a version that reads field 4 directly and cannot silently yield empty:

```bash
  # Collect pacman packages for everything missing except qs, which cargo owns.
  local id pkgs
  local -a pac=()
  local want_qs=0
  for id in "${missing[@]}"; do
    if [[ $id == qs ]]; then want_qs=1; continue; fi
    # A `while read` loop over the table looks equivalent and is not: the final
    # read returns non-zero at EOF and clears the variables it names, so the
    # package field was always empty by the time it was used.
    pkgs=$(deps | awk -F'|' -v id="$id" '$1 == id { print $4; exit }')
    if [[ -z $pkgs ]]; then
      echo "dependencies.sh: no table entry for '$id'; skipping." >&2
      continue
    fi
    [[ $pkgs == "-" ]] && continue
    # Word splitting is wanted (a field may hold several package names) but glob
    # expansion is not, and this list is about to become a sudo command line.
    local -a names=()
    read -ra names <<<"$pkgs"
    pac+=("${names[@]}")
  done
```

Note three things this changes beyond the bug fix: an unknown id is now reported
instead of silently contributing nothing; the `-` sentinel is handled with an
explicit `continue`; and `read -ra` performs the field splitting with globbing
disabled.

**Verify**: `bash -n scripts/dependencies.sh` → exit 0.

### Step 2: Harden the `pacman` invocation

The array is now non-empty for the first time, so the command line it builds
must be unambiguous. In the `if (( ${#pac[@]} )); then` block, add a `--`
terminator so no package name can be parsed as an option:

```bash
    sudo pacman -S --needed -- "${pac[@]}" || {
```

Also update the preview banner earlier in the function so what is *shown* matches
what is *run*. Find the here-doc containing `sudo pacman -S --needed ${pac[*]}`
and change that line to `  sudo pacman -S --needed -- ${pac[*]}`.

**Verify**: `bash -n scripts/dependencies.sh` → exit 0, and
`grep -c 'pacman -S --needed --' scripts/dependencies.sh` → `2` (the banner and
the real invocation).

### Step 3: Add argv assertions to the test harness

Extend `tests/dependencies.test.sh` (created by plan 001) with `--install`
cases. Stub `sudo`, `pacman`, and `cargo` onto `PATH` as scripts that record
their argv to a file and exit 0, then assert on the recorded argv. Feed
`--install` from `/dev/null` so the `[[ -t 0 ]]` prompt is skipped.

Cases to cover:

1. **The regression gate.** With `wl-copy` and `notify-send` absent from `PATH`,
   `--install` must invoke `sudo` at least once, and the recorded argv must
   contain `pacman`, `-S`, `--needed`, `--`, `wl-clipboard`, and `libnotify`.
   *This assertion fails against the pre-fix script* — confirm that by stashing
   your change (`git stash`), running the test to see it fail, then restoring
   (`git stash pop`). Report both outcomes.
2. **Multi-package field.** With `bluetoothctl` absent, the recorded argv must
   contain both `bluez` and `bluez-utils` as separate arguments.
3. **The `-` sentinel.** A run where `qs` is the only missing entry must not
   invoke `pacman` at all.
4. **No glob leakage.** Create a file named `bluez-victim` in the sandbox
   working directory, `cd` there, and assert the recorded argv does not contain
   it — proving the package field is not glob-expanded.
5. **Nothing missing.** With every probe stubbed present, `--install` prints the
   "All Nearby Share dependencies are present." line and invokes neither `sudo`
   nor `cargo`.

The `cargo` stub matters: without it, case 1 could reach the real
`cargo install --git` if `qs` is also missing. Stub it unconditionally.

**Verify**: `bash tests/dependencies.test.sh` → pass line, exit 0.

### Step 4: Confirm the non-install paths still behave

**Verify**:
`bash scripts/dependencies.sh --json | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['deps']))"`
→ prints `8`.
`bash scripts/dependencies.sh --check; echo "exit=$?"` → exit is `0` or `1`
(either is acceptable; it reflects this machine's real state).

## Test plan

- Extend `tests/dependencies.test.sh` with the five `--install` cases above.
- Structural pattern: `tests/updater.test.sh` — stub binaries on `PATH`, one
  `mktemp` sandbox per case, `announce`/`assert_eq`/`assert_contains` helpers.
- The regression-specific test is case 1; it must fail before Step 1 and pass
  after.
- Verification: `bash tests/dependencies.test.sh` → all pass.

## Done criteria

ALL must hold:

- [ ] `bash -n scripts/dependencies.sh` exits 0
- [ ] `bash tests/dependencies.test.sh` exits 0, including the five new `--install` cases
- [ ] `bash tests/updater.test.sh` exits 0
- [ ] `grep -c 'while IFS=.|. read' scripts/dependencies.sh` returns `0`
- [ ] `grep -c 'pac+=(\$pkgs)' scripts/dependencies.sh` returns `0`
- [ ] `grep -c 'pacman -S --needed --' scripts/dependencies.sh` returns `2`
- [ ] `bash scripts/dependencies.sh --json` is valid JSON with 8 entries
- [ ] `git status --porcelain` lists only `scripts/dependencies.sh` and `tests/dependencies.test.sh`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `for id in "${missing[@]}"` block does not match the excerpt in "Current
  state" — the script changed since this plan was written.
- Any verification would require running `--install` without stubs. It must not.
- You find yourself needing to edit the `deps()` table to make a test pass. The
  table is out of scope; report what you found instead.
- Case 1 passes *before* you make the Step 1 change. That would mean the bug is
  not what this plan describes — stop and report, because the rest of the plan's
  reasoning is then suspect.

## Maintenance notes

- The `while read` idiom removed here is a recurring shell trap. If a future
  change needs several fields from the table, extract them with one `awk` call
  into a single variable and split explicitly — do not reintroduce a loop whose
  body is `:`.
- A reviewer should check that `--` appears in **both** the banner and the real
  `sudo pacman` line, since those two drifting apart is exactly how a user ends
  up consenting to one command and running another.
- Deliberately deferred: the `deps()` table is missing `dbus` and `bluez-libs`
  that `README.md` lists, the `bluez` probe does not check whether
  `bluetooth.service` is running, and the `qs` probe only tests `-x` (a truncated
  binary reads as present). All three are table/probe concerns, tracked
  separately.
