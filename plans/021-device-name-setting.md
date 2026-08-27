# Plan 021: Let the user choose the name this machine advertises

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- Panel.qml Service.qml QuickShare.qml Model.js manifest.json tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED — changing the name requires restarting the receiver, and a
  careless implementation can restart it on every keystroke
- **Depends on**: `plans/007-export-and-test-model-helpers.md`,
  `plans/008-sanitise-remote-device-names.md`
- **Category**: direction
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

Every phone on the network currently sees this machine as **"Omarchy"** —
including machines belonging to different people, which makes them
indistinguishable in a device list.

That name is not a brand choice. It is an unreachable fallback:

```rust
let alias = std::env::var("HOSTNAME")
    .ok()
    .filter(|s| !s.is_empty())
    .unwrap_or_else(|| "Omarchy".into());
```

`HOSTNAME` is a **bash convenience variable that bash never exports**. Verified
on the target machine: `$HOSTNAME` is `luna` in an interactive shell, `env | grep
-c '^HOSTNAME='` returns `0`, and the running helper's `/proc/<pid>/environ`
contains **zero** `HOSTNAME` entries. A GUI-launched daemon therefore essentially
never sees it, and every Omarchy Nearby user in the world advertises the same
literal string.

This plan gives the user a name they choose, with three modes, exposed through a
settings control in the pane:

1. **Hostname** — this machine's actual hostname (`luna` here).
2. **Generated** — a stable, friendly two-word name, in the spirit of the ones
   LocalSend makes up.
3. **Custom** — whatever the user types.

## Current state

**The helper takes its alias from the environment**, which is the hook this plan
uses. `Service.qml` spawns it as a plain `Process`:

```qml
      id: backend
      property bool launched: false
      command: [root.pluginDir + "/bin/omarchy-nearby-helper"]
      running: root.receiverConfigured && root.receiverEnabled && root.pluginVersion !== ""
      stdinEnabled: true
      stdout: SplitParser { onRead: function(line) { root.handleEvent(Model.parseLine(line)) } }
      stderr: SplitParser { onRead: function(line) { console.warn("nearby backend", line) } }
```

**Quickshell's `Process` supports an `environment` property.** Verified in
`quickshell-io.qmltypes`, which declares `environment`, `clearEnvironment` and
`workingDirectory` on `Process`. Setting `HOSTNAME` there is what makes this work
**without modifying `backend/`** — which matters, because `backend/` is
byte-identical to upstream and plan 015's release model depends on it staying so.

**Quick Share takes a name too.** `qs` declares a global flag:

```rust
    /// Our display name shown to the phone (default: hostname).
    #[arg(long, global = true)]
    name: Option<String>,
```

so one setting can drive both panes. `QuickShare.qml` builds argv in three
places (`scanner`, `sender`, and any future receive path); each needs `--name`.

**The hostname is readable without a subprocess**: `/proc/sys/kernel/hostname`
contains `luna` on this machine. Use `FileView` on that path — it matches how
`Service.qml` already reads `manifest.json`.

**Settings live in the shell config, not in the widget.** `Service.qml` reads
them from the bar entry, and `Model.js` provides the accessors:

```qml
  readonly property var pluginSettings: configEntry ? configEntry.settings : ({})
  readonly property bool receiverEnabled: Model.receiverEnabledIn(configEntry)
  readonly property string mode: Model.modeIn(configEntry)
```

with persistence via `persistMode` / `persistReceiverEnabled`, both of which call
`shell.updateEntryInline` (or `mutateShellConfig` when the entry is a bare
string). Copy that shape exactly — do **not** store the name in `Panel.qml`,
which the bar instantiates once per monitor.

`manifest.json` currently declares two settings:

```json
  "settings": {
    "receiverEnabled": { "type": "boolean", "default": true, "description": "Run the LocalSend receiver" },
    "mode": { "type": "string", "default": "localsend", "description": "Which pane opens first: localsend or quickshare" }
  }
```

**The hero already hosts one trailing control**, which is where the cog goes:

```qml
          trailingControl: root.viewState === "nearby" ? receiverToggle : null
        }
        Component {
          id: receiverToggle
          ToggleSwitch {
            checked: root.receiverEnabled
            hasCursor: root.cursorActive && root.selectedIndex < 0
            foreground: root.foreground
            onHovered: function(on) { root.noteHover(on, -1) }
            onToggled: root.toggleReceiver()
            PanelToolTip { visible: parent.containsMouse; text: root.receiverEnabled ? "Turn Nearby off" : "Turn Nearby on"; fontFamily:root.fontFamily }
          }
        }
```

**The critical behavioural constraint**: the helper reads its alias **once, at
startup**. Changing the name therefore requires restarting the receiver. The
existing `toggleReceiver` already performs a clean shutdown (`shutdown` command,
`receiverShutdownFallback` timer, `finishReceiverShutdown`) — reuse that path
rather than killing the process.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Model tests | `node tests/model.test.js` | `Model tests passed`, exit 0 |
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |
| Quick Share suite | `node tests/quickshare-state.test.js` | pass line, exit 0 (if plan 010 landed) |
| Manifest valid | `jq -e . manifest.json && omarchy plugin validate .` | exit 0 |
| See the live name | `omarchy-shell t1nk33r.nearby-share status` | JSON; alias visible after step 7 |

## Scope

**In scope**:
- `Model.js` — name resolution and generation (pure, testable)
- `Service.qml` — the setting, persistence, `Process.environment`, restart-on-change
- `QuickShare.qml` — pass `--name` in every argv
- `Panel.qml` — the cog and the name view
- `manifest.json` — declare the two new settings
- `tests/model.test.js`, `tests/service-state.test.js`, `tests/panel-state.test.js`

**Out of scope** (do NOT touch):
- **`backend/` — any file.** The whole design exists to avoid touching it. If you
  find yourself editing Rust, you have taken a wrong turn.
- The `"Omarchy"` fallback itself. It is upstream's, and fixing it properly
  (reading `gethostname(2)` or `/proc/sys/kernel/hostname` in Rust) is an
  upstream report — see plan 018's maintenance notes.
- `scripts/**` and the firewall.

## Git workflow

- Branch: `advisor/021-device-name-setting`
- Conventional commits; `feat:` is correct here.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add name resolution to `Model.js`

Three pure functions, in the file's ES5 style (`var`, `function`):

```js
// The advertised name has three sources. `hostname` and `generated` are derived,
// so only the mode and the custom string are persisted -- a generated name that
// changed on every launch would show up as a new device on the phone each time,
// which is why it is seeded rather than random.
function deviceNameModeIn(entry) {
  var mode = entry && entry.settings ? String(entry.settings.deviceNameMode || "") : ""
  return (mode === "hostname" || mode === "generated" || mode === "custom") ? mode : "hostname"
}

function customDeviceNameIn(entry) {
  return entry && entry.settings ? String(entry.settings.deviceName || "") : ""
}

// Deterministic from the seed, so the same machine keeps the same name across
// restarts without persisting it.
function generatedDeviceName(seed) {
  var adjectives = ["Amber","Brisk","Calm","Copper","Dusty","Eager","Fleet","Glass",
                    "Hazel","Ivory","Jolly","Keen","Lucky","Mellow","Noble","Olive",
                    "Plucky","Quiet","Rapid","Silver","Tidy","Umber","Vivid","Warm"]
  var nouns = ["Otter","Badger","Falcon","Heron","Lynx","Marten","Osprey","Puffin",
               "Raven","Shrew","Stoat","Tern","Vole","Weasel","Wren","Ibis",
               "Kestrel","Magpie","Nuthatch","Pika","Quail","Redwing","Sable","Teal"]
  var text = String(seed || "")
  var hash = 0
  for (var i = 0; i < text.length; i++) hash = ((hash * 31) + text.charCodeAt(i)) >>> 0
  return adjectives[hash % adjectives.length] + " " + nouns[(hash >>> 8) % nouns.length]
}

// The one function callers use. Falls back down the chain rather than ever
// returning empty: an empty alias makes the helper advertise nothing useful.
function resolveDeviceName(entry, hostname, seed) {
  var mode = deviceNameModeIn(entry)
  var custom = displayName(customDeviceNameIn(entry), 32)
  var host = displayName(hostname, 32)
  if (mode === "custom" && custom !== "") return custom
  if (mode === "generated") return generatedDeviceName(seed || host || "nearby")
  if (host !== "") return host
  return generatedDeviceName(seed || "nearby")
}
```

