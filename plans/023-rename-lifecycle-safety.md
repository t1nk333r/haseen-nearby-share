# Plan 023: Stop a rename destroying a live transfer or misreporting the receiver

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat eec2db4..HEAD -- Service.qml tests/service-state.test.js`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED — deferring a rename means the advertised name lags the setting
  until the deferral clears; get the re-arm wrong and the rename silently never
  applies
- **Depends on**: none (but conflicts textually with plan 022 — see Scope)
- **Category**: bug
- **Planned at**: commit `eec2db4`, 2026-08-28

## Why this matters

Changing the advertised name shuts the LocalSend helper down and lets it come
back, because the helper reads its alias only at startup. That bounce is
currently unconditional and reuses a timer whose safety argument no longer holds.

**A rename can abort a transfer in progress, with no error.** `restartForName`
consults only `receiverEnabled`, `shutdownPending` and `backend.running`. It
does not look at whether a transfer is running or a request is queued. The
shutdown clears `incomingQueue`, `activeIncomingSession` and `pendingOutgoing`,
but the rename branch of `finishReceiverShutdown` deliberately does not reset
`viewState` — so the panel is left showing a frozen progress bar under the
status "Applying new name…" / "Starting receiver…". Nothing leaves that state:
the back route falls through to closing the popup for those view states, and the
post-restart `ready` handler does not touch `viewState`. Recovery is toggling the
receiver off and on.

The same window destroys an **incoming request**: a request arriving while the
name pane is open flips `viewState` to `"incoming"`, and the already-armed
1200 ms timer then fires and tears the helper down underneath it. That is the
more reachable of the two, because the debounce window is exactly when a user is
fiddling with settings.

**The 250 ms shutdown fallback is not safe on this path.** That timer was
previously armed only by `toggleReceiver`, where firing early is harmless: that
path persists `receiverEnabled = false`, which breaks the `backend.running`
binding and takes the process down regardless. On the rename path
`receiverEnabled` stays true, so if the timer wins the race the helper is still
running — `restartingForName` and `shutdownPending` are both cleared, the
rebind is skipped because `backend.running` is still true, and the helper's real
exit a moment later is then handled by the *non-rename* branch. The user sees a
spurious "Receiver stopped" error, one of four restart attempts is burned, and
if the helper is wedged the panel sits at "Starting receiver…" while a healthy
helper still holds port 53317 under the old name.

## Current state

**`Service.qml` — the unconditional bounce:**

```qml
    function restartForName() {
      if (!receiverEnabled || shutdownPending || !backend.running) return
      restartingForName = true
      shutdownPending = true
      statusText = "Applying new name…"
      send({command:"shutdown"})
      receiverShutdownFallback.restart()
    }
```

**`Service.qml` — the debounce that arms it:**

```qml
  onAdvertisedNameChanged: {
    if (!receiverEnabled || !backend.running || shutdownPending) return
    nameRestart.restart()
  }
```

**`Service.qml` — the guarded shutdown branch.** Note it returns without
touching `viewState`, which is what orphans a transfer view:

```qml
    if (restartingForName) {
      restartingForName = false
      backendReady = false
      devices = []
      selectedDevice = null
      statusText = "Starting receiver…"
      errorText = ""
      if (!backend.running) bindBackendRunning()
      return
    }
    persistReceiverEnabled(false)
```

**`Service.qml` — the two timers.** `receiverShutdownFallback` is the one being
reused across two paths with different invariants:

```qml
  Timer { id: nameRestart; interval: 1200; repeat: false; onTriggered: root.restartForName() }
  Timer { id: receiverShutdownFallback; interval: 250; repeat: false; onTriggered: root.finishReceiverShutdown() }
```

**The transfer state to consult** — all already properties on `root`:
`viewState` (`"sending"`, `"receiving"`, `"incoming"`, `"pin"`),
`incomingQueue` (array), `pendingOutgoing` (object or null),
`activeIncomingSession` (string), `outgoingTransferId` (string).

**Conventions:** `Service.qml` is the single per-session engine; all transfer
state and all timers live here, never in `Panel.qml`. The existing
`backendRestart` timer shows the repo's idiom for a bounded retry with an
attempt counter — read it before adding a re-arm loop.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Service tests | `node tests/service-state.test.js` | `service state tests passed`, exit 0 |
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |
| Validator | `omarchy plugin validate .` | exit 0 |

The `Timer` blocks are QML declarations the Node harness does not execute; the
*functions* they call are extracted and do run. State which is which in your
report.

## Scope

**In scope**:
- `Service.qml` — `restartForName`, `onAdvertisedNameChanged`, the
  `restartingForName` branch of `finishReceiverShutdown`, and a rename-specific
  fallback timer
- `tests/service-state.test.js`

**Out of scope** (do NOT touch):
- `backend/` — byte-identical to upstream.
- `Panel.qml`, `Model.js`, `QuickShare.qml` — plan 022 owns the name modes, the
  cursor rows and the cog. This plan is only about what happens *during* the
  bounce.
- `closeDeviceName` — plan 022 adds the discovery restart there.
- `toggleReceiver`'s own path. It is correct as it stands; the fix here must not
  change its behaviour.

## Git workflow

- Branch: `advisor/023-rename-lifecycle-safety`
- Conventional commits; `fix:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a single predicate for "something is in flight"

