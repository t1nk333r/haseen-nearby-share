# Plan 013: Stop automatic and unattended paths reaching a privileged installer

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- .githooks/post-merge scripts/dependencies.sh scripts/setup_firewall.sh README.md tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW — the change strictly reduces what runs automatically
- **Depends on**: `plans/001-shell-linting-and-dependency-tests.md`
- **Category**: security
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

Two consent failures, opposite in shape.

**Too much happens automatically.** `omarchy plugin update` ends in
`git merge --ff-only`, which fires `post-merge`. The hook then spawns a terminal
running `dependencies.sh --install`, which runs `sudo pacman` and
`cargo install --git`. The user consented to *updating a plugin*, not to a root
package operation — and a window that appears on its own demanding a sudo
password is exactly the shape users are taught to distrust. Since the hook script
and the installer both come from the tree that was just merged, an upstream
compromise escalates from "user-level QML on next shell reload" to "root package
install on next pull".

**Too little is required when nobody is watching.** Both privileged scripts gate
their confirmation prompt on `[[ -t 0 ]]`. When stdin is not a terminal the
prompt is *skipped* and execution proceeds. The guard fails open — and it fails
open uselessly, because without a TTY `sudo` cannot read a password either, so
the realistic outcome is an unattended `sudo` failure rather than an install.

There is also a smaller honesty bug: the hook fires `notify-send` claiming
"Installing: …" **before** deciding how to launch anything, and one of its
branches does nothing at all. On that path the user is told an install started
that never did — which today is the guaranteed outcome, because the installer's
package path is inert until plan 002 lands.

## Current state

`.githooks/post-merge` — the notification precedes the launch decision, and the
`if` has a silent fall-through:

```bash
count=$(printf '%s\n' "$missing" | grep -c .)
summary=$(printf '%s' "$missing" | tr '\n' ' ')

if command -v notify-send >/dev/null 2>&1; then
  notify-send --app-name="Nearby Share" \
    "Nearby Share: $count missing dependenc$([[ $count == 1 ]] && echo y || echo ies)" \
    "Installing: ${summary% }"
fi

# A pull is not necessarily happening in a terminal the user is watching, so
# ask for one rather than assuming this stdout is visible.
if command -v omarchy-launch-floating-terminal-with-presentation >/dev/null 2>&1; then
  setsid omarchy-launch-floating-terminal-with-presentation \
    "bash '$checker' --install" >/dev/null 2>&1 &
elif [[ -t 1 ]]; then
  "$checker" --install
elif command -v xdg-terminal-exec >/dev/null 2>&1; then
  setsid xdg-terminal-exec bash "$checker" --install >/dev/null 2>&1 &
fi

exit 0
```

`scripts/dependencies.sh` — the fail-open gate:

```bash
  if [[ -t 0 ]]; then
    printf 'Press Enter to proceed with installation, or Ctrl+C to cancel: '
    read -r _
  fi
```

`scripts/setup_firewall.sh` has the identical pattern in both `apply_ufw` and
`apply_firewalld`.

The hook's own stated intent, from its header comment — the property this plan
restores:

```
# Deliberately never runs sudo itself: it opens the installer in a terminal,
# where a password prompt has somewhere to appear and the user can still say no.
```

**Conventions**: `scripts/dependencies.sh` runs `set -uo pipefail` (no `-e`);
`.githooks/post-merge` the same. Comments explain *why* in full sentences.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Syntax check | `bash -n .githooks/post-merge scripts/dependencies.sh scripts/setup_firewall.sh` | exit 0 |
| Dependency tests | `bash tests/dependencies.test.sh` | pass line, exit 0 |
| Firewall tests | `bash tests/firewall.test.sh` | pass line, exit 0 (if plan 005 landed) |

**Never run the installer or the firewall script for real.**

## Scope

**In scope**:
- `.githooks/post-merge`
- `scripts/dependencies.sh` — the confirmation gate and a new `--yes` flag
- `scripts/setup_firewall.sh` — the same gate treatment
- `README.md` — describe the new hook behaviour
- `tests/dependencies.test.sh` — extend

**Out of scope** (do NOT touch):
- The lookup/quoting logic in `install_missing` — plan 002.
- The firewall rule contents or scoping — plans 005 and 006.
- The panel's install button. Installing from an explicit click is exactly the
  consent this plan preserves; do not weaken it.

## Git workflow

- Branch: `advisor/013-deescalate-privileged-automation`
- Conventional commits; `fix:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Reduce the hook to a notification

Replace everything from the `notify-send` block to `exit 0` in
`.githooks/post-merge` with a notification only:

```bash
# Notify, do not act. This hook runs from `omarchy plugin update`'s fast-forward
# merge, so anything it launches runs on a pull the user did not opt into
# individually -- and the installer it used to launch runs `sudo pacman` and
# builds a third-party CLI. A pull is consent to update a plugin, not consent to
# a root package operation. The panel's install button and running the script by
# hand are both explicit; this is not.
plural="dependencies"
[[ $count == 1 ]] && plural="dependency"

if command -v notify-send >/dev/null 2>&1; then
  notify-send --app-name="Nearby Share" \
    "Nearby Share: $count missing $plural" \
    "${summary% } -- open Nearby Share and choose Install dependencies, or run scripts/dependencies.sh --install"
fi

# Also say it on stdout, which is visible when the pull was run in a terminal.
echo "Nearby Share: $count missing $plural: ${summary% }" >&2
echo "Install them with: $checker --install" >&2

