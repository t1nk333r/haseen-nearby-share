# Plan 011: Harden the Quick Share engine's process lifecycle

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- QuickShare.qml tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: `plans/010-test-quickshare-cli-contract.md`
- **Category**: bug
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

Four defects in how `QuickShare.qml` supervises its subprocesses. They share a
root cause: the engine handles the happy path and the clean-exit path, but not
the *never-started* and *never-finishes* paths.

1. **`depsProbe` has no failed-launch guard.** It is the only `Process` in the
   fork lacking one. Quickshell reports a command it could not launch by
   returning `running` to `false` **without ever emitting `started` or `exited`**
   — so a missing `bash`, or a `pluginDir` that does not resolve, leaves
   `depsChecked` false forever. The pane then renders nothing at all: no devices,
   no setup block, no error.
2. **`depsProbe` ignores its exit code.** A non-zero exit (127 for a bad path,
   say) feeds empty stdout into the parser, which leaves `missingDeps` stale and
   reports "the CLI is not installed" — offering an installer that will fail the
   same way, with no "Missing:" list.
3. **A hung `qs send` never times out**, and then blocks every later send. The
   scan path passes `--timeout`; the send path has no equivalent bound and no
   watchdog. `sendFiles` early-returns while `sender.running`, silently, so once
   a send wedges the pane is dead until the plugin reloads.
4. **A launch failure in `sender` and in `scanner` leave contradictory state.**
   `scanner` clears `available` but leaves `missingDeps` stale; `sender` calls
   `failWith` and leaves `available` untouched. The two disagree about whether
   the binary exists, and the pane can show "a helper is needed" while listing
   nothing as missing.

## Current state

File: `QuickShare.qml`.

`depsProbe` — note the absent `launched` flag, absent `onStarted`, absent
`onRunningChanged`, and the discarded `code`:

```qml
    id: depsProbe
    command: ["bash", root.pluginDir + "/scripts/dependencies.sh", "--json"]
    running: false
    stdout: StdioCollector { id: depsOutput; waitForEnd: true }
    onExited: function(code) { root.noteDependencies(String(depsOutput.text || "")) }
```

`sender` — has the guard, but its failure path does not touch `available`:

```qml
    onRunningChanged: {
      if (running || sender.launched) return
      root.pendingPaths = []
      root.failWith("The Quick Share CLI is not installed.")
    }
    onExited: function(code) { root.finishSend(code) }
```

`noteDependencies` — leaves `missingDeps` untouched when parsing fails:

```qml
  function noteDependencies(payload) {
    var parsed = null
    try { parsed = JSON.parse(payload) } catch (e) { parsed = null }
    if (!parsed || !parsed.deps) { depsChecked = true; return }
    ...
```

`sendFiles` — the silent early return, and no timer:

```qml
  function sendFiles(paths) {
    if (!available || !selectedDevice || sender.running) return
    if (!paths || !paths.length) return
    ...
    viewState = "sending"
    sender.launched = false
    sender.running = true
  }
```

The scan path, for contrast, **is** bounded:

```qml
    command: [root.binary, "--port", String(root.port), "devices", "--json", "--timeout", String(root.scanTimeout)]
```

**The convention this plan restores** is stated in `AGENTS.md`:

> Treat Quickshell `Process` startup, exit, stdin, and repeated-use behavior as
> separate lifecycle cases. Missing commands may fail without an exit code.

`scanner` in this same file is the in-repo exemplar of the correct shape —
`launched` flag, `onStarted` setting it, `onRunningChanged` catching the
never-launched case.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Quick Share tests | `node tests/quickshare-state.test.js` | pass line, exit 0 |
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |

`Process` blocks and `Timer` blocks are QML declarations that the Node harness
cannot execute. Their changes are verified by source-text assertion plus review;
the *functions* they call are verified for real. Say which is which in your
report — do not imply the QML was executed.

## Scope

**In scope**:
- `QuickShare.qml`
- `tests/quickshare-state.test.js` — extend

**Out of scope** (do NOT touch):
- `finishSend`'s exit-code mapping. Plan 013 owns the `130`-vs-signal question;
  changing it here would collide.
- `noteSendLine`'s regexes — a separate hardening concern.
- `Panel.qml`, `Service.qml`, `Model.js`, all shell scripts.

## Git workflow