In `Service.qml`, near the other derived properties:

```qml
  // A rename tears the helper down, which drops whatever it was carrying. The
  // shutdown clears the queues, so by the time anything could notice, the
  // transfer is already gone -- the check has to happen before the shutdown is
  // sent, not after.
  readonly property bool transferInFlight: viewState === "sending" || viewState === "receiving"
    || viewState === "incoming" || viewState === "pin"
    || incomingQueue.length > 0 || pendingOutgoing !== null
    || activeIncomingSession !== "" || outgoingTransferId !== ""
```

**Verify**: `node tests/service-state.test.js` → exit 0.

### Step 2: Defer the bounce instead of destroying the transfer

Rewrite `restartForName` to re-arm rather than proceed, with a bounded number of
deferrals so a stuck transfer cannot postpone the rename forever:

```qml
    function restartForName() {
      if (!receiverEnabled || shutdownPending || !backend.running) return
      if (transferInFlight) {
        // Wait for the transfer rather than killing it. Bounded so a wedged
        // session cannot postpone the rename indefinitely; after the budget the
        // rename is abandoned, not forced, because losing a transfer is worse
        // than advertising the old name until the next restart.
        if (nameRestartDeferrals >= 30) {
          nameRestartDeferrals = 0
          eprintNameDeferralGaveUp()
          return
        }
        nameRestartDeferrals++
        nameRestart.restart()
        return
      }
      nameRestartDeferrals = 0
      restartingForName = true
      shutdownPending = true
      statusText = "Applying new name…"
      send({command:"shutdown"})
      nameShutdownFallback.restart()
    }
```

Add `property int nameRestartDeferrals: 0`. Replace
`eprintNameDeferralGaveUp()` with whatever this file's convention is for a
non-fatal note — check whether `Service.qml` uses `console.warn` anywhere; if it
does not, drop the call entirely rather than introducing a new logging style.

Note the last line now arms a **new** timer, added in Step 3.

**Verify**: `node tests/service-state.test.js` → exit 0.

### Step 3: Give the rename bounce its own fallback

Add beside the existing timers:

```qml
  // Not receiverShutdownFallback. That timer's 250 ms is safe for
  // toggleReceiver, where firing early still takes the helper down because the
  // running binding breaks. On a rename receiverEnabled stays true, so an early
  // fire clears the flags while the helper is still up and the real exit is
  // then mishandled as an unexpected stop.
  Timer {
    id: nameShutdownFallback
    interval: 2000
    repeat: false
    onTriggered: root.finishNameShutdown()
  }
```

and the handler:

```qml
  function finishNameShutdown() {
    if (!restartingForName) return
    if (backend.running) {
      // The helper has not gone yet. Re-arm rather than declare the bounce
      // complete: clearing the flags now would hand the real exit to the
      // unexpected-stop path and show a spurious error.
      nameShutdownFallback.restart()
      return
    }
    finishReceiverShutdown()
  }
```

**Verify**: `node tests/service-state.test.js` → exit 0;
`grep -c 'nameShutdownFallback' Service.qml` → `3`.

### Step 4: Never leave a view orphaned

In the `restartingForName` branch of `finishReceiverShutdown`, reset any view
that the shutdown just invalidated. `device_name` is the expected case and must
be preserved; anything transfer-related must not survive:

```qml
    if (restartingForName) {
      restartingForName = false
      backendReady = false
      devices = []
      selectedDevice = null
      // The shutdown cleared the queues, so a transfer view left standing shows
      // a frozen progress bar with no route out -- goBack closes the popup for
      // those states and the post-restart ready does not touch viewState.
      if (viewState !== "device_name" && viewState !== "nearby") {
        viewState = "nearby"
        cursorRequested(0)
      }
      statusText = "Starting receiver…"
      errorText = ""
      if (!backend.running) bindBackendRunning()
      return
    }
```

