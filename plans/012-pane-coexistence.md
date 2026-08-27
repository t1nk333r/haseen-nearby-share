# Plan 012: Make the two panes coexist coherently

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- Panel.qml Service.qml QuickShare.qml tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED — touches pane gating and discovery lifecycle; a careless fix
  can make the incoming column appear over an active Quick Share transfer
- **Depends on**: `plans/003-fix-visibility-precedence.md`, `plans/004-fix-quickshare-cursor-routing.md`
- **Category**: bug
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

The two panes were added by gating each pane's columns on a mode flag. That
handles rendering, but three things cross the pane boundary and were not
reconciled:

1. **An inbound LocalSend request is unactionable in Quick Share mode.** The
   engine sets `viewState = "incoming"` and fires a desktop notification
   regardless of mode. The hero title and icon follow LocalSend state, so the
   popup reads "Incoming" with an urgent icon — but the accept/decline column is
   gated off, and keyboard activation never routes to it. The user is notified of
   a transfer they cannot accept or decline, and it sits until it expires.

2. **LocalSend discovery never restarts when switching back.** `setMode` only
   acts in the `quickshare` direction, and `viewOpened` returns early in Quick
   Share mode. So: open the popup with Quick Share persisted, switch to
   LocalSend — discovery was never started and is not started now.
   `discoveryActive` stays false, so the empty state reads "No devices nearby"
   rather than "Finding devices…", and nothing appears until the user finds
   Rescan.

3. **Quick Share state is invisible outside its own pane.** The bar icon's
   `active` state and tooltip read only LocalSend state, so a transfer in flight
   leaves the icon idle. `heroMetaText` branches solely on LocalSend, so the hero
   can say "Turned off" above a working Quick Share pane. No Quick Share terminal
   state emits a notification, so a send that completes after the popup closed is
   discovered only by chance. `qsStatusText` is declared in `Panel.qml` and
   referenced nowhere.

## Current state

`Service.qml` — `viewOpened` returns early, and `setMode` is one-directional:

```qml
  function viewOpened() {
    openViewCount++
    if (openViewCount !== 1) return
    if (quickShareMode) {
      quickShareEngine.refreshDependencies()
      if (quickShareEngine.available && quickShareEngine.viewState === "nearby") quickShareEngine.scan()
      return
    }
    if (viewState === "nearby" && receiverEnabled && backendReady) startDiscovery()
  }
  function setMode(next) {
    var wanted = next === "quickshare" ? "quickshare" : "localsend"
    if (wanted === mode) return
    persistMode(wanted)
    cursorRequested(0)
    if (wanted === "quickshare") {
      quickShareEngine.refreshDependencies()
      if (anyViewOpen && quickShareEngine.available) quickShareEngine.scan()
    }
  }
```

`Panel.qml` — the bar icon reads only LocalSend state (find it by its
`BarIconButton` block; `active:` and `tooltipText:` both reference
`root.incoming`, `root.viewState`, `root.receiverEnabled`, `root.backendReady`
and none of the `qs*` mirrors).

`Panel.qml` — `heroMetaText` branches only on LocalSend `viewState`, and
`qsStatusText` is declared among the Quick Share mirrors but used nowhere:
`grep -c qsStatusText Panel.qml` returns `1`.

`Service.qml` emits desktop notifications for LocalSend events; `QuickShare.qml`
has no notification path at all.

**Architectural constraint that governs this plan**, from `AGENTS.md`:

> `Panel.qml` and `Model.js` implement the Quickshell UI and its state model.
> The bar builds one `Panel.qml` per monitor, so it must stay a view: anything
> there can only be one of belongs in `Service.qml`.

So: notifications and discovery lifecycle go in `Service.qml` / `QuickShare.qml`,
never in `Panel.qml`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Service tests | `node tests/service-state.test.js` | pass line, exit 0 |
| Panel tests | `node tests/panel-state.test.js` | pass line, exit 0 |
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |

## Scope

**In scope**:
- `Service.qml` — `viewOpened`, `setMode`
- `QuickShare.qml` — a notification on terminal states
- `Panel.qml` — bar icon `active`/`tooltipText`, `heroMetaText`, and consuming
  `qsStatusText`
- `tests/service-state.test.js`, `tests/panel-state.test.js`

