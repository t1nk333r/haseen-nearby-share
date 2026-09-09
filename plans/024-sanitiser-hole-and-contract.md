# Plan 024: Close the remaining sanitiser hole and settle what "render literally" means

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat eec2db4..HEAD -- Model.js Service.qml Panel.qml QuickShare.qml ROBUSTNESS.md tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1 for Step 1–3 (the hole); P2 for Step 4 (the contract)
- **Effort**: S
- **Risk**: LOW for the hole; MED for the contract change, which alters what
  every existing device row displays
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `eec2db4`, 2026-08-28

## Why this matters

Device names in this plugin come from **unauthenticated LAN advertisements** —
anything on the network chooses what it is called. They are rendered by UI kit
components the plugin does not control, which use Qt's default `Text.AutoText`,
so a name that looks like markup is rendered *as* markup. Verified: `grep -c
textFormat` returns `0` for both `/usr/share/omarchy/shell/Ui/Button.qml` and
`/usr/share/omarchy/shell/Ui/PanelHero.qml`, and a filesystem-wide search
confirmed there is exactly one copy of the kit with no override shadowing it.

`Model.displayName` was added to neutralise names once, at ingestion, precisely
because the render sites cannot be fixed. **Two problems remain.**

**One value bypasses it.** `systemHostname` is the raw trimmed contents of
`/proc/sys/kernel/hostname`, and it is concatenated straight into a kit `Button`
label in the device-name pane. The *advertised* name derived from the hostname
is sanitised; the one *displayed* is not. Impact is bounded — it takes a
deliberate `sethostname` to exploit — but it is a new hole in the function
written to close exactly this class, and the fix is one call.

**And the sanitiser does not do what the documentation says.**
`ROBUSTNESS.md` item 10 requires that names containing `<b>`, quotes, `$()`,
newlines and emoji "must render literally and must not execute commands or
markup." `displayName` *deletes* `<` and `>`, so a device legitimately named
`<b>Phone</b>` renders as `bPhone/b` — not literal, silently corrupted. The
implementation meets a weaker property (no markup executes) than the document
specifies, and the new tests freeze that divergence in place. Per the audit
playbook's decision-drift rule, one of the two is wrong and the team should know
which.

## Current state

**`Model.js` — the sanitiser:**

```js
function displayName(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
  var max = Number(limit || 64)
  text = text.replace(/[<>]/g, "").replace(/[\x00-\x1F\x7F]/g, " ")
  text = text.replace(/\s+/g, " ").trim()
  if (text.length > max) text = text.slice(0, max - 1) + "…"
  return text
}
```

Note it does not touch `&`.

**`Service.qml` — the unsanitised hostname:**

```qml
  FileView {
    path: "/proc/sys/kernel/hostname"
    printErrors: false
    onLoaded: root.systemHostname = String(text() || "").trim()
    onLoadFailed: root.systemHostname = ""
  }
```

**`Panel.qml` — where it reaches an AutoText sink:**

```qml
              iconText:"\u{f0322}"; text:"Hostname · " + (root.systemHostname !== "" ? root.systemHostname : "unknown")
```

`Button`'s label is rendered by a bare `Text` in the kit with no `textFormat`.

**`ROBUSTNESS.md` item 10 — the contract:**

```
10. Test aliases, filenames and text containing `<b>`, quotes, `$()`, newlines and emoji.
    They must render literally and must not execute commands or markup.
```

**`tests/model.test.js` — the assertions that freeze the current behaviour:**

```js
assert.equal(Model.displayName("<b>Phone</b>"), "bPhone/b")
assert.equal(Model.displayName("<img src=x>"), "img src=x")
```

**Where `displayName` is already applied correctly** — keep these working:
`Model.upsertDevice` (LocalSend ingestion) and `Model.resolveDeviceName` (the
custom name and the hostname that feed the advertised value).