**Verify**: `node tests/service-state.test.js` → exit 0.

### Step 5: Do not arm the debounce while a transfer is live

`onAdvertisedNameChanged` currently arms the timer regardless. Arming during a
transfer is harmless now that Step 2 defers, but it wakes the engine every
1.2 s for nothing. Tighten it:

```qml
  onAdvertisedNameChanged: {
    if (!receiverEnabled || !backend.running || shutdownPending) return
    nameRestartDeferrals = 0
    nameRestart.restart()
  }
```

Resetting the counter here is the important half: a *new* name change should get
a fresh deferral budget rather than inheriting the previous one's.

**Verify**: `node tests/service-state.test.js` → exit 0.

### Step 6: Tests

All of these drive extracted functions, so they execute for real. Add
`restartForName`, `finishNameShutdown` and `transferInFlight` handling to the
harness as needed — `restartForName` is already in `functionNames`.

1. **The regression gate.** `engine({receiverEnabled: true, viewState: "receiving",
   backend: {running: true, ...}})` → `restartForName()` sends **no**
   `shutdown` command and leaves `restartingForName` false. Revert Step 2,
   confirm this fails, restore.
2. Same with `incomingQueue: [{...}]` and with `pendingOutgoing: {...}` — each
   defers.
3. Idle (`viewState: "nearby"`, empty queues) → `restartForName()` **does** send
   `{command:"shutdown"}` and sets both flags.
4. Deferral budget: call `restartForName()` 31 times with a transfer in flight
   and assert it stops re-arming and resets the counter.
5. `finishNameShutdown()` with `backend.running` true → does **not** clear
   `restartingForName`; with it false → calls through and clears.
6. Orphan reset: `finishReceiverShutdown()` with `restartingForName: true` and
   `viewState: "sending"` → `viewState` becomes `"nearby"`; with
   `viewState: "device_name"` → it stays `"device_name"`.
7. The ordinary off path is untouched: `finishReceiverShutdown()` with
   `restartingForName: false` still persists the setting and sets
   `statusText` to `"Turned off"`.

**Verify**: `node tests/service-state.test.js` → exit 0 with the seven cases.

## Test plan

- Seven cases in `tests/service-state.test.js`, using the existing `engine({...})`
  sandbox helper as the structural pattern.
- Case 1 is the regression gate for the destroyed-transfer bug; case 5 for the
  early-fire bug; case 6 for the orphaned view.
- For cases 1, 5 and 6: revert the corresponding fix, confirm the test fails,
  restore, confirm it passes. Report all three observations. The defects this
  plan fixes shipped precisely because the guard's *producer* was never driven
  by a test.

## Done criteria

ALL must hold:

- [ ] `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` exits 0
- [ ] `omarchy plugin validate .` exits 0
- [ ] `grep -c 'transferInFlight' Service.qml` returns at least `2`
- [ ] `grep -c 'nameShutdownFallback' Service.qml` returns `3`
- [ ] `grep -c 'receiverShutdownFallback.restart()' Service.qml` returns `1` (only `toggleReceiver` still uses it)
- [ ] Cases 1, 5 and 6 each verified to fail with their fix reverted, then restored
- [ ] `git diff --stat backend/` shows no changes
- [ ] `git status --porcelain` lists only `Service.qml` and `tests/service-state.test.js`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any "Current state" excerpt does not match the live code.
- `Service.qml` has no existing logging convention and you are tempted to invent
  one for the give-up case. Drop the call instead and note it.
- The deferral loop can be shown to postpone a rename indefinitely — that means
  the budget is not being reset or `transferInFlight` never clears. Report it;
  an unbounded defer is a different bug, not a fix.
- Plan 022 is in flight. It does not touch these functions, but both plans edit
  `Service.qml`; sequence them and rebase.
- You conclude the right answer is to block renaming in the UI while a transfer
  runs. That is a reasonable alternative design and it is explicitly **not** what
  this plan chose — raise it rather than implementing it, because it changes what
  the cog does rather than what the engine does.

## Maintenance notes

- Two timers now feed shutdown: `receiverShutdownFallback` (250 ms, toggle path
  only) and `nameShutdownFallback` (2000 ms, rename path). They exist separately
  because their safety arguments differ — an early fire is harmless on one and
  actively wrong on the other. Do not re-merge them.
- `transferInFlight` is the single predicate for "do not tear the helper down".
  Anything else that wants to bounce the helper should consult it.
- The deferral budget is 30 × 1.2 s ≈ 36 s. If users report renames not applying
  during long transfers, raise the budget rather than removing the check — the
  alternative is silently killing their transfer, which is the bug this fixes.