`displayName` comes from plan 008 — it strips angle brackets and control
characters and caps length, which is exactly the validation a user-typed name
needs. If plan 008 has not landed, STOP (see STOP conditions).

Export all four on the last line of `Model.js`.

**Verify**: `node -e "const M=require('./Model.js'); console.log(M.resolveDeviceName({settings:{deviceNameMode:'custom',deviceName:'My Box'}},'luna','fp'))"`
→ prints `My Box`.

### Step 2: Declare the settings in `manifest.json`

```json
    "deviceNameMode": {
      "type": "string",
      "default": "hostname",
      "description": "Where the advertised name comes from: hostname, generated or custom"
    },
    "deviceName": {
      "type": "string",
      "default": "",
      "description": "The advertised name when deviceNameMode is custom"
    }
```

**Verify**: `jq -e . manifest.json` → exit 0; `omarchy plugin validate .` → exit 0.

### Step 3: Read the hostname in `Service.qml`

Add a `FileView` beside the existing `manifest.json` one:

```qml
  property string systemHostname: ""

  FileView {
    path: "/proc/sys/kernel/hostname"
    printErrors: false
    onLoaded: root.systemHostname = String(text() || "").trim()
    onLoadFailed: root.systemHostname = ""
  }
```

**Verify**: `node tests/service-state.test.js` → exit 0.

### Step 4: Expose the resolved name and persist the setting

In `Service.qml`, alongside `mode` and `receiverEnabled`:

```qml
  readonly property string deviceNameMode: Model.deviceNameModeIn(configEntry)
  readonly property string customDeviceName: Model.customDeviceNameIn(configEntry)
  // Seeded from the TLS fingerprint where one is known, so a generated name is
  // stable for this machine and distinct from another machine with the same
  // hostname. Falls back to the hostname before the helper has reported.
  readonly property string advertisedName: Model.resolveDeviceName(configEntry, systemHostname, helperFingerprint || systemHostname)
```

Add `property string helperFingerprint: ""` and set it from the helper's `ready`
event, which already carries `fingerprint` (see `handleEvent`).

Add a `persistDeviceName(mode, custom)` modelled **exactly** on the existing
`persistMode`, including its `hasStringBarEntry` / `mutateShellConfig` branch.

**Verify**: `node tests/service-state.test.js` → exit 0.

### Step 5: Pass the name to the helper, and restart when it changes

Give the backend `Process` an environment:

```qml
      // The helper reads its advertised alias from HOSTNAME at startup, and
      // HOSTNAME is a bash variable that is never exported -- so a GUI-launched
      // helper always fell back to a hardcoded string. Supplying it here fixes
      // the name without patching the helper, which must stay identical to
      // upstream.
      environment: ({ "HOSTNAME": root.advertisedName })
```

Then restart the receiver when the name changes — but **only** when it actually
changes and only when the receiver is running:

```qml
  onAdvertisedNameChanged: {
    if (!receiverEnabled || !backend.running || shutdownPending) return
    nameRestart.restart()
  }

  // Debounced: a custom name is typed one character at a time, and restarting
  // the receiver per keystroke would bind and unbind the port repeatedly.
  Timer {
    id: nameRestart
    interval: 1200
    repeat: false
    onTriggered: root.restartForName()
  }

  function restartForName() {
    if (!receiverEnabled || shutdownPending) return
    statusText = "Applying new name…"
    send({command:"shutdown"})
    // The existing shutdown path clears state and unbinds; the running binding
    // brings the helper straight back with the new environment.
    receiverShutdownFallback.restart()
  }
```

