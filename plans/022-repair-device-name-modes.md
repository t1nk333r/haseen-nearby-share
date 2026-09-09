# Plan 022: Make all three device-name modes actually work

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat eec2db4..HEAD -- Panel.qml Service.qml Model.js QuickShare.qml tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW — every change makes an unusable path usable
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `eec2db4`, 2026-08-28

## Why this matters

The device-name feature shipped with three modes. **Two of them are broken, and
one of them breaks the other pane.** All six defects below were confirmed by
reading the code; two were reproduced directly.

1. **A name starting with `-` breaks all of Quick Share.** The name goes into
   argv after `--name` with no guard. Reproduced against the shipped binary:
   `./bin/nearby-qs --port 53318 --name "-Luna" devices --json` →
   `error: unexpected argument '-L' found`. Both scanning and sending die. The
   LocalSend pane is unaffected because it uses the process environment, so the
   failure looks arbitrary and pane-specific.

2. **Generated mode displays one name and advertises a different one.** The
   engine seeds from the TLS fingerprint; the pane's button seeds from the
   hostname. Reproduced: advertised `Eager Puffin`, button showed `Lucky Vole`.
   The pane header (bound to the engine) and the button (computed locally) show
   two different names at once. Worse, the fingerprint only arrives on the
   helper's `ready` event — *after* the helper already launched — so
   `advertisedName` changes post-launch and triggers a guaranteed extra helper
   bounce roughly 1.2 s into every session in generated mode.

3. **Custom mode is unusable without a mouse.** The text field owns no cursor
   row, nothing ever focuses it, and `submitCustomName` has exactly one caller —
   the field's own `onAccepted`. Pressing Enter on the Custom row calls
   `chooseNameMode("custom")`, which re-persists the *previously saved* string
   and discards whatever was typed.

4. **The panel's key catcher is not blocked while the field has focus.** The UI
   kit's `PanelKeyCatcher` documents that a panel with an inline editor must set
   `blocked: editor.activeFocus`; both existing editors in this file do, and
   `nameInput` does not. Keys the field ignores move the panel cursor out from
   under the editor.

5. **The cog is live inside the Quick Share pane and dead-ends there.** Clicking
   it produces no visible pane, silently removes the receiver toggle from the
   header, and parks the engine in `device_name` with no exit but a pane switch.

6. **Discovery is dead after a rename.** Returning to the device list shows
   "No devices nearby" with discovery off, until the user finds Rescan.

## Current state

**`Panel.qml` — the key catcher, missing `nameInput`:**

```qml
        blocked: (root.viewState==="pin" && pinInput.activeFocus)||(root.viewState==="incoming_pin_edit"&&incomingPinInput.activeFocus)
```

**`Panel.qml` — `activateCursor`, with the `-3` check above the mode branch:**

```qml
    function activateCursor() {
      if (viewState === "device_name" && !quickShareMode) {
        if (selectedIndex === 0) chooseNameMode("hostname")
        else if (selectedIndex === 1) chooseNameMode("generated")
        else if (selectedIndex === 2) chooseNameMode("custom")
        else closeDeviceName()
        return
      }
      if (selectedIndex === -3) { openDeviceName(); return }
      if (selectedIndex === -2) { setMode(quickShareMode ? "localsend" : "quickshare"); return }
      if (quickShareMode) {
```

**`Panel.qml` — `moveCursor`, clamping the name view to rows 0..3:**

```qml
    function moveCursor(dx, dy) {
      cursorActive = true
      if (viewState === "device_name" && !quickShareMode) {
        if (dy !== 0) selectedIndex = Math.max(0, Math.min(3, selectedIndex + dy))
        return
      }
```

**`Panel.qml` — the hero control, gated on `viewState` only:**

```qml
          trailingControl: root.viewState === "nearby" ? nearbyHeroControls : null
```

**`Panel.qml` — the text field, with no `text:` binding and no cursor row:**

```qml
              id: nameInput
              visible: root.deviceNameMode === "custom"
              width:parent.width; placeholderText:"Name shown to other devices"; maximumLength:32
              foreground:root.foreground; font.family:root.fontFamily; font.pixelSize:Style.font.body
              onAccepted: root.submitCustomName()
              Keys.onPressed: function(event) { if(event.key===Qt.Key_Escape){root.closeDeviceName();event.accepted=true} }
            }
```

**`Panel.qml` — the locally recomputed preview (the divergence):**

```qml
  readonly property string generatedPreview: Model.generatedDeviceName(systemHostname || "nearby")
```

**`Service.qml` — the engine's own seed, which differs:**

