# Plan 008: Sanitise remote device names at the ingestion boundary

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- Model.js QuickShare.qml Panel.qml tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW — changes displayed text only, and only for names that are
  already hostile
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

Device names in this plugin arrive from **unauthenticated LAN advertisements** —
anything on the network can choose what it is called. Those names are rendered
in the popup: in the device list, in the hero title, and in the Quick Share
confirmation-code block.

Qt's `Text` element defaults to `textFormat: Text.AutoText`, which applies
rich-text detection: a string that looks like markup is rendered *as* markup.
Most of the plugin's own `Text` elements set `textFormat: Text.PlainText`
explicitly — but four do not, and, more importantly, **three of the sinks belong
to the shared Omarchy UI kit, which the plugin cannot fix at the render site**.
Verified against the installed kit:

- `/usr/share/omarchy/shell/Ui/Button.qml` — renders `text: root.text` with no
  `textFormat`. This is every device row in both panes.
- `/usr/share/omarchy/shell/Ui/PanelHero.qml` — renders `text: root.title` and
  `text: root.meta.toUpperCase()`, neither with `textFormat`.

`grep -c textFormat` returns `0` for both files, and there is exactly one copy of
the kit on the system with no plugin-local override shadowing it.

The consequence is that a hostile alias containing markup is rendered as HTML
inside the shell's own popup: spoofed layout in the device list and hero, and an
image source causing the shell process to fetch remote content unprompted. The
Quick Share confirmation-code block is the worst sink, because that block is the
out-of-band verification step the user is meant to trust.

This is not a hypothetical requirement. `ROBUSTNESS.md` item 10 already states
the invariant this plan restores:

> Test aliases, filenames and text containing `<b>`, quotes, `$()`, newlines and
> emoji. They must render literally and must not execute commands or markup.

Because the kit cannot be fixed from here, the fix must happen **once at
ingestion**, where remote names enter the model — which then covers every
downstream sink, including the ones the plugin does not own.

## Current state

Two ingestion points, one per protocol.

**LocalSend** — `Model.js`, `upsertDevice`. `device.alias` comes from the Rust
helper's JSON event, which carries the remote-supplied alias:

```js
function upsertDevice(devices, device) {
  if (!device || !device.fingerprint || !device.alias) return devices || []
  var next = (devices || []).slice()
  var found = -1
  for (var i = 0; i < next.length; i++) if (next[i].fingerprint === device.fingerprint) { found = i; break }
  var row = {
    alias: String(device.alias), version: String(device.version || "2.1"), deviceModel: String(device.deviceModel || ""),
    deviceType: String(device.deviceType || "desktop"), fingerprint: String(device.fingerprint),
    port: Number(device.port || 53317), protocol: String(device.protocol || "https"),
    download: device.download === true, ip: String(device.ip || "")
  }
  if (found < 0) next.push(row); else next[found] = row
  next.sort(function(a, b) { return a.alias.localeCompare(b.alias) })
  return next
}
```

**Quick Share** — `QuickShare.qml`, `noteDevices`. `d.name` comes from the `qs`
CLI's JSON device list:

```qml
  function noteDevices(payload) {
    var parsed = null
    try { parsed = JSON.parse(payload) } catch (e) { parsed = null }
    if (!parsed || !parsed.length) { devices = []; return }
    var next = []
    for (var i = 0; i < parsed.length; i++) {
      var d = parsed[i]
      // `id` is already "ip:port" and is exactly what `qs send --to` accepts,
      // so it is carried through untouched rather than rebuilt from ip/port.
      next.push({ alias: String(d.name || "Unknown"), id: String(d.id || ""),
                  deviceType: String(d.type || "device"), ip: String(d.ip || "") })
    }
    next.sort(function(a, b) { return a.alias.localeCompare(b.alias) })
    devices = next
  }
```

The four bare `Text` elements in `Panel.qml` that also need `textFormat` — find
them by their content: the sending/receiving progress caption that concatenates
`transferPeer`, the Quick Share "Confirm this code on " + peer line, the line
rendering the parsed PIN, and the Quick Share progress caption. Neighbouring
`Text` elements in the same file already set `textFormat:Text.PlainText`, so
copy that exact spelling.

**Conventions:** `Model.js` is ES5-flavoured (`var`, `function`) so QML can load
it, and every function is exported on the last line and covered in
`tests/model.test.js`. `tests/model.test.js` already contains a fixture with a
markup-bearing alias:

```js
const phone = {alias:"<b>Phone</b>",fingerprint:"fp",deviceType:"mobile",ip:"192.0.2.2"}
```

That fixture exists but nothing currently asserts the alias is neutralised.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Model tests | `node tests/model.test.js` | `Model tests passed`, exit 0 |
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |
| Syntax check | `node --check Model.js` | exit 0 |

There is no QML runtime available for verification here. `QuickShare.noteDevices`
is not reachable from the Node suites, so its change is verified by source-text
assertion plus review — say so plainly in your report rather than implying it was
executed.

## Scope

