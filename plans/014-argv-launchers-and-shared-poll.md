# Plan 014: Replace the shell-string launchers and move the dependency poll off the view

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- Panel.qml QuickShare.qml tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

Two problems in `Panel.qml`'s helper-launching code.

**The two terminal launchers build a shell command as a string.** Every other
`Process` in this repo uses an argv array, which involves no shell at all. These
two interpolate a filesystem path into single quotes, inside a double-quoted
argument, inside a `bash -c` string — two levels of quoting. A plugin path
containing a single quote breaks out and the remainder is interpreted by `bash`.
The path comes from `manifest.__sourceDir` or `$HOME`, neither of which is
validated. No exploit is reachable on a normal install, but this is the standard
string-built-shell-command pattern in a file that otherwise consistently avoids
it.

Neither launcher handles failure. `depsInstaller` ignores its exit code;
`firewallSetup` has no `onExited` at all; neither has the `launched` flag that
catches a command which never starts. So if no terminal launcher is installed, or
the inner script is missing, the user clicks "Install dependencies" or "Firewall
rules" and gets **nothing** — no error, no state change — while a 15-minute
polling timer spins in the background.

**That polling timer is in the wrong file.** The bar instantiates `Panel.qml`
once per monitor, so on a two-monitor setup an install starts *two* independent
4-second timers, both spawning `bash scripts/dependencies.sh --json` against the
one shared engine, for up to 15 minutes. Its comment claims it "polls only while
the popup is open"; it never reads `opened`. A machine-wide install probe is
precisely the kind of singular concern that `AGENTS.md` says belongs in the
service.

## Current state

`Panel.qml` — the two launchers:

```qml
    id: depsInstaller
    command: ["bash","-c","if command -v omarchy-launch-floating-terminal-with-presentation >/dev/null 2>&1; then omarchy-launch-floating-terminal-with-presentation \"bash '" + root.qsScriptDir + "/dependencies.sh' --install\"; else xdg-terminal-exec bash '" + root.qsScriptDir + "/dependencies.sh' --install; fi"]
    running: false
    // The installer runs detached in its own terminal, so this exit says the
    // launcher returned, not that anything was installed. Re-probing is what
    // turns the pane back on, and it is cheap.
    onExited: function(code) { depsRecheck.restart() }
```

`firewallSetup` has the same two-level-quoting shape and no `onExited`.

The per-monitor timer, whose comment does not match its behaviour:

```qml
    id: depsRecheck
    interval: 4000; repeat: true
    running: false
    property int ticks: 0
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      ticks++
      if (root.qs) root.qs.refreshDependencies()
      if (root.qsAvailable || ticks > 225) stop()
    }
```

`Panel.qml`'s own header states the rule being broken:

```
  // The bar builds one of these per monitor, so this file owns no helper, no
  // transfer state, and no IPC target. All of that lives in the `service`
  // entry point, which the shell loads exactly once; everything below is a
  // view onto it plus this popup's own cursor.
```

The in-repo exemplar for a correct launcher **is not** in this repo — it is the
pattern used by `omaconnect`, and it has the same two-level quoting. Do not copy
it. The correct shape is a plain argv array, as every other `Process` in
`QuickShare.qml` and `Panel.qml` already uses:

```qml
    command: ["omarchy-file-select","--title","Send nearby","--multiple"]
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |
| Quick Share suite | `node tests/quickshare-state.test.js` | pass line, exit 0 (if plan 010 landed) |
| Launcher present? | `command -v omarchy-launch-floating-terminal-with-presentation` | prints a path on this machine |

## Scope

**In scope**:
- `Panel.qml` — the two launcher `Process` blocks, and removing the timer
- `QuickShare.qml` — receive the timer as engine state
- `tests/panel-state.test.js` and/or `tests/quickshare-state.test.js`

**Out of scope** (do NOT touch):
- `scripts/dependencies.sh` and `scripts/setup_firewall.sh` themselves.
- The cursor routing that decides *when* `installDependencies()` and
  `configureFirewall()` are called — plan 004.
- Whether the hook may launch the installer — plan 013.

## Git workflow

- Branch: `advisor/014-argv-launchers-and-shared-poll`
- Conventional commits; `fix:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Detect the launcher once, as a plain property

