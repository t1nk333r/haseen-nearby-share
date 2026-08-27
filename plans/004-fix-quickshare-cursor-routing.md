# Plan 004: Correct keyboard cursor routing in the Quick Share pane

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- Panel.qml tests/panel-state.test.js`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (but conflicts textually with plan 003 — see Scope)
- **Category**: bug
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

Three defects in the Quick Share pane's keyboard handling, all in the same two
functions. The first is the serious one:

**Pressing Enter right after opening the popup can launch a privileged
installer.** Opening the popup sets `selectedIndex = -1`, which is the receiver
toggle row. In `activateCursor`, the Quick Share branch tests `!qsAvailable`
*before* it tests any index, so on a machine without the Quick Share CLI, index
`-1` falls into that branch and spawns a terminal running
`dependencies.sh --install` — `sudo pacman` plus a multi-hundred-crate `cargo`
build. The user pressed Enter on a row drawn as a *receiver switch*. A window
demanding a sudo password then appears, which is both surprising and the exact
shape users are taught to distrust.

Second, when the CLI *is* installed, index `-1` matches no branch at all, so the
receiver toggle is a dead row — unreachable by keyboard from the Quick Share
pane.

Third, two cursor-range errors: the Quick Share "target" view clamps to index 2
but only has two rows, so Down-twice parks the cursor on a row that highlights
nothing and Enter there silently performs Back; and the "Firewall rules" button
declares no `hasCursor` and sits beyond `qsLastIndex`, so it can never be
focused or activated by keyboard at all.

## Current state

File: `Panel.qml`. Cursor indices are shared between the two panes and go
negative: `-2` is the two-button mode switcher, `-1` is the LocalSend receiver
toggle, `0..n-1` are device rows.

`qsLastIndex` — the Quick Share pane's cursor ceiling:

```qml
  readonly property int qsLastIndex: qsViewState !== "nearby"
    ? 0
    : (qsAvailable ? qsDevices.length : 0)