**Out of scope** (do NOT touch):
- The pane `visible:` gates — plan 003 owns them.
- `moveCursor` / `activateCursor` index arithmetic — plan 004 owns it. This plan
  adds **one** early branch to `activateCursor` (Step 3); do not restructure the
  rest.
- `finishSend`'s exit-code mapping — plan 013.
- The decision to auto-switch panes on an inbound request. See Step 3: this plan
  makes the request *actionable*, it does not hijack the user's pane.

## Git workflow

- Branch: `advisor/012-pane-coexistence`
- Conventional commits; `fix:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Restart LocalSend discovery when switching back to it

In `Service.qml`'s `setMode`, add the missing direction:

```qml
    if (wanted === "quickshare") {
      quickShareEngine.refreshDependencies()
      if (anyViewOpen && quickShareEngine.available) quickShareEngine.scan()
      return
    }
    // Switching back has to start discovery itself: viewOpened returned early
    // when the popup was opened in Quick Share mode, so LocalSend discovery has
    // never run in this session of the popup.
    if (anyViewOpen && viewState === "nearby" && receiverEnabled && backendReady) startDiscovery()
```

**Verify**: `node tests/service-state.test.js` → exit 0.

### Step 2: Stop active discovery when leaving LocalSend

Still in `setMode`, before the `quickshare` branch's scan, stop LocalSend's
active discovery so it is not scanning the subnet behind a pane nobody is
looking at:

```qml
    if (wanted === "quickshare") {
      stopDiscovery()
      quickShareEngine.refreshDependencies()
```

Note `stopDiscovery()` only ends *active* discovery; the receiver and passive
listening are unaffected, which is the documented lifecycle in `README.md`.

**Verify**: `node tests/service-state.test.js` → exit 0.

### Step 3: Make a pending inbound request actionable from either pane

An inbound LocalSend request is time-limited and the user was just notified about
it, so it must be reachable. Do **not** force a pane switch — that would yank the
view out from under someone mid-Quick-Share-transfer.

In `Panel.qml`, change the incoming column's gate so it renders in both panes:

```qml
          visible: root.viewState === "incoming" && root.incoming; width:parent.width; spacing:Style.space(8)
```

(That is, drop the `!root.quickShareMode &&` prefix from this **one** column.)

Then in `activateCursor`, add a single early branch **above** the
`quickShareMode` block so accept/decline wins over pane routing:

```qml
  function activateCursor() {
    // A pending request is time-limited and the user has already been notified,
    // so it stays actionable from whichever pane is showing rather than being
    // reachable only after they find the LocalSend button.
    if (viewState === "incoming" && incoming) {
      selectedIndex === 0 ? declineIncoming() : acceptIncoming()
      return
    }
    if (selectedIndex === -2) { setMode(quickShareMode ? "localsend" : "quickshare"); return }
```

And in `moveCursor`, add the matching clamp above the `quickShareMode` block:

```qml
    if (viewState === "incoming" && incoming) {
      if (dx !== 0) selectedIndex = Math.max(0, Math.min(1, selectedIndex + dx))
      return
    }
```

**Verify**: `node tests/panel-state.test.js` → exit 0 (new cases added in Step 6).

### Step 4: Make the bar icon and hero reflect whichever pane is active

In `Panel.qml`, extend the `BarIconButton`'s `active` binding so a Quick Share
transfer lights the icon, and its `tooltipText` so it describes the visible pane:

```qml
    active: root.incoming !== null || root.viewState === "receiving" || root.viewState === "sending" || root.viewState === "pin" || root.qsViewState === "sending"
    tooltipText: root.incoming ? "Incoming transfer"
      : (root.quickShareMode
        ? (root.qsViewState === "sending" ? "Quick Share · Sending" : (root.qsAvailable ? "Quick Share · Ready" : "Quick Share · Not installed"))
        : (!root.receiverEnabled ? "Nearby · Turned off" : (root.backendReady ? (root.viewState === "pin" ? "Nearby · PIN required" : "Nearby · Ready to receive") : "Nearby · Receiver unavailable")))
```

Note `root.incoming` is checked first in both bindings: an inbound request
outranks pane state, matching Step 3.

Then make `heroMetaText` consume `qsStatusText` when the Quick Share pane is
showing. Add, as the first branch of that binding:

```qml
    if (quickShareMode && viewState !== "incoming") {
      if (qsViewState === "sending") return "Sending"
      if (qsViewState === "success") return "Sent"
      if (qsViewState === "error") return "Failed"
      if (!qsAvailable) return "Setup required"
      return qsScanning ? "Searching" : "Ready to send"
    }
```

**Verify**: `grep -c 'qsStatusText' Panel.qml` → still `1` if you did not use it,
or `2` if you did. Either is acceptable **provided** the hero no longer reports
LocalSend state over a Quick Share pane; if `qsStatusText` remains unused after
this step, delete the declaration rather than leaving a dead property.

### Step 5: Notify on Quick Share terminal states

`Service.qml` emits notifications for LocalSend events. Add the equivalent to
`QuickShare.qml` so a transfer that finishes after the popup closed is not
silent. Follow the notification pattern already used in `Service.qml` — read it
first and match its argv shape and app-name.

Fire on success and on error inside `finishSend`, and **not** on cancellation
(the user initiated that and does not need telling).

Because `QuickShare.qml` is a singleton child of `Service.qml`, this is the
correct home for it under the per-monitor rule quoted in "Current state" — do not
put it in `Panel.qml`.

**Verify**: `grep -c 'notify-send' QuickShare.qml` → at least `1`;
`node tests/quickshare-state.test.js` → exit 0 if that suite exists (plan 010),
otherwise note it as unverified-by-execution.

### Step 6: Tests

`tests/service-state.test.js`:
1. `setMode("localsend")` with `anyViewOpen`, `backendReady`, `receiverEnabled`,
   `viewState === "nearby"` → a `discovery_start` command is sent.
2. `setMode("quickshare")` → a `discovery_stop` command is sent.
3. `setMode` to the mode already active → no commands sent.

`tests/panel-state.test.js`:
4. `panel({quickShareMode: true, viewState: "incoming", incoming: {...},
   selectedIndex: 1})` → `activateCursor()` calls `acceptIncoming`.
5. Same with `selectedIndex: 0` → calls `declineIncoming`.
6. Same context → `moveCursor(1, 0)` clamps within `0..1`.
7. `quickShareMode: true, viewState: "nearby", qsViewState: "sending"` →
   `activateCursor()` does **not** call `acceptIncoming`.

**Verify**: `node tests/service-state.test.js && node tests/panel-state.test.js`
→ exit 0.

## Test plan

- Seven cases across the two existing suites, using their existing sandbox
  helpers as the structural pattern.
- Case 4 is the regression gate for the unactionable-request bug.
- The `BarIconButton` and notification changes are property bindings and a
  `Process`; verified by source-text assertion and review, not execution.
- Verification: all four Node suites green.

## Done criteria

ALL must hold:

- [ ] `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` exits 0
- [ ] `node tests/quickshare-state.test.js` exits 0, if plan 010 has landed
- [ ] `grep -c 'visible: !root.quickShareMode' Panel.qml` returns `9` (the incoming column no longer counted)
- [ ] `grep -c 'qsViewState === "sending"' Panel.qml` returns at least `2` (icon + hero)
- [ ] `grep -c 'notify-send' QuickShare.qml` returns at least `1`
- [ ] `grep -c 'qsStatusText' Panel.qml` returns `0` or `2` — never `1` (no dead property)
- [ ] `git status --porcelain` lists only the in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plans 003 and 004 have not landed. This plan edits the same regions of
  `Panel.qml` and will conflict.
- `Service.qml` has no existing `notify-send` invocation to model Step 5 on.
  Report rather than inventing a notification shape.
- Making the incoming column render in both panes causes it to appear *during*
  an active Quick Share transfer in a way that hides the transfer's own column.
  If the two can be simultaneously visible, stop and report — the layout question
  needs a decision, and silently stacking them repeats the bug plan 003 fixed.
- You conclude the right answer is to auto-switch panes on an inbound request.
  That is a plausible design and it is explicitly **not** what this plan chose;
  raise it rather than implementing it.

## Maintenance notes

- Anything that crosses the pane boundary — notifications, the bar icon, the
  hero, an inbound request — must be considered in both modes. The pattern to
  follow is: check `incoming` first, then `quickShareMode`, then pane-local state.
- Discovery lifecycle now has three triggers: `viewOpened`, `setMode` in both
  directions, and `viewClosed`. A fourth will need the same treatment; they are
  all in `Service.qml` deliberately.
- Deliberately deferred: whether an inbound request should raise the popup on the
  focused monitor. That is a shell-level concern and touches the IPC summon path.