**Read `finishReceiverShutdown` before writing this.** It currently calls
`persistReceiverEnabled(false)`, which would turn the receiver *off* rather than
restart it. You need a restart that does **not** flip that setting — add a
`restartingForName` flag that `finishReceiverShutdown` checks, skipping the
`persistReceiverEnabled(false)` call and re-binding instead. Getting this wrong
turns a rename into "the receiver silently switched itself off", so verify it
explicitly in Step 8.

**Verify**: `node tests/service-state.test.js` → exit 0.

### Step 6: Pass `--name` to the Quick Share CLI

In `QuickShare.qml`, add a `property string advertisedName: ""` bound from the
service, and insert `--name` into **both** argv builders, immediately after
`--port`:

```qml
    command: [root.binary, "--port", String(root.port), "--name", root.advertisedName, "devices", "--json", "--timeout", String(root.scanTimeout)]
```

and the equivalent in `sender`'s `command` block. `--name` is a global flag, so
it must precede the subcommand.

Wire it in `Service.qml`'s `QuickShare { ... }` instantiation:
`advertisedName: root.advertisedName`.

Guard the empty case: if `advertisedName` is empty, omit the two argv entries
rather than passing an empty string, which `qs` would advertise literally.

**Verify**: `grep -c '"--name"' QuickShare.qml` → `2`;
`node tests/quickshare-state.test.js` → exit 0 if that suite exists.

### Step 7: Add the cog and the name view to `Panel.qml`

Replace the hero's single trailing control with a row holding a cog and the
existing toggle:

```qml
          trailingControl: root.viewState === "nearby" ? nearbyHeroControls : null
        }
        Component {
          id: nearbyHeroControls
          Row {
            spacing: Style.space(8)
            Button {
              bordered: false; iconText: "󰒓"; text: ""
              tooltipText: "Device name"
              foreground: root.dim; fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.selectedIndex === -3
              onHovered: function(v) { root.noteHover(v, -3) }
              onClicked: root.openDeviceName()
            }
            ToggleSwitch {
              checked: root.receiverEnabled
              hasCursor: root.cursorActive && root.selectedIndex === -1
              foreground: root.foreground
              onHovered: function(on) { root.noteHover(on, -1) }
              onToggled: root.toggleReceiver()
              PanelToolTip { visible: parent.containsMouse; text: root.receiverEnabled ? "Turn Nearby off" : "Turn Nearby on"; fontFamily:root.fontFamily }
            }
          }
        }
```

Index `-3` is new. The existing negative indices are `-2` (mode switcher) and
`-1` (receiver toggle), so extend the cursor floor from `-2` to `-3` in
`moveCursor`'s clamps — there are several; change them all.

Add a `device_name` view state with three rows plus a text field:

- A row per mode showing what it would produce: `Hostname (luna)`,
  `Generated (Amber Otter)`, `Custom`.
- A `TextField` enabled only in custom mode, `maximumLength: 32`.
- A Back row.
- A line stating that changing the name briefly restarts the receiver.

Gate its column on `!root.quickShareMode && root.viewState === "device_name"`,
matching the other LocalSend columns — **with parentheses if you write a
multi-state condition** (see plan 003).

Add `openDeviceName()`, `chooseNameMode(mode)`, `submitCustomName(text)` and a
Back route in `goBackLocalSend`, all delegating to the engine.

**Verify**: `node tests/panel-state.test.js` → exit 0.

### Step 8: Tests

`tests/model.test.js`:
1. `deviceNameModeIn` over null / `{}` / each valid mode / an unknown string
   (→ `hostname`).
2. `customDeviceNameIn` over null / missing / present.
3. `generatedDeviceName` is **deterministic**: same seed → same name, twice.
4. `generatedDeviceName` differs for two different seeds.
5. `resolveDeviceName`: custom mode with a custom name → that name; custom mode
   with an **empty** name → falls back, never returns `""`; hostname mode →
   hostname; hostname mode with empty hostname → a generated name;
   generated mode → the seeded name.