exit 0
```

**Verify**: `bash -n .githooks/post-merge` → exit 0;
`grep -c -- '--install' .githooks/post-merge` → `1` (only in the advisory text,
never as an invocation);
`grep -c 'setsid' .githooks/post-merge` → `0`;
`grep -c 'xdg-terminal-exec' .githooks/post-merge` → `0`.

### Step 2: Close the fail-open gate in the dependency installer

Replace the `[[ -t 0 ]]` block in `install_missing` with a fail-*closed* gate
plus an explicit opt-in flag:

```bash
  if (( assume_yes )); then
    echo "Proceeding without confirmation (--yes)."
  elif [[ -t 0 ]]; then
    printf 'Press Enter to proceed with installation, or Ctrl+C to cancel: '
    read -r _
  else
    # The prompt is the consent step, so a missing terminal must refuse rather
    # than skip it. Without a TTY sudo cannot read a password either, so
    # proceeding would fail anyway -- just later and less clearly.
    echo "dependencies.sh: refusing to install without a terminal." >&2
    echo "Run this from a shell, or pass --yes to install non-interactively." >&2
    return 2
  fi
```

Declare `assume_yes` near the top of the script (`assume_yes=0`) and parse the
flag in the existing `case` dispatcher so `--install --yes` and `--yes --install`
both work. Keep the existing unknown-option branch exiting 2.

**Verify**: `bash -n scripts/dependencies.sh` → exit 0;
`bash scripts/dependencies.sh --install </dev/null; echo "exit=$?"` → `exit=2`
and stderr says it is refusing. This is safe to run: it refuses before reaching
`sudo`.

### Step 3: Same treatment for the firewall script

Apply the identical pattern to both `apply_ufw` and `apply_firewalld` in
`scripts/setup_firewall.sh`: fail closed without a TTY, with a `--yes` opt-in
parsed alongside whatever flags the script already accepts.

If plan 006 has landed, it added a `--local` flag and an option `case` — extend
that `case` rather than adding a second parser.

**Verify**: `bash -n scripts/setup_firewall.sh` → exit 0;
`bash scripts/setup_firewall.sh </dev/null; echo "exit=$?"` → non-zero, with a
message about refusing. Safe to run: it refuses before reaching `sudo`.

### Step 4: Document the hook's new behaviour

`README.md` currently presents install-on-pull as a headline feature. It is now
notify-on-pull. Update that bullet to say the hook detects missing dependencies
after an update and tells you, and that installing is an explicit action — the
panel's button or the script by hand.

**Verify**: `grep -c 'Install dependencies' README.md` → at least `1`.

### Step 5: Tests

Extend `tests/dependencies.test.sh`:

1. `--install` with stdin from `/dev/null` and no `--yes` → exit 2, `sudo` never
   invoked. *This is the regression gate for the fail-open bug.*
2. `--install --yes` with stubs and something missing → `sudo` **is** invoked.
3. `--yes` alone (no `--install`) → does not install anything.
4. Unknown flag still exits 2.

Add a hook test — a new case in the same file is acceptable, or a small
`tests/post-merge.test.sh` if you prefer; say which you chose:

5. Run `.githooks/post-merge` in a sandbox repo with a stubbed `notify-send` and
   a stubbed terminal launcher on `PATH`, with a dependency missing. Assert the
   launcher was **never** invoked and `notify-send` **was**.

**Verify**: `bash tests/dependencies.test.sh` → pass line, exit 0.

## Test plan

- Five cases as above. Case 1 gates the fail-open regression; case 5 gates the
  hook de-escalation.
- Structural pattern: the stub-on-`PATH` harness in `tests/updater.test.sh` and
  the cases plan 001 added.
- Verification: `bash tests/dependencies.test.sh` and, if present,
  `bash tests/firewall.test.sh` → all pass.

## Done criteria

ALL must hold:

- [ ] `bash -n .githooks/post-merge scripts/dependencies.sh scripts/setup_firewall.sh` exits 0
- [ ] `grep -c 'setsid' .githooks/post-merge` returns `0`
- [ ] `grep -c 'xdg-terminal-exec' .githooks/post-merge` returns `0`
- [ ] `bash scripts/dependencies.sh --install </dev/null` exits 2 without invoking sudo
- [ ] `bash tests/dependencies.test.sh` exits 0 with the new cases
- [ ] `bash tests/firewall.test.sh` exits 0, if plan 005 has landed
- [ ] `README.md` no longer describes the hook as installing anything
- [ ] `git status --porcelain` lists only the in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `.githooks/post-merge` does not match the excerpt in "Current state".
- The maintainer wants to keep automatic installation on pull. That is their call
  to make, but it is the opposite of this plan — stop and confirm rather than
  half-implementing.
- `bash scripts/dependencies.sh --install </dev/null` reaches `sudo` at any point
  during your testing. Stop immediately; the gate is not closed.
- Plan 006 has landed and its option parser conflicts with the `--yes` flag in a
  way you cannot resolve without redesigning it. Report the conflict.

## Maintenance notes

- The rule this plan establishes: **automatic paths notify, explicit paths act.**
  A git hook, a timer, or any background trigger may detect and report, but may
  never invoke a privileged operation. Anything new that wants to install must be
  reachable from a user action.
- `--yes` exists for deliberate automation (a provisioning script, a container
  build). It is opt-in and greppable, which is the point — a fail-open `[[ -t 0 ]]`
  check is neither.
- A reviewer should confirm the hook cannot reach `dependencies.sh --install`
  through any branch, including the `[[ -t 1 ]]` foreground one that used to run
  it directly.