Add to `Panel.qml`, near the other derived properties:

```qml
  // Resolved once rather than re-tested inside a shell string. The Omarchy
  // launcher wraps the command in its own presentation; xdg-terminal-exec is
  // the fallback on a non-Omarchy shell.
  property string terminalLauncher: ""
```

and a small probe `Process` that sets it:

```qml
  Process {
    id: launcherProbe
    command: ["sh","-c","command -v omarchy-launch-floating-terminal-with-presentation || command -v xdg-terminal-exec"]
    running: true
    stdout: StdioCollector { id: launcherOutput; waitForEnd: true }
    onExited: function(code) {
      root.terminalLauncher = code === 0 ? String(launcherOutput.text || "").trim().split("\n")[0] : ""
    }
  }
```

This is the one place a shell is still involved, and it interpolates nothing —
the command string is a constant.

**Verify**: `grep -c 'launcherProbe' Panel.qml` → `1`;
`node tests/panel-state.test.js` → exit 0.

### Step 2: Rebuild both launchers as argv arrays

```qml
  Process {
    id: depsInstaller
    property bool launched: false
    // argv, not a shell string: the plugin path is interpolated here and a
    // single quote in it would otherwise break out of two levels of quoting.
    command: root.terminalLauncher.indexOf("omarchy-launch") >= 0
      ? [root.terminalLauncher, "bash " + root.qsScriptDir + "/dependencies.sh --install"]
      : [root.terminalLauncher, "bash", root.qsScriptDir + "/dependencies.sh", "--install"]
    running: false
    onStarted: depsInstaller.launched = true
    onRunningChanged: {
      if (running || depsInstaller.launched) return
      root.copyNote = "No terminal is available to run the installer."
    }
    onExited: function(code) {
      if (code !== 0) { root.copyNote = "The installer could not be started."; return }
      if (root.qs) root.qs.notifyInstallStarted()
    }
  }
```

Note the Omarchy launcher takes the command **as one argument** (it does
`cmd="$*"` internally), while `xdg-terminal-exec` takes argv — hence the branch.
That single remaining string is passed to a launcher that re-parses it, so it
still cannot contain a quote safely; guard it in Step 4.

Do the same for `firewallSetup`, pointing at `setup_firewall.sh`, with its own
`launched` flag, `onRunningChanged`, and an `onExited` that reports a non-zero
code into `copyNote`.

**Verify**: `grep -c 'bash","-c"' Panel.qml` → `0`;
`grep -c 'depsInstaller.launched' Panel.qml` → `2`;
`grep -c 'firewallSetup.launched' Panel.qml` → `2`.

### Step 3: Move the poll into the engine

Delete the `depsRecheck` `Timer` from `Panel.qml`. Add the equivalent to
`QuickShare.qml`, where there is exactly one instance per session:

```qml
  // One poll per session, not one per monitor. The bar builds a Panel per
  // screen, so a timer living there started a duplicate probe on every monitor
  // and kept running after the popup closed.
  property int installPollTicks: 0

  function notifyInstallStarted() { installPollTicks = 0; installPoll.restart() }

  Timer {
    id: installPoll
    interval: 4000
    repeat: true
    running: false
    onTriggered: {
      root.installPollTicks++
      root.refreshDependencies()
      if (root.available || root.installPollTicks > 225) stop()
    }
  }
```

**Verify**: `grep -c 'depsRecheck' Panel.qml` → `0`;
`grep -c 'installPoll' QuickShare.qml` → at least `3`.

### Step 4: Refuse a path that cannot be passed safely

`qsScriptDir` derives from unvalidated input, and the Omarchy launcher branch
still passes a single string. Rather than attempt to quote it, refuse:

In `Panel.qml`, guard both actions:

```qml
  // The Omarchy launcher re-parses its argument with a shell, so a path
  // containing a quote or whitespace cannot be passed to it safely. Refusing is
  // better than emitting a command line that means something else.
  readonly property bool scriptDirSafe: /^[A-Za-z0-9_.\/-]+$/.test(root.qsScriptDir)

  function installDependencies() {
    if (!scriptDirSafe) { copyNote = "The plugin path contains characters that cannot be passed to a terminal safely."; return }
    if (!depsInstaller.running) { depsInstaller.launched = false; depsInstaller.running = true }
  }
  function configureFirewall() {
    if (!scriptDirSafe) { copyNote = "The plugin path contains characters that cannot be passed to a terminal safely."; return }
    if (!firewallSetup.running) { firewallSetup.launched = false; firewallSetup.running = true }
  }
```

**Verify**: `grep -c 'scriptDirSafe' Panel.qml` → `3`;
`node tests/panel-state.test.js` → exit 0.

### Step 5: Tests

`tests/panel-state.test.js` — `installDependencies` and `configureFirewall` are
extractable functions, so these run for real:

1. `panel({qsScriptDir: "/home/u/.config/omarchy/plugins/x/scripts"})` →
   `installDependencies()` sets `depsInstaller.running` true.
2. `panel({qsScriptDir: "/home/o'brien/plugins/x/scripts"})` →
   `installDependencies()` leaves `depsInstaller.running` false and sets
   `copyNote`. *This is the regression gate.*
3. Same two cases for `configureFirewall`.
4. Source assertions: no `"bash","-c"` remains in `Panel.qml`; no `depsRecheck`
   remains.

`tests/quickshare-state.test.js`, if plan 010 landed:

5. `notifyInstallStarted()` resets `installPollTicks` to 0.

**Verify**: `node tests/panel-state.test.js` → exit 0.

## Test plan

- Five cases as above; case 2 is the regression gate for the quoting break-out.
- Structural pattern: the existing `panel({...})` sandbox cases.
- The `Process` and `Timer` declarations are verified by source assertion and
  review, not execution — say so.
- Verification: all Node suites green.

## Done criteria

ALL must hold:

- [ ] `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` exits 0
- [ ] `grep -c 'bash","-c"' Panel.qml` returns `0`
- [ ] `grep -c 'depsRecheck' Panel.qml` returns `0`
- [ ] `grep -c 'installPoll' QuickShare.qml` returns at least `3`
- [ ] `grep -c 'scriptDirSafe' Panel.qml` returns `3`
- [ ] Both launchers have a `launched` flag and an `onRunningChanged` guard
- [ ] `git status --porcelain` lists only `Panel.qml`, `QuickShare.qml`, and test files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The launcher blocks or the timer do not match the excerpts in "Current state".
- `omarchy-launch-floating-terminal-with-presentation` turns out to accept argv
  rather than a single string. Read
  `/usr/share/omarchy/bin/omarchy-launch-floating-terminal-with-presentation` and
  confirm; if it takes argv, drop the branch in Step 2 and use argv for both —
  and then Step 4's guard can be relaxed. Report which you found.
- Removing `depsRecheck` from `Panel.qml` breaks an existing assertion in
  `tests/panel-state.test.js`. Report the assertion; it may be a genuine
  regression lock rather than incidental.
- Plan 011 has landed and already added a poll or a `notifyInstallStarted` to
  `QuickShare.qml`. Reconcile rather than adding a second.

## Maintenance notes

- The rule: `Process.command` is an argv array. The only exception in this file
  is `launcherProbe`, whose command string is a constant with nothing
  interpolated. Any new launcher must follow that.
- Timers that drive shared engine state belong in `QuickShare.qml` or
  `Service.qml`, never in `Panel.qml` — the bar builds one Panel per monitor.
  The deleted timer's own comment claimed a gating behaviour it did not have,
  which is worth watching for in review generally.
- Deliberately deferred: `Panel.qml` splits the file chooser's output on `\n`, so
  a filename containing a newline becomes two nonexistent paths. Same pattern
  exists on the LocalSend side; it is a separate finding.