6. `resolveDeviceName` sanitises: a custom name containing markup comes back
   neutralised, and a 200-character name comes back capped.

`tests/service-state.test.js`:
7. `persistDeviceName("custom","Box")` writes both keys into the entry.
8. **The restart does not disable the receiver.** Drive `restartForName()` then
   `finishReceiverShutdown()` and assert `persistReceiverEnabled(false)` was
   **not** called and the receiver setting is still true. *This is the
   regression gate for Step 5's trap.*

`tests/panel-state.test.js`:
9. `moveCursor(0,-99)` from `0` in the LocalSend nearby view stops at `-3`.
10. `activateCursor()` at `-3` opens the device-name view; at `-1` still toggles
    the receiver.

**Verify**: all four suites exit 0.

## Test plan

- Ten cases across three suites; case 8 is the one that matters most, because
  the failure it guards (a rename silently switching the receiver off) is
  invisible until someone tries to receive a file.
- Structural pattern: the existing `panel({...})` and service sandbox helpers.
- The `Process.environment` binding and the QML columns are verified by
  source-text assertion and review, not execution — say so plainly in your
  report rather than implying the QML ran.
- Manual check worth doing if a phone is available: set a custom name, wait for
  the debounce, and confirm the phone shows it. Do **not** claim this was done
  if it was not — `AGENTS.md` forbids it.

## Done criteria

ALL must hold:

- [ ] `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` exits 0
- [ ] `node tests/quickshare-state.test.js` exits 0, if plan 010 has landed
- [ ] `jq -e . manifest.json && omarchy plugin validate .` exits 0
- [ ] `grep -c '"--name"' QuickShare.qml` returns `2`
- [ ] `grep -c 'HOSTNAME' Service.qml` returns at least `1`
- [ ] `git diff --stat backend/` shows **no** changes
- [ ] `grep -c 'selectedIndex < 0' Panel.qml` returns `0` (the toggle uses `=== -1`)
- [ ] Case 8 fails if `finishReceiverShutdown`'s guard is removed (verified, then restored)
- [ ] `git status --porcelain` lists only the in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 008 has not landed, so `Model.displayName` does not exist. A user-typed
  name is remote-ish input rendered in the same `AutoText` sinks; do not ship
  this without that sanitiser, and do not write a second copy of it.
- `Process` turns out not to accept `environment` at runtime despite the
  qmltypes declaration. Report what you observed; do **not** work around it by
  patching `backend/`.
- `finishReceiverShutdown` cannot be made to skip `persistReceiverEnabled(false)`
  without restructuring the shutdown path more broadly. Report rather than
  half-doing it — a rename that turns the receiver off is worse than no rename.
- You conclude the name should be stored in `Panel.qml`. It must not be: the bar
  builds one Panel per monitor and they would disagree.
- The generated-name lists need to match LocalSend's exact wordlist. They do not
  — the requirement is friendly and stable, not identical.

## Maintenance notes

- The advertised name reaches two engines by two different routes: the
  `HOSTNAME` environment variable for the LocalSend helper, and `--name` argv for
  the Quick Share CLI. A third engine would need a third wiring; there is no
  shared mechanism and deliberately so, because each is the interface its binary
  actually exposes.
- The name is read **once per helper start**. Anything that changes it must go
  through the debounced restart, or the phone will keep showing the old name
  until the next toggle.
- A generated name is seeded from the TLS fingerprint, so it survives restarts
  but changes if the identity is ever regenerated. That is acceptable, and it is
  another reason the identity should not silently rotate — see plan 018's
  finding on non-atomic identity persistence.
- Upstream should still fix its own fallback to read `gethostname(2)` rather than
  `$HOSTNAME`; this plan works around it for our users but every other Omarchy
  Nearby user still advertises "Omarchy". That is worth filing alongside plan
  018's five reports.