**Still outstanding from plan 008**, and deliberately not this plan's job:
`textFormat: Text.PlainText` on four bare `Text` elements in `Panel.qml`, the PIN
length cap, and routing `QuickShare.noteDevices`' alias through `displayName`.

**Conventions:** `Model.js` is ES5-flavoured (`var`, `function`), exported on the
last line, tested in `tests/model.test.js`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Model tests | `node tests/model.test.js` | `Model tests passed`, exit 0 |
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |
| Kit has no textFormat | `grep -c textFormat /usr/share/omarchy/shell/Ui/Button.qml` | `0` |

## Scope

**In scope**:
- `Service.qml` — sanitise the hostname at ingestion
- `Model.js` — only if Step 4's decision says so
- `ROBUSTNESS.md` — only if Step 4's decision says so
- `tests/model.test.js`

**Out of scope** (do NOT touch):
- `/usr/share/omarchy/shell/Ui/*` — **not this repo.** It is the packaged
  Omarchy shell; edits there are overwritten on update. Reporting the missing
  `textFormat` upstream is worthwhile and is not this plan.
- The four bare `Text` elements in `Panel.qml` and `QuickShare.noteDevices` —
  plan 008's remaining work.
- `backend/` — byte-identical to upstream.
- The device-name modes and the rename lifecycle — plans 022 and 023.

## Git workflow

- Branch: `advisor/024-sanitiser-hole-and-contract`
- Conventional commits; `fix:` for Steps 1–3, `docs:` for Step 4 if it lands as
  a documentation change. Keep them as separate commits — one is a fix and one
  is a decision.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Sanitise the hostname where it enters

```qml
    onLoaded: root.systemHostname = Model.displayName(String(text() || ""), 64)
```

Sanitising at ingestion rather than at the render site is deliberate and matches
the reasoning `displayName` exists for: there is one ingestion point and several
sinks, some of which belong to the kit.

**Verify**: `grep -c 'Model.displayName(String(text' Service.qml` → `1`;
`node tests/service-state.test.js` → exit 0.

### Step 2: Confirm the advertised name is unaffected

`resolveDeviceName` already runs the hostname through `displayName`, so this is
now applied twice. `displayName` must be idempotent for that to be safe.

**Verify**: `node -e "const M=require('./Model.js'); const a=M.displayName('<b>x</b>'); console.log(JSON.stringify(a), JSON.stringify(M.displayName(a)), a===M.displayName(a) ? 'IDEMPOTENT' : 'NOT IDEMPOTENT')"`
→ prints `IDEMPOTENT`. If it does not, STOP — double sanitisation would corrupt
names further and the fix belongs at one layer only.

### Step 3: Test the hole is closed

Add to `tests/model.test.js`:

```js
// The hostname reaches a kit Button label, and the kit renders labels with
// Qt's default AutoText. Sanitising has to happen where the value enters,
// because the render site is not ours to fix.
assert.equal(Model.displayName("<b>host</b>", 64), "bhost/b")
assert.equal(Model.displayName(Model.displayName("<b>host</b>", 64), 64), "bhost/b",
  "sanitising is idempotent, so applying it at ingestion and again in resolveDeviceName is safe")
```

(Adjust the expected strings if Step 4 changes the escaping rule — write this
test *after* Step 4 is decided, or write it to match whatever ships.)

**Verify**: `node tests/model.test.js` → exit 0.

### Step 4: Settle the contract — DECISION REQUIRED

`ROBUSTNESS.md` says names "must render literally". `displayName` deletes `<`
and `>`. These cannot both be true. Two coherent resolutions:

**(A) Amend the document to describe what ships.** Change item 10 to
"must not execute markup or commands, and must not be able to alter the panel's
layout". Cost: a device legitimately named `<b>Phone</b>` still displays as
`bPhone/b`, silently corrupted. Benefit: no behaviour change, no risk, and the
security property that actually matters is stated accurately.