- Branch: `advisor/011-harden-quickshare-lifecycle`
- Conventional commits; `fix:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Give `depsProbe` the standard lifecycle shape

Model it on `scanner` in the same file:

```qml
  Process {
    id: depsProbe
    property bool launched: false
    command: ["bash", root.pluginDir + "/scripts/dependencies.sh", "--json"]
    running: false
    stdout: StdioCollector { id: depsOutput; waitForEnd: true }
    onStarted: depsProbe.launched = true
    // A command that never launches returns running to false without ever
    // emitting started or exited, so the pane would otherwise wait on a probe
    // that is never coming and render nothing at all.
    onRunningChanged: {
      if (running || depsProbe.launched) return
      root.noteProbeFailure("The dependency check could not be started.")
    }
    onExited: function(code) {
      if (code !== 0) { root.noteProbeFailure("The dependency check failed (exit " + code + ")."); return }
      root.noteDependencies(String(depsOutput.text || ""))
    }
  }
```

**Verify**: `grep -c 'depsProbe.launched' QuickShare.qml` → `2`.

### Step 2: Add `noteProbeFailure` and make parse failure explicit

Add beside `noteDependencies`:

```qml
  // A probe that could not run is a different state from a CLI that is absent,
  // and the pane must not offer an installer for the second when it is the
  // first. Both leave Quick Share unusable; only one is fixed by installing.
  function noteProbeFailure(message) {
    depsChecked = true
    available = false
    missingDeps = []
    probeError = String(message || "")
    if (viewState === "nearby") statusText = probeError
  }
```

Declare the backing property beside the other dependency state:

```qml
  property string probeError: ""
```

Then make `noteDependencies` clear it on success and treat unparseable output as
a probe failure rather than silently accepting it:

```qml
    if (!parsed || !parsed.deps) { noteProbeFailure("The dependency check returned unreadable output."); return }
```

and, on the success path, `probeError = ""` before setting `depsChecked = true`.

**Verify**: `node tests/quickshare-state.test.js` → the Step 5 case from plan
010 (non-JSON leaves `missingDeps` unchanged) now **fails**. That is expected —
update that assertion to the new behaviour and remove its "characterised, not
endorsed" comment, since this plan is the fix it named.

### Step 3: Surface `probeError` in the panel

`Panel.qml` renders the SETUP block from `qsChecked` and `qsMissingDeps`. Add a
mirror property and a line so a probe failure is visible rather than presenting
as "not installed".

Add to `Panel.qml`'s Quick Share mirrors:

```qml
  readonly property string qsProbeError: qs ? qs.probeError : ""
```

and, inside the SETUP `Column`, above the "Missing:" text:

```qml
            Text {
              visible: root.qsProbeError !== ""
              width:parent.width; textFormat:Text.PlainText; wrapMode:Text.Wrap
              text: root.qsProbeError
              color:root.urgent; font.family:root.fontFamily; font.pixelSize:Style.font.body
            }
```

This is the one edit this plan makes outside `QuickShare.qml`; it is required,
because a state with no renderer is invisible.

**Verify**: `grep -c 'qsProbeError' Panel.qml` → `2`.

### Step 4: Add a send watchdog

Add a `Timer` beside the `sender` `Process`:

```qml
  // `qs send` has no --timeout of its own, unlike the scan path. Without a
  // bound, a peer that never answers leaves the pane at "Connecting..." and --
  // because sendFiles early-returns while sender.running -- silently blocks
  // every later send until the plugin reloads.
  Timer {
    id: sendWatchdog
    interval: 180000
    repeat: false
    running: false
    onTriggered: {
      if (!sender.running) return
      root.sendTimedOut = true
      sender.signal(15)
    }
  }
```

Declare `property bool sendTimedOut: false` with the other state.

Arm it in `sendFiles` (`sendWatchdog.restart()` immediately before
`sender.running = true`), and disarm it at the top of `finishSend`
(`sendWatchdog.stop()`).

In `finishSend`, before the existing code-based branches, handle the timeout so
it is not misreported as a decline:

```qml
    if (sendTimedOut) {
      sendTimedOut = false
      viewState = "error"
      errorText = "Quick Share stopped responding while sending to " + transferPeer + "."
      statusText = errorText
      return
    }