**In scope**:
- `Model.js` — add a `displayName` helper, use it in `upsertDevice`, export it
- `QuickShare.qml` — use the same rule in `noteDevices`
- `Panel.qml` — add `textFormat: Text.PlainText` to the four bare `Text` elements
- `tests/model.test.js` — assertions
- `tests/panel-state.test.js` — a source-text assertion for the four elements

**Out of scope** (do NOT touch):
- `/usr/share/omarchy/shell/Ui/*` — **not this repo.** It is the packaged
  Omarchy shell and edits there are overwritten on update. Reporting the missing
  `textFormat` upstream is a worthwhile follow-up, but it is not this plan and
  you must not edit those files.
- `backend/` — the Rust helper already truncates aliases for its log lines. Its
  event payloads are a separate finding.
- The `fingerprint` field. It is a map key and a TLS pinning input; truncating or
  rewriting it would break peer identity. Sanitise `alias` only.
- `QuickShare.qml`'s `id` field — it is `ip:port` and is passed to `qs --to`.

## Git workflow

- Branch: `advisor/008-sanitise-remote-device-names`
- Conventional commits; `fix:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a `displayName` helper to `Model.js`

Place it next to `iconFor`, in the file's existing ES5 style. Note the character
class in the second `replace` is the C0 control range plus DEL, written with hex
escapes — do not type literal control characters into the source:

```js
// Remote device names arrive from unauthenticated LAN advertisements, and the
// shared Omarchy UI kit renders Button.text and PanelHero.title/meta with Qt's
// default AutoText, which turns anything that looks like markup into markup.
// The plugin cannot set textFormat on those elements, so names are neutralised
// here instead -- once, at the boundary, covering every downstream sink.
// ROBUSTNESS.md item 10 requires such names render literally.
function displayName(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
  var max = Number(limit || 64)
  // Angle brackets are what Qt's rich-text detection keys on; control
  // characters and newlines let a name break out of its row visually.
  text = text.replace(/[<>]/g, "").replace(/[\x00-\x1F\x7F]/g, " ")
  text = text.replace(/\s+/g, " ").trim()
  if (text.length > max) text = text.slice(0, max - 1) + "…"
  return text
}
```

Add `displayName` to the export object on the last line of `Model.js`.

**Verify**: `node -e "const M=require('./Model.js'); console.log(JSON.stringify(M.displayName('<b>Phone</b>')))"`
→ prints `"bPhone/b"`.

### Step 2: Use it in `upsertDevice`

Change only the `alias:` field of the `row` object:

```js
    alias: displayName(device.alias), version: String(device.version || "2.1"), deviceModel: String(device.deviceModel || ""),
```

Leave the `!device.alias` guard at the top of the function alone — it rejects an
absent alias before sanitising, which is still correct. Note the sort below uses
`a.alias.localeCompare(b.alias)`, which now sorts on the sanitised value; that is
intended and harmless.

**Verify**: `node -e "const M=require('./Model.js'); console.log(M.upsertDevice([], {alias:'<b>P</b>',fingerprint:'fp'})[0].alias)"`
→ prints `bP/b`.

### Step 3: Apply the same rule in `QuickShare.qml`

`QuickShare.qml` must import the model before it can use the helper. Confirm the
line `import "Model.js" as Model` is present at the top; `Panel.qml` has it in
that exact form. If it is absent, add it alongside the other imports.

Then, in `noteDevices`, change the alias field only:

```qml
      next.push({ alias: Model.displayName(d.name || "Unknown"), id: String(d.id || ""),
                  deviceType: String(d.type || "device"), ip: String(d.ip || "") })
```

**Verify**: `grep -c 'Model.displayName' QuickShare.qml` → `1`, and
`grep -c 'import "Model.js" as Model' QuickShare.qml` → `1`.

### Step 4: Set `textFormat` on the four bare `Text` elements in `Panel.qml`

First record the baseline: `grep -c 'textFormat:Text.PlainText' Panel.qml` and
note the number.

Add `textFormat:Text.PlainText` to each of the four elements named in "Current
state", matching the exact spelling used by their neighbours in the same file
(no space after the colon, in the compact blocks).

This is defence in depth: after Steps 1–3 the *names* are already neutralised,
but the PIN string parsed out of the `qs` CLI's stderr also lands in one of these
elements and is not covered by `displayName`.

Additionally, cap the rendered PIN so an over-long capture cannot distort the
popup — add `elide:Text.ElideRight` to the element that renders
`root.qsTransferPin`.

**Verify**: `grep -c 'textFormat:Text.PlainText' Panel.qml` → exactly 4 higher
than the baseline you recorded.

### Step 5: Assert the behaviour in `tests/model.test.js`

The file already declares a markup-bearing fixture; add assertions for it. Write
the control character with an escape, never literally:

```js
// ROBUSTNESS.md item 10: names containing markup must render literally. The
// shared UI kit renders device rows with Qt's AutoText, so the neutralising has
// to happen here rather than at the render site.
assert.equal(Model.displayName("<b>Phone</b>"), "bPhone/b")
assert.equal(Model.displayName("<img src=x>"), "img src=x")
assert.equal(Model.displayName("Phone\nName"), "Phone Name", "a newline must not break the row")
assert.equal(Model.displayName("Phone\x07Name"), "Phone Name", "control characters are neutralised")
assert.equal(Model.displayName("  Phone  "), "Phone")
assert.equal(Model.displayName(""), "")
assert.equal(Model.displayName(null), "")
assert.equal(Model.displayName(undefined), "")
assert.equal(Model.displayName("x".repeat(200)).length, 64, "an over-long name is capped")
assert.equal(Model.displayName("Ok Name"), "Ok Name", "an ordinary name is unchanged")
assert.equal(Model.displayName("Phone ❤"), "Phone ❤", "emoji survive")
assert.equal(Model.upsertDevice([], {alias:"<b>P</b>", fingerprint:"fp"})[0].alias, "bP/b",
  "the LocalSend ingestion point neutralises aliases")