```

The `moveCursor` Quick Share branch:

```qml
  function moveCursor(dx, dy) {
    cursorActive = true
    if (selectedIndex === -2 && dx !== 0) {
      setMode(dx > 0 ? "quickshare" : "localsend")
      return
    }
    if (quickShareMode) {
      if (qsViewState === "target") {
        if (dy !== 0) selectedIndex = Math.max(-2, Math.min(2, selectedIndex + dy))
        return
      }
      if (qsViewState === "sending" || qsViewState === "success" || qsViewState === "error") {
        if (dy !== 0) selectedIndex = Math.max(-2, Math.min(0, selectedIndex + dy))
        return
      }
      if (dy !== 0) selectedIndex = Math.max(-2, Math.min(qsLastIndex, selectedIndex + dy))
      return
```

The `activateCursor` Quick Share branch:

```qml
  function activateCursor() {
    if (selectedIndex === -2) { setMode(quickShareMode ? "localsend" : "quickshare"); return }
    if (quickShareMode) {
      if (qsViewState === "target") {
        if (selectedIndex === 0) qsSelectFiles()
        else qsBack()
        return
      }
      if (qsViewState === "sending") { qsCancel(); return }
      if (qsViewState === "success" || qsViewState === "error") { qsFinish(); return }
      if (!qsAvailable) { installDependencies(); return }
      if (selectedIndex >= 0 && selectedIndex < qsDevices.length) qsChooseDevice(selectedIndex)
      else if (selectedIndex === qsDevices.length) qsScan()
      return
    }
```

The receiver toggle's cursor test — `< 0` lights it for `-2` as well, so the
mode switcher and the toggle highlight simultaneously:

```qml
          ToggleSwitch {
            checked: root.receiverEnabled
            hasCursor: root.cursorActive && root.selectedIndex < 0
```

The Quick Share target view has exactly two rows: a "Send files" `Button` with
`hasCursor:...selectedIndex===0`, and a "Back" `Button` with
`hasCursor:...selectedIndex===1`. There is no row 2.

The firewall button, which has no cursor wiring at all:

```qml
          Button {
            width:parent.width; bordered:false; iconText:"󰌵"; text:"Firewall rules"
            tooltipText:"Open the ports both protocols need"
            foreground:root.dim; fontFamily:root.fontFamily
            onClicked:root.configureFirewall()
          }
```

**Repo conventions:** `tests/panel-state.test.js` extracts these functions from
the QML source and runs them in a `vm` sandbox with a stubbed context, so cursor
logic **is** genuinely unit-testable — unlike property bindings. The harness
builds a context via a `panel({...})` helper; existing cases look like:

```js
{
  const state = panel({viewState: "nearby", devices: [{alias: "A"}, {alias: "B"}], selectedIndex: 0})
  state.moveCursor(0, 1)
  assert.equal(state.selectedIndex, 1)
}
```

The harness already stubs Quick Share view state (`quickShareMode`,
`qsViewState`, `qsAvailable`, `qsDevices`, `qsSelected`) and records engine
calls, and `qsLastIndex` is evaluated from the real binding rather than
re-implemented. Read the `panel()` function before writing tests.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Panel tests | `node tests/panel-state.test.js` | `panel state tests passed`, exit 0 |
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |

## Scope

**In scope**:
- `Panel.qml` — `qsLastIndex`, the Quick Share branches of `moveCursor` and
  `activateCursor`, the `ToggleSwitch` `hasCursor` test, and the firewall
  `Button`'s cursor wiring
- `tests/panel-state.test.js` — new cursor cases

**Out of scope** (do NOT touch):
- The two `visible:` bindings that plan 003 corrects. If plan 003 has not landed
  yet, leave them exactly as they are; if it has, do not revisit them.
- The LocalSend branches of `moveCursor` / `activateCursor` below the
  `quickShareMode` block.
- `QuickShare.qml`, `Service.qml`, `Model.js`.
- `scripts/setup_firewall.sh` — this plan makes the firewall *button* reachable;
  what it runs is plans 005 and 006.

## Git workflow

- Branch: `advisor/004-fix-quickshare-cursor-routing`
- Conventional commits; `fix:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Handle the receiver toggle before the availability check

In `activateCursor`'s `quickShareMode` block, insert an explicit `-1` case
immediately after the three view-state branches and **before** the
`!qsAvailable` test, then narrow the availability test to index `0`:

```qml
      if (qsViewState === "sending") { qsCancel(); return }
      if (qsViewState === "success" || qsViewState === "error") { qsFinish(); return }
      // The receiver toggle is drawn above both panes, so it stays actionable
      // from this one. Checked before availability: the setup block's install
      // button is row 0, and an unavailable CLI must not make every row above
      // it launch a privileged installer.
      if (selectedIndex === -1) { toggleReceiver(); return }
      if (!qsAvailable) { if (selectedIndex === 0) installDependencies(); return }
```

**Verify**: `node tests/panel-state.test.js` → exit 0 (no new assertions yet;
this confirms nothing existing broke).

### Step 2: Give the firewall row a cursor position

The firewall button is always visible in the Quick Share `nearby` view, whether
or not the CLI is available. Extend the ceiling to include it and wire the
button.

Change `qsLastIndex` to reserve one row past the existing last:

```qml
  readonly property int qsLastIndex: qsViewState !== "nearby"
    ? 0
    : (qsAvailable ? qsDevices.length + 1 : 1)
```

So in the available case the rows are: devices `0..n-1`, "Search for devices" at
`n`, "Firewall rules" at `n+1`. In the unavailable case: "Install dependencies"
at `0`, "Firewall rules" at `1`.

Add the matching branches in `activateCursor`, replacing the two lines that
currently end the Quick Share block:

```qml
      if (!qsAvailable) {
        if (selectedIndex === 0) installDependencies()
        else if (selectedIndex === 1) configureFirewall()
        return
      }
      if (selectedIndex >= 0 && selectedIndex < qsDevices.length) qsChooseDevice(selectedIndex)
      else if (selectedIndex === qsDevices.length) qsScan()
      else if (selectedIndex === qsDevices.length + 1) configureFirewall()
      return
```

Note this supersedes the one-line `!qsAvailable` form from Step 1 — end with the
block form above.

Wire the button itself:

```qml
          Button {
            width:parent.width; bordered:false; iconText:"󰌵"; text:"Firewall rules"
            tooltipText:"Open the ports both protocols need"
            foreground:root.dim; fontFamily:root.fontFamily
            hasCursor:root.cursorActive && root.selectedIndex === (root.qsAvailable ? root.qsDevices.length + 1 : 1)
            onHovered:function(v){root.noteHover(v, root.qsAvailable ? root.qsDevices.length + 1 : 1)}
            onClicked:root.configureFirewall()
          }
```

**Verify**: `node tests/panel-state.test.js` → exit 0.

### Step 3: Fix the phantom row in the target view

The Quick Share target view has two rows, not three. In `moveCursor`, change the
clamp:

```qml
      if (qsViewState === "target") {
        if (dy !== 0) selectedIndex = Math.max(-2, Math.min(1, selectedIndex + dy))
        return
      }
```

**Verify**: `node tests/panel-state.test.js` → exit 0.

### Step 4: Stop the receiver toggle lighting up on the mode switcher

Change the `ToggleSwitch` test from `< 0` to an exact match:

```qml
            hasCursor: root.cursorActive && root.selectedIndex === -1
```

**Verify**: `grep -c 'hasCursor: root.cursorActive && root.selectedIndex === -1' Panel.qml` → `1`,
and `grep -c 'selectedIndex < 0' Panel.qml` → `0`.

### Step 5: Add cursor tests

In `tests/panel-state.test.js`, add cases using the existing `panel({...})`
helper. Each `panel()` call needs `quickShareMode: true` plus the relevant
`qsViewState` / `qsAvailable` / `qsDevices`.

1. **The regression gate.** `panel({quickShareMode: true, qsViewState: "nearby",
   qsAvailable: false, selectedIndex: -1})` → `activateCursor()` must call
   `toggleReceiver` on the engine and must **not** set `depsInstaller.running`.
   Assert against the engine's recorded `calls`. *This fails before Step 1.*
2. Same context but `selectedIndex: 0` → `activateCursor()` **does** start the
   installer.
3. `qsAvailable: true, qsDevices: [{alias:"A",id:"1"},{alias:"B",id:"2"}],
   selectedIndex: -1` → `activateCursor()` calls `toggleReceiver`.
4. Firewall reachability: with two devices, `selectedIndex: 3` →
   `activateCursor()` starts `firewallSetup`; and `moveCursor(0, 99)` from `0`
   lands on `3`, not `2`.
5. Target view has no phantom row: `panel({quickShareMode: true, qsViewState:
   "target", selectedIndex: 0})` → `moveCursor(0, 5)` leaves `selectedIndex`
   at `1`.
6. Mode switcher does not also light the toggle — assert `qsLastIndex` and the
   index arithmetic rather than the binding, since `hasCursor` is a property
   binding the harness cannot evaluate. Cover it instead with a source-text
   assertion: `assert.doesNotMatch(source, /selectedIndex < 0/, "...")`.

**Verify**: `node tests/panel-state.test.js` → `panel state tests passed`, exit 0.

### Step 6: Confirm nothing else regressed

**Verify**: `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js`
→ exit 0.

## Test plan

- Extend `tests/panel-state.test.js` with the six cases above, using the
  existing `panel({...})` sandbox helper as the structural pattern.
- Case 1 is the regression gate for the privileged-installer bug and must fail
  before Step 1. Verify that explicitly (stash the `Panel.qml` change, run, see
  it fail, restore) and report both outcomes.
- Verification: `node tests/panel-state.test.js` → all pass.

## Done criteria

ALL must hold:

- [ ] `node tests/panel-state.test.js` exits 0 with the six new cases present
- [ ] `node tests/model.test.js && node tests/service-state.test.js` exits 0
- [ ] `grep -c 'selectedIndex < 0' Panel.qml` returns `0`
- [ ] `grep -c 'qsDevices.length + 1' Panel.qml` returns at least `3` (ceiling, activate branch, button wiring)
- [ ] `grep -c 'Math.min(2, selectedIndex + dy)' Panel.qml` returns `0`
- [ ] Case 1 fails when the Step 1 change is reverted (verified, then restored)
- [ ] `git status --porcelain` lists only `Panel.qml` and `tests/panel-state.test.js`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `moveCursor`, `activateCursor`, `qsLastIndex`, or the `ToggleSwitch` block do
  not match the excerpts in "Current state".
- `tests/panel-state.test.js` has no `panel({...})` helper, or that helper does
  not already stub `quickShareMode` / `qsViewState` / `qsAvailable` / `qsDevices`.
  Extending the harness's context shape is acceptable; rewriting the harness is
  not — report instead.
- You find the firewall button is *not* always visible in the `nearby` view (for
  example if plan 006 has since gated it). The index arithmetic in Step 2
  assumes it is unconditional; if that changed, stop and report.
- Case 1 passes before the Step 1 change is applied.

## Maintenance notes

- Quick Share cursor indices are now: `-2` mode switcher, `-1` receiver toggle,
  `0..n-1` devices, `n` rescan, `n+1` firewall (available); or `-2`, `-1`, `0`
  install, `1` firewall (unavailable). Any new row must update `qsLastIndex`,
  `activateCursor`, **and** the row's own `hasCursor`/`onHovered` together —
  these three drifting apart is what produced the phantom row.
- A reviewer should check that `activateCursor` tests indices before it tests
  availability. The ordering is the whole bug.
- Deliberately deferred: the LocalSend pane's own cursor ceiling and the
  question of whether an inbound LocalSend request should force a pane switch.