```

Place this after `pendingPaths = []` and `transferPin = ""` so cleanup still runs.

**Verify**: `grep -c 'sendWatchdog' QuickShare.qml` → at least `4`;
`node tests/quickshare-state.test.js` → exit 0 after you add the case in Step 6.

### Step 5: Make the two launch-failure paths agree, and give the early return a reason

In `sender.onRunningChanged`, set the same state the scanner does:

```qml
    onRunningChanged: {
      if (running || sender.launched) return
      root.pendingPaths = []
      root.available = false
      root.noteProbeFailure("The Quick Share CLI could not be started.")
      root.failWith("The Quick Share CLI could not be started.")
    }
```

In `scanner.onRunningChanged`, replace the ad-hoc assignment with the same
helper so the two cannot drift:

```qml
    onRunningChanged: {
      if (running || scanner.launched) return
      root.scanning = false
      root.noteProbeFailure("The Quick Share CLI could not be started.")
    }
```

And give `sendFiles`'s silent early return a visible reason:

```qml
  function sendFiles(paths) {
    if (!available) { failWith("Quick Share is not available."); return }
    if (!selectedDevice) { failWith("No device is selected."); return }
    if (sender.running) { failWith("A Quick Share transfer is already in progress."); return }
    if (!paths || !paths.length) return
```

**Verify**: `grep -c 'noteProbeFailure' QuickShare.qml` → at least `4`.

### Step 6: Extend the tests

Add to `tests/quickshare-state.test.js`:

1. `noteProbeFailure("x")` → `available === false`, `depsChecked === true`,
   `missingDeps` empty, `probeError === "x"`.
2. `noteDependencies("not json")` → probe-failure state (this replaces the plan
   010 characterisation case).
3. `noteDependencies` with a valid all-present payload after a prior failure →
   `probeError === ""`.
4. `finishSend(0)` with `sendTimedOut = true` → error state, not success. This is
   the important one: a transfer that timed out must not be reported as sent
   just because the killed process happened to exit 0.
5. `sendFiles([])` with `available === false` → `viewState === "error"`.

**Verify**: `node tests/quickshare-state.test.js` → all pass.

## Test plan

- Extend `tests/quickshare-state.test.js` with the five cases in Step 6.
- Case 4 is the regression gate for the watchdog.
- The `Process`, `Timer` and `Panel.qml` changes are verified by source-text
  assertion and review, not execution — state that plainly.
- Verification: `node tests/quickshare-state.test.js` → all pass; the three
  existing suites unchanged and green.

## Done criteria

ALL must hold:

- [ ] `node tests/quickshare-state.test.js` exits 0 with the five new cases
- [ ] `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` exits 0
- [ ] `grep -c 'depsProbe.launched' QuickShare.qml` returns `2`
- [ ] `grep -c 'sendWatchdog' QuickShare.qml` returns at least `4`
- [ ] `grep -c 'noteProbeFailure' QuickShare.qml` returns at least `4`
- [ ] `grep -c 'qsProbeError' Panel.qml` returns `2`
- [ ] `git status --porcelain` lists only `QuickShare.qml`, `Panel.qml`, `tests/quickshare-state.test.js`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `Process` blocks do not match the excerpts in "Current state".
- Plan 010 has not landed, so `tests/quickshare-state.test.js` does not exist.
  This plan's verification depends on it; do not create a competing harness.
- Quickshell's `Process` turns out to have no `signal(int)` method in the
  installed version. Check `/usr/share/omarchy/shell` usage or Quickshell docs;
  if absent, report rather than substituting a different kill mechanism.
- Adding `probeError` to `Panel.qml` conflicts with plan 004's cursor-index
  changes to the SETUP block. Land 004 first, then rebase.

## Maintenance notes

- Every `Process` in this repo needs four things: a `launched` flag, `onStarted`
  setting it, `onRunningChanged` catching the never-launched case, and an
  `onExited` that reads its `code`. `scanner` is the exemplar. `AGENTS.md`
  states this requirement; `depsProbe` is what it looks like when it is missed.
- The 180-second watchdog is a guess at a generous upper bound for a LAN
  transfer. If users report large transfers being killed, raise it or make it
  proportional to total bytes — do not simply remove it.
- A reviewer should confirm `finishSend` checks `sendTimedOut` **before** the
  exit-code branches. A killed process's exit code is not meaningful.
