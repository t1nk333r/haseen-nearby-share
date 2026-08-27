# Plan 017: Correct the dependency table and stop staging inside the watched tree

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- scripts/dependencies.sh bin/nearby-update-helper QuickShare.qml tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: `plans/002-repair-dependency-install.md` (002 rewrites the
  lookup this plan's table feeds)
- **Category**: bug
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

Two unrelated defects in the same file, both cheap.

**Probes that pass while the feature is still broken.** The dependency table is
the user's only signal for why Quick Share is not working, and three of its
entries can report "present" when the thing they gate is unusable:

- `bluez` is probed by testing that the `bluetoothctl` *binary* exists. It says
  nothing about `bluetooth.service` running or an adapter being present — and on
  Arch, `bluez` installs the service disabled by default. Quick Share discovery
  uses Bluetooth LE, so this is the difference between "installed" and "working".
- The `qs` probe is `[[ -x $QS_BIN ]]`. A truncated or wrong-architecture file at
  that path — for instance from a `mv` that failed halfway — reports as present.
- `README.md` lists `dbus` and `bluez-libs` among Quick Share's requirements;
  neither appears in the table. They arrive as transitive dependencies of
  `bluez` today, which makes this latent rather than broken, but the table is
  documented as the authority and disagrees with the README.

**Staging directories are created inside the plugin tree.** Both
`scripts/dependencies.sh` and (before plan 015 deletes it) `install.sh` create
`mktemp -d` directories under `bin/`. The shell watches the plugin directory and
reloads the plugin when anything under it changes — which can kill a
multi-minute `cargo` build mid-flight. This is not speculative: it is the exact
problem `bin/nearby-update-helper` was rewritten to avoid, and it says so at
length in its own comments before staging under the cache directory instead.

`bin/*` is gitignored, so leaked staging directories are also invisible to
`git status` and accumulate silently.

## Current state

`scripts/dependencies.sh` — the table:

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

The `qs` probe special case:

```bash
have_dep() {
  local id=$1 probe=$2
  if [[ $id == qs ]]; then
    [[ -x $QS_BIN ]]
    return
  fi
  have "$probe"
}
```

The staging directory, created inside the watched tree:

```bash
    local stage
    stage=$(mktemp -d "${plugin_dir}/bin/.qs-build.XXXXXX") || return 1
```

and the unchecked move that follows the build:

```bash
    mv -- "$stage/bin/qs" "$QS_BIN"
    chmod 0755 "$QS_BIN"
    echo "Installed $QS_BIN"
```

`bin/nearby-update-helper` — the decision this plan propagates, in its own words,
and the orphan sweep whose glob no longer matches anything any code creates:

```bash
"$plugin_dir"/bin/.update.*
```

That pattern matches neither `.install.XXXXXX` (`install.sh`) nor
`.qs-build.XXXXXX` (`dependencies.sh`), and `nearby-update-helper` itself now
stages under the cache root — so the sweep is dead code guarding a leak that
moved.

**Note on `base-devel`**: it is a **meta-package**, not a group, on current Arch
(verified with `pacman -Qi base-devel`). `pacman -S --needed base-devel` does not
prompt for member selection. Do not "fix" this entry.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Syntax check | `bash -n scripts/dependencies.sh` | exit 0 |
| JSON mode | `bash scripts/dependencies.sh --json` | valid JSON |
| Dependency tests | `bash tests/dependencies.test.sh` | pass line, exit 0 |

**Never run `--install`.**

## Scope

**In scope**:
- `scripts/dependencies.sh` — the table, `have_dep`, the staging path, the `mv`
- `bin/nearby-update-helper` — the dead orphan-sweep glob
- `README.md` — only if the table changes make its dependency list wrong
- `tests/dependencies.test.sh` — extend

**Out of scope** (do NOT touch):
- The lookup loop — plan 002 rewrites it. If 002 has not landed, do not fix it
  here; add table entries in the existing format and let 002 handle consumption.
- `install.sh` — plan 015 deletes it. If it still exists, leave its staging path
  alone rather than fixing a file that is about to go.
- The `scope` column's vocabulary (`core` / `quickshare` / `quickshare-build`) —
  `QuickShare.qml` reads it; changing the values needs a lockstep QML change.

## Git workflow

- Branch: `advisor/017-dependency-table-and-staging`
- Conventional commits; `fix:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Stage outside the watched plugin tree

Replace the staging directory with one under the cache root, matching the
decision `bin/nearby-update-helper` already documents:

```bash
    local cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-nearby"
    mkdir -p "$cache_root" || return 1
    local stage
    stage=$(mktemp -d "$cache_root/qs-build.XXXXXX") || return 1
```

Add a comment naming the reason, since the reason is non-obvious:

```bash
    # Not under the plugin directory: the shell watches that tree and reloads
    # the plugin when anything in it changes, which can kill a multi-minute
    # cargo build. bin/nearby-update-helper was moved here for the same reason.
```

**Verify**: `bash -n scripts/dependencies.sh` → exit 0;
`grep -c 'plugin_dir}/bin/.qs-build' scripts/dependencies.sh` → `0`;
`grep -c 'XDG_CACHE_HOME' scripts/dependencies.sh` → at least `1`.

### Step 2: Clean up on signals, not only on return

The existing `trap ... RETURN` fires on the function's return paths but **not**
when the process is signalled — and the banner explicitly invites `Ctrl+C`
during a build that takes minutes. Add an EXIT/INT/TERM trap alongside it:

```bash
    # shellcheck disable=SC2064
    trap "rm -rf -- '$stage'" RETURN
    # shellcheck disable=SC2064
    trap "rm -rf -- '$stage'; exit 130" INT TERM
```

**Verify**: `bash -n scripts/dependencies.sh` → exit 0;
`grep -c 'INT TERM' scripts/dependencies.sh` → `1`.

### Step 3: Check the move and the chmod

The script runs under `set -uo pipefail` with no `-e`, so an unchecked `mv`
falls through to "Installed …" and `return 0`:

```bash
    if ! mv -- "$stage/bin/qs" "$QS_BIN"; then
      echo "Could not install the Quick Share CLI to $QS_BIN." >&2
      sleep 2.5
      return 1
    fi
    chmod 0755 "$QS_BIN" || { echo "Could not make $QS_BIN executable." >&2; return 1; }
    echo "Installed $QS_BIN"
```

**Verify**: `grep -c 'if ! mv --' scripts/dependencies.sh` → `1`.

### Step 4: Strengthen the `qs` probe

An executable bit is not evidence the binary runs. Replace the probe:

```bash
  if [[ $id == qs ]]; then
    # -x only says the bit is set. A truncated or wrong-architecture file passes
    # that and then fails at the first real invocation, which the panel reports
    # as a mysterious scan failure rather than a bad install.
    [[ -x $QS_BIN ]] && "$QS_BIN" --version >/dev/null 2>&1
    return
  fi
```

**Verify**: `bash scripts/dependencies.sh --json | python3 -c "import json,sys; d=json.load(sys.stdin); print([x['present'] for x in d['deps'] if x['id']=='qs'])"`
→ prints `[True]` if `bin/nearby-qs` is a working binary on this machine,
`[False]` otherwise. Either is correct; confirm it matches reality by running
`./bin/nearby-qs --version` yourself.

### Step 5: Add the missing packages, and a service-state advisory

Add `dbus` and `bluez-libs` to the `bluez` row's package field so the table
matches `README.md`:

```
bluez|Bluetooth stack|bluetoothctl|bluez bluez-libs bluez-utils dbus|quickshare
```

For the service-state problem, do **not** fold it into `present` — that would
change the JSON contract `QuickShare.qml` consumes. Add a separate advisory line
to the `--check` and `--install` output instead:

```bash
# Installed is not the same as running, and Quick Share discovery needs the
# service, not just the binary. Reported separately so the JSON contract the
# panel consumes keeps meaning exactly "the program is installed".
bluetooth_advisory() {
  command -v systemctl >/dev/null 2>&1 || return 0
  command -v bluetoothctl >/dev/null 2>&1 || return 0
  systemctl is-active --quiet bluetooth && return 0
  echo "Note: bluetooth.service is not running. Quick Share discovery needs it:" >&2
  echo "  sudo systemctl enable --now bluetooth" >&2
}
```

Call it at the end of the `--check` branch and after a successful `--install`.

**Verify**: `bash scripts/dependencies.sh --check >/dev/null; echo "exit=$?"` →
`0` or `1`, and any advisory appears on stderr, not stdout (stdout must stay
parseable);
`bash scripts/dependencies.sh --json | python3 -c "import json,sys; json.load(sys.stdin)"` → exit 0.

### Step 6: Fix or delete the dead orphan sweep

In `bin/nearby-update-helper`, the sweep globs `"$plugin_dir"/bin/.update.*`,
which nothing creates any more. Either widen it to the names that *are* created
under `bin/`, or delete it and note that staging now lives in the cache root.

Prefer deleting: after Step 1 nothing stages under `bin/` at all, so a sweep
there guards nothing. Replace it with a cache-root sweep if you want the
hygiene, or remove it outright and say which you chose.

**Verify**: `bash -n bin/nearby-update-helper` → exit 0;
`bash tests/updater.test.sh` → pass line, exit 0.

### Step 7: Tests

Extend `tests/dependencies.test.sh`:

1. `--json` still emits 8 entries with valid JSON after the table change.
2. The `bluez` row's package field contains four packages — assert via the
   `--install` argv stub with `bluetoothctl` absent.
3. `qs` probe: with a stub `nearby-qs` that exits non-zero for `--version`, the
   `qs` entry reports `present: false`. This needs the probe to be redirectable;
   if `QS_BIN` cannot be pointed at a stub without editing the script, assert
   the weaker property that the probe invokes the binary at all, and say so.
4. Advisory goes to stderr: `--check`'s stdout remains exactly the missing ids.

**Verify**: `bash tests/dependencies.test.sh` → pass line, exit 0.

## Test plan

- Four cases as above, in the file plan 001 created.
- Case 4 matters most: `QuickShare.qml` parses `--json`'s stdout, so anything
  advisory leaking there breaks the pane.
- Verification: `bash tests/dependencies.test.sh` and `bash tests/updater.test.sh`
  → all pass.

## Done criteria

ALL must hold:

- [ ] `bash -n scripts/dependencies.sh bin/nearby-update-helper` exits 0
- [ ] `grep -c 'plugin_dir}/bin/.qs-build' scripts/dependencies.sh` returns `0`
- [ ] `grep -c 'XDG_CACHE_HOME' scripts/dependencies.sh` returns at least `1`
- [ ] `grep -c 'if ! mv --' scripts/dependencies.sh` returns `1`
- [ ] `grep -c 'INT TERM' scripts/dependencies.sh` returns `1`
- [ ] `bash scripts/dependencies.sh --json` is valid JSON with 8 entries
- [ ] `bash scripts/dependencies.sh --check` writes only missing ids to stdout
- [ ] `bash tests/dependencies.test.sh && bash tests/updater.test.sh` exits 0
- [ ] `git status --porcelain` lists only the in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The table or the staging block do not match the excerpts in "Current state".
- You are tempted to change `base-devel` to `gcc` or to treat it as a group. It
  is a meta-package on current Arch; verified. Leave it.
- Adding the service advisory changes anything on **stdout** for `--json` or
  `--check`. `QuickShare.qml` parses that stdout; a stray line breaks the pane.
- Strengthening the `qs` probe makes `--json` slow enough to be noticeable — it
  now execs a binary on every probe. If it adds more than a few tens of
  milliseconds, report rather than shipping a laggy panel.

## Maintenance notes

- The rule this plan propagates: **never stage under the plugin directory.** The
  shell watches it and reloads on change, which kills long-running work.
  `bin/nearby-update-helper` learned this first; now `dependencies.sh` follows.
- `present` in the JSON means exactly "the program is installed". Anything about
  whether it *works* — a service state, an adapter, a permission — goes to
  stderr as an advisory, so the panel's contract stays simple.
- Deliberately deferred: a richer dependency state (`installed but not running`)
  surfaced in the panel UI. That changes the JSON contract and needs a lockstep
  `QuickShare.qml` change; worth doing if bluetooth-not-running turns out to be
  a common support question.