```

The "emoji survive" case matters: `ROBUSTNESS.md` item 10 lists emoji alongside
markup, and a sanitiser that strips them would fail the same requirement from
the other direction.

**Verify**: `node tests/model.test.js` → `Model tests passed`, exit 0.

### Step 6: Assert the Quick Share side by source text

`QuickShare.noteDevices` cannot be reached from Node. Add a source assertion to
whichever suite already reads `QuickShare.qml`; if none does, add it to
`tests/model.test.js` with an explicit read:

```js
const fs = require("node:fs")
const quickShareSource = fs.readFileSync(require.resolve("../QuickShare.qml"), "utf8")
assert.match(quickShareSource, /alias: Model\.displayName\(/,
  "Quick Share device names must be neutralised at ingestion, like LocalSend's")
```

**Verify**: the chosen suite passes.

### Step 7: Confirm the tests bite, and nothing regressed

Temporarily make `displayName` return its input unchanged, run
`node tests/model.test.js`, confirm it **fails**, then restore.

**Verify**: `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js`
→ exit 0. Report the stub-and-fail observation.

## Test plan

- `tests/model.test.js`: the twelve assertions in Step 5, covering markup,
  newlines, control characters, whitespace, empty/null/undefined, length cap,
  and the two must-not-change cases (ordinary names, emoji).
- Source-text assertion for the Quick Share ingestion point (Step 6).
- Structural pattern: the flat top-level `assert` style already in
  `tests/model.test.js`.
- Step 7 proves the suite is not vacuous.

## Done criteria

ALL must hold:

- [ ] `node -e "const M=require('./Model.js'); if(typeof M.displayName!=='function') process.exit(1)"` exits 0
- [ ] `node tests/model.test.js` exits 0 with the new assertions
- [ ] `node tests/panel-state.test.js && node tests/service-state.test.js` exits 0
- [ ] `grep -c 'Model.displayName' QuickShare.qml` returns `1`
- [ ] `grep -c 'alias: String(device.alias)' Model.js` returns `0`
- [ ] `grep -c 'textFormat:Text.PlainText' Panel.qml` is exactly 4 higher than the pre-change count
- [ ] Stubbing `displayName` to identity makes `node tests/model.test.js` fail (verified, then reverted)
- [ ] `git status --porcelain` lists only `Model.js`, `QuickShare.qml`, `Panel.qml`, and the test files
- [ ] No file under `/usr/share/omarchy/` was modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `upsertDevice` or `noteDevices` do not match the excerpts in "Current state".
- `QuickShare.qml` has no `import "Model.js" as Model` line and adding one in
  `Panel.qml`'s form appears to break the file's other imports.
- You find yourself wanting to edit anything under `/usr/share/omarchy/`. That is
  the packaged shell, not this repo; note the upstream issue in your report and
  stop.
- Stripping angle brackets turns out to break a legitimate device name in the
  fixtures — for example if a real LocalSend client is known to bracket its
  alias. Report rather than loosening the filter.
- Any existing assertion in `tests/model.test.js` starts failing because it
  expected a raw alias. That is a real conflict about intended behaviour; report
  the assertion rather than deleting it.

## Maintenance notes

- Every new field carrying remote-supplied text into the model must go through
  `displayName`. The two ingestion points are `Model.upsertDevice` (LocalSend)
  and `QuickShare.noteDevices` (Quick Share) — a third protocol would need a
  third call.
- `fingerprint` is deliberately **not** sanitised: it is a map key and a TLS
  pinning input. If a future change starts displaying it, sanitise a copy for
  display and never the stored value.
- A reviewer should confirm no file outside this repo was touched, and that the
  emoji case still passes — over-aggressive sanitising fails `ROBUSTNESS.md`
  item 10 just as markup does.
- Worthwhile follow-up, deliberately out of scope: report the missing
  `textFormat` on `Ui/Button.qml` and `Ui/PanelHero.qml` upstream to Omarchy, so
  other plugins are covered too. Also out of scope: `Service.qml` passes a remote
  sender name into a `notify-send` body, and most notification daemons parse
  markup — that path needs the same treatment and is tracked separately.