```qml
  readonly property string advertisedName: Model.resolveDeviceName(configEntry, systemHostname, helperFingerprint !== "" ? helperFingerprint : systemHostname)
```

**`Service.qml` — `closeDeviceName`, which never restarts discovery:**

```qml
  function closeDeviceName() { viewState = "nearby"; cursorRequested(0); focusRestoreRequested() }
```

For contrast, `finishText()` and `finishTerminal()` in the same file *do*
restart discovery when returning to the nearby view — read them and match.

**`QuickShare.qml` — the two argv builders that take the name:** both push
`"--name"` followed by `root.advertisedName` before the subcommand.

**Conventions:**

- `Panel.qml` is a **view**: the bar builds one per monitor, so it must own
  nothing there can only be one of. `generatedPreview` violates this by
  recomputing a machine-wide value locally.
- The existing PIN editor is the exemplar for an inline field: `Service.qml`'s
  `beginIncomingPinEdit` emits `incomingPinFocusRequested()`, `Panel.qml`
  connects that signal to focus the field, and the field appears in the key
  catcher's `blocked` expression. Mirror that pattern exactly.
- `Model.js` is ES5-flavoured (`var`, `function`) and every function is exported
  on the last line and tested in `tests/model.test.js`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |
| Shell tests | `bash tests/updater.test.sh` | pass line, exit 0 |
| Validator | `omarchy plugin validate .` | exit 0 |
| Reproduce defect 1 | `./bin/nearby-qs --port 53318 --name "-Luna" devices --json` | before the fix: `error: unexpected argument '-L' found` |
| Live name | `omarchy-shell t1nk33r.nearby-share name` | the advertised name |

`omarchy restart shell` may refuse while the session is locked. QML property
bindings, `Process` and `Timer` blocks are not executed by the Node suites —
say plainly in your report which changes were verified by execution and which by
source assertion.

## Scope

**In scope**:
- `Model.js` — reject leading `-`/`+` in a name
- `Service.qml` — a single `generatedName`, the focus signal, `closeDeviceName`
- `Panel.qml` — key catcher, cursor rows, cog gating, field seeding, preview
- `tests/model.test.js`, `tests/panel-state.test.js`, `tests/service-state.test.js`

**Out of scope** (do NOT touch):
- `backend/` — byte-identical to upstream, deliberately.
- The rename *lifecycle* — aborting in-flight transfers and the 250 ms shutdown
  fallback are **plan 023**. Do not touch `restartForName` or
  `finishReceiverShutdown` here.
- The `displayName` strip-versus-escape question — **plan 024**, and it needs a
  maintainer decision. Do not change how `<` and `>` are handled.
- `scripts/**`, and the test-coverage gaps tracked separately.

## Git workflow

- Branch: `advisor/022-repair-device-name-modes`
- Conventional commits; `fix:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Reject names that argv would read as flags

In `Model.js`'s `displayName`, after the existing strips and before the length
cap, remove leading `-` and `+`:

```js
  // A leading hyphen makes the name parse as a flag when it is passed to the
  // Quick Share CLI as `--name <value>`, which kills every invocation with a
  // usage error. Verified: `--name "-Luna"` -> "unexpected argument '-L'".
  text = text.replace(/^[-+]+/, "").trim()
```

Place it so the whitespace collapse still runs on the result.

**Verify**: `node -e "const M=require('./Model.js'); console.log(JSON.stringify(M.displayName('-Luna')), JSON.stringify(M.displayName('--x')), JSON.stringify(M.displayName('a-b')))"`
→ `"Luna" "x" "a-b"` — an interior hyphen must survive.

### Step 2: Give the generated name one source of truth

Add to `Service.qml`, beside `advertisedName`:

```qml
  // One value, computed once. Panel.qml recomputing this locally produced a
  // button that showed a different name than the machine advertised, and the
  // bar builds one Panel per monitor, so a machine-wide name does not belong
  // there. Seeded from the hostname rather than the fingerprint: the
  // fingerprint only arrives on the helper's ready event, so seeding from it
  // changes the name after the helper has already launched and forces a
  // spurious bounce on every session.
  readonly property string generatedName: Model.generatedDeviceName(systemHostname !== "" ? systemHostname : "nearby")
```

Change `advertisedName` to seed from the same value:

```qml
  readonly property string advertisedName: Model.resolveDeviceName(configEntry, systemHostname, systemHostname !== "" ? systemHostname : "nearby")
```

`helperFingerprint` becomes unused by the name path. Leave the property and its
assignment in place (it is harmless and other work may want it) but delete it
from the `advertisedName` expression.

In `Panel.qml`, replace the local recomputation with the engine's value:

```qml
  readonly property string generatedPreview: engine ? engine.generatedName : ""