**(B) Escape instead of deleting, so names really do render literally.**
Convert `&`, `<` and `>` to entities and set `textFormat: Text.RichText` at the
sinks. Cost: it requires controlling every sink — and **three of them belong to
the UI kit, which this repo cannot edit**. Without that, escaping makes things
*worse*: an `AutoText` sink would render `&lt;b&gt;` as `<b>` while a
`PlainText` sink shows the raw entity.

**Recommendation: (A).** Option (B) is not reachable while `Button.text` and
`PanelHero.title`/`meta` are `AutoText` in a package this repo does not own. Do
not attempt (B) here.

Also note, and record rather than fix: `displayName` does not touch `&`. Qt's
`mightBeRichText()` heuristic may treat a leading `&lt;` entity as rich text, in
which case a name containing `&lt;b&gt;` survives sanitisation and could still
reach an `AutoText` sink as markup. **This was not verified against the shipped
Qt build.** Do not add an `&` strip on the strength of a recalled heuristic —
either verify it against the installed Qt and then fix it, or write it down as
an open question in `ROBUSTNESS.md`.

If (A): amend item 10 and add one line noting that `<` and `>` are removed from
remote-supplied names at ingestion, with `Model.displayName` named as the choke
point.

**Verify**: `grep -c 'render literally' ROBUSTNESS.md` → `0` if (A) landed;
`node tests/model.test.js` → exit 0.

### Step 5: Record the coverage

`ROBUSTNESS.md`'s "Automated coverage" paragraph enumerates what the suites
cover and was not extended when `displayName` arrived. Add name sanitisation to
that list, naming the ingestion points it covers (`upsertDevice`,
`resolveDeviceName`, the hostname) and the ones it does not yet
(`QuickShare.noteDevices`, per plan 008).

**Verify**: `grep -ci 'sanitis' ROBUSTNESS.md` → at least `1`.

## Test plan

- Two assertions in `tests/model.test.js`: the hostname case and idempotence.
- Idempotence is the load-bearing one, because Step 1 makes the hostname pass
  through `displayName` twice.
- If Step 4 lands as (A), the existing `"bPhone/b"` assertions stay and are now
  *correct by contract* rather than freezing a divergence.

## Done criteria

ALL must hold:

- [ ] `grep -c 'Model.displayName(String(text' Service.qml` returns `1`
- [ ] `displayName` is idempotent (verified by the Step 2 command)
- [ ] `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` exits 0
- [ ] `ROBUSTNESS.md` and `Model.js` no longer contradict each other
- [ ] No file under `/usr/share/omarchy/` was modified
- [ ] `git diff --stat backend/` shows no changes
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `displayName` turns out **not** to be idempotent. Then Step 1 is the wrong
  layer; report and stop rather than sanitising twice.
- You are inclined to take option (B) and escape. It needs control of sinks in a
  package this repo must not edit; if you believe there is a way, write it up
  rather than implementing it.
- You are tempted to add an `&` strip based on the `mightBeRichText` note. Verify
  against the installed Qt first, or record it as an open question.
- You find yourself editing anything under `/usr/share/omarchy/`.
- The maintainer prefers (B) over (A). That is their call, and it changes this
  plan substantially — stop and get it in writing.

## Maintenance notes

- The rule: **remote-supplied text is neutralised where it enters the model**,
  never at the render site, because several sinks belong to the shared UI kit.
  The ingestion points are `Model.upsertDevice`, `Model.resolveDeviceName`, the
  hostname `FileView`, and — still outstanding per plan 008 —
  `QuickShare.noteDevices`.
- `displayName` is now applied twice to the hostname by design. Keep it
  idempotent; a future change that appends rather than replaces would break that
  quietly.
- Worth filing upstream to Omarchy: `Ui/Button.qml` and `Ui/PanelHero.qml` render
  caller-supplied text with `AutoText`. Fixing it there would cover every plugin,
  not just this one.