```

**Verify**: `node tests/service-state.test.js && node tests/panel-state.test.js`
→ exit 0. Then confirm the divergence is gone:
`node -e "const M=require('./Model.js'); const h='luna'; console.log(M.resolveDeviceName({settings:{deviceNameMode:'generated'}},h,h) === M.generatedDeviceName(h) ? 'MATCH' : 'STILL DIVERGENT')"`
→ `MATCH`.

### Step 3: Gate the cog on the LocalSend pane

Two changes. The hero control:

```qml
          trailingControl: !root.quickShareMode && root.viewState === "nearby" ? nearbyHeroControls : null
```

And move the `-3` branch in `activateCursor` **below** the `quickShareMode`
block so it cannot fire from the Quick Share pane. Cut this line from where it
currently sits above the mode check:

```qml
      if (selectedIndex === -3) { openDeviceName(); return }
```

and place it immediately after the `if (quickShareMode) { ... }` block closes,
before `if (viewState === "nearby") {`.

**Verify**: `node tests/panel-state.test.js` → exit 0;
`grep -n 'trailingControl' Panel.qml` → shows the `!root.quickShareMode &&` form.

### Step 4: Make the text field a real cursor row and block the key catcher

The name view's rows become: 0 Hostname, 1 Generated, 2 Custom, **3 the text
field**, 4 Back.

In `moveCursor`, widen the clamp to 4:

```qml
      if (viewState === "device_name" && !quickShareMode) {
        if (dy !== 0) selectedIndex = Math.max(0, Math.min(4, selectedIndex + dy))
        return
      }
```

In `activateCursor`'s `device_name` branch, focus the field on row 3 and treat
only row 4 as Back:

```qml
      if (viewState === "device_name" && !quickShareMode) {
        if (selectedIndex === 0) chooseNameMode("hostname")
        else if (selectedIndex === 1) chooseNameMode("generated")
        else if (selectedIndex === 2) chooseNameMode("custom")
        else if (selectedIndex === 3) focusCustomName()
        else closeDeviceName()
        return
      }
```

Add `function focusCustomName() { if (engine) engine.requestCustomNameFocus() }`
to `Panel.qml`, and in `Service.qml` add a signal plus emitter mirroring the PIN
editor:

```qml
  signal customNameFocusRequested()
  function requestCustomNameFocus() { if (deviceNameMode !== "custom") persistDeviceName("custom", customDeviceName); customNameFocusRequested() }
```

Connect it in `Panel.qml`'s existing `Connections` block, alongside
`onIncomingPinFocusRequested`:

```qml
    function onCustomNameFocusRequested() { if (root.opened) Qt.callLater(function(){ nameInput.forceActiveFocus() }) }
```

Give the field a cursor row and extend the key catcher:

```qml
        blocked: (root.viewState==="pin" && pinInput.activeFocus)||(root.viewState==="incoming_pin_edit"&&incomingPinInput.activeFocus)||(root.viewState==="device_name"&&nameInput.activeFocus)
```

and on the field itself add `hasCursor:root.cursorActive&&root.selectedIndex===3`
plus `onHovered` if the kit's `TextField` supports them — **if it does not,
leave the field without `hasCursor` and say so in your report**; the focus route
is what makes it reachable, the highlight is cosmetic.

Finally move the Back button to index 4: change its `hasCursor` and `onHovered`
from `3` to `4`.

**Verify**: `node tests/panel-state.test.js` → exit 0;
`grep -c 'nameInput.activeFocus' Panel.qml` → `1`.

### Step 5: Seed the field from the saved name

The field must show the saved custom name when the pane opens, without
clobbering in-progress typing. Seed on visibility rather than binding
continuously:

```qml
              onVisibleChanged: if (visible && text === "") text = root.customDeviceName
```

And make an empty submission a no-op rather than a silent revert to hostname —
in `Service.qml`:

```qml
  function submitCustomName(text) {
    var next = String(text || "").trim()
    // An empty submission used to persist "", which resolveDeviceName then
    // ignores in favour of the hostname -- so a stray Enter silently discarded
    // the user's name with no confirmation.
    if (next === "") return
    persistDeviceName("custom", next)
  }
```

**Verify**: `node tests/service-state.test.js` → exit 0.

### Step 6: Restart discovery when leaving the name pane

```qml
  function closeDeviceName() {
    viewState = "nearby"
    cursorRequested(0)
    focusRestoreRequested()
    // A rename bounces the helper, and the post-restart `ready` skips discovery
    // because the user is still sitting in this pane -- so returning to the
    // device list would show "No devices nearby" with discovery switched off.
    if (anyViewOpen && receiverEnabled && backendReady) startDiscovery()
  }
```

**Verify**: `node tests/service-state.test.js` → exit 0.

### Step 7: Tests

`tests/model.test.js`:
1. `displayName("-Luna")` → `"Luna"`; `displayName("--x")` → `"x"`;
   `displayName("a-b")` → `"a-b"` (interior hyphen survives);
   `displayName("-")` → `""`.
2. `resolveDeviceName` in generated mode equals `generatedDeviceName(hostname)`
   for the same hostname — the assertion that would have caught defect 2.

`tests/service-state.test.js`:
3. `submitCustomName("")` persists nothing; `submitCustomName("  ")` persists
   nothing; `submitCustomName("Box")` persists `Box`.
4. `closeDeviceName()` with `anyViewOpen`/`receiverEnabled`/`backendReady` true
   sends a `discovery_start`; with `backendReady` false it does not.

`tests/panel-state.test.js`:
5. Add `openDeviceName`, `closeDeviceName`, `chooseNameMode`, `submitCustomName`
   and `focusCustomName` to `functionNames` so they are extracted at all.
6. From `viewState:"device_name"`, `moveCursor(0,9)` clamps to `4` and
   `moveCursor(0,-9)` clamps to `0`.
7. `activateCursor()` at 0/1/2 records `chooseNameMode` with the right mode; at
   3 records the focus request; at 4 records `closeDeviceName`.
8. With `quickShareMode: true` and `selectedIndex: -3`, `activateCursor()` does
   **not** call `openDeviceName` — the regression gate for defect 5.
9. Source assertion: `trailingControl` includes `!root.quickShareMode`.

**Verify**: all suites exit 0.

### Step 8: Confirm the reproduced defects are gone

**Verify**:
`./bin/nearby-qs --port 53318 --name "$(node -e "const M=require('./Model.js');process.stdout.write(M.displayName('-Luna'))")" devices --json --timeout 1`
→ exits 0 with a JSON array, not a usage error.

Run all four suites and `omarchy plugin validate .` → all green.

## Test plan

- Nine cases across three suites. Cases 1, 2 and 8 are the regression gates for
  the three defects that were reproduced.
- Structural pattern: the existing `panel({...})` and `engine({...})` sandbox
  helpers.
- For each gate, revert the corresponding fix, confirm the test fails, restore,
  confirm it passes — and report both observations. A test that cannot fail is
  what let these six defects ship.

## Done criteria

ALL must hold:

- [ ] `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` exits 0
- [ ] `bash tests/updater.test.sh` exits 0 and `omarchy plugin validate .` exits 0
- [ ] `node -e "const M=require('./Model.js'); process.exit(M.displayName('-Luna')==='Luna'?0:1)"` exits 0
- [ ] `grep -c 'Model.generatedDeviceName' Panel.qml` returns `0` (the local recomputation is gone)
- [ ] `grep -c 'nameInput.activeFocus' Panel.qml` returns `1`
- [ ] `grep -c '!root.quickShareMode && root.viewState === "nearby" ? nearbyHeroControls' Panel.qml` returns `1`
- [ ] `Math.min(4, selectedIndex + dy)` appears in the `device_name` branch
- [ ] `git diff --stat backend/` shows no changes
- [ ] Each regression gate verified to fail with its fix reverted, then restored
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any "Current state" excerpt does not match the live code.
- The kit's `TextField` does not support `hasCursor`/`onHovered`. Leave the
  highlight out, keep the focus route, and say so — do not invent a wrapper.
- Making the field a cursor row conflicts with plans 003, 004, 012 or 014, which
  also edit `Panel.qml`'s cursor logic. Land whichever is in flight first, rebase,
  and re-read.
- You find yourself changing `restartForName` or `finishReceiverShutdown`. That
  is plan 023.
- You find yourself changing how `<` and `>` are handled. That is plan 024 and
  needs a maintainer decision.

## Maintenance notes

- The name view's rows are now 0 Hostname, 1 Generated, 2 Custom, 3 the field,
  4 Back. Adding a row means updating the clamp in `moveCursor`, the branch in
  `activateCursor`, and each row's own `hasCursor` — those three drifting apart
  is what produced the phantom rows this plan removes.
- Any value that describes the machine rather than the popup belongs in
  `Service.qml`. `generatedPreview` is the cautionary example: recomputed per
  monitor, it disagreed with the engine and nobody noticed.
- Any new string that reaches `qs` argv needs the leading-flag guard.
  `displayName` is now the single choke point for that; keep it so.
