# Plan 007: Export and test the fork's two `Model.js` helpers

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- Model.js tests/model.test.js`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

`Model.js` is the one file in this plugin that is pure, dependency-free
JavaScript, `require`-able from Node and therefore genuinely unit-testable —
everything else is QML that the test suite can only regex or partially sandbox.
Every function in it is exported at the bottom of the file and covered in
`tests/model.test.js`.

Except two. `modeIn` and `quickShareIconFor` were added with the Quick Share
pane and left out of the export list. QML imports the namespace directly, so the
plugin works and nothing complains — which is precisely why the omission is easy
to miss. The consequence is that the two newest, least-exercised pure functions
in the codebase are the only ones Node cannot reach, so they have no path to
coverage at all.

`modeIn` is not a trivial helper. It is the single decision point for which pane
the entire plugin opens in, and it reads persisted state out of `shell.json`. Its
sibling `receiverEnabledIn` reads the same structure and is tested exhaustively —
because a default-vs-persisted drift bug in exactly that area shipped once
before and is recorded in `CHANGELOG.md`. `modeIn` is one config-shape edge case
away from repeating it.

## Current state

File: `Model.js`, ~280 lines, plain ES5-flavoured JavaScript (`var`, `function`,
no modules) so QML's engine can load it.

The two unexported functions:

```js
function modeIn(entry) {
  var mode = entry && entry.settings ? String(entry.settings.mode || "") : ""
  return mode === "quickshare" ? "quickshare" : "localsend"
}
```

```js
function quickShareIconFor(type) {
  if (type === "phone" || type === "tablet") return iconFor("mobile")
  return iconFor("desktop")
}
```

The export line, the **last line of the file** — note both names are absent:

```js
if (typeof module !== "undefined") module.exports = { parseLine, upsertDevice, snapshotDevices, iconFor, formatBytes, incomingSummary, enqueueIncoming, removeIncoming, currentIncoming, outgoingCommand, viewAfterOutgoing, barEntry, hasStringBarEntry, promoteStringBarEntry, receiverEnabledIn, helperVersionMatches, compareVersions, helperSatisfies, helperUpdateAvailable, manifestVersion, manifestMinHelperVersion }
```

The sibling function whose test coverage is the pattern to copy:

```js
function receiverEnabledIn(entry) {
  return !!entry && entry.settings.receiverEnabled !== false
}
```

`modeIn`'s consumer, in `Service.qml`:

```qml
  readonly property string mode: Model.modeIn(configEntry)
  readonly property bool quickShareMode: mode === "quickshare"
```

`configEntry` comes from `Model.barEntry(shell.shellConfig, manifestPluginId)`,
which returns either `null` or an object of shape `{id, settings}`. **`settings`
may be an empty object**, and `barEntry` can return `null` outright when the
plugin has no bar entry — so `modeIn` must tolerate `null`, `{}`, and
`{settings:{}}`.

The existing test style in `tests/model.test.js` — flat top-level assertions,
no framework, `require` at the top, and the file ends by printing a pass line:

```js
const layoutOff = {version:1, bar:{layout:{left:[{id:"omarchy.menu"}], center:[], right:[{id:"b.omadoro"},{id:"oma.nearby",receiverEnabled:false}]}}, plugins:[]}
assert.deepEqual(Model.barEntry(layoutOff, "oma.nearby"), {id:"oma.nearby", settings:{receiverEnabled:false}})
assert.equal(Model.receiverEnabledIn(Model.barEntry(layoutOff, "oma.nearby")), false)
```

Note the plugin-id strings in those fixtures are *arguments* to functions that
take `pluginId` as a parameter — they are correctly parameterised and need no
change.

**Conventions:** `Model.js` uses `var` and `function` declarations, not `const`
or arrow functions — match it. `tests/model.test.js` uses `const` and modern
syntax, because it runs under Node only.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Model tests | `node tests/model.test.js` | prints `Model tests passed`, exit 0 |
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |
| Syntax check | `node --check Model.js` | exit 0 |

## Scope

**In scope**:
- `Model.js` — the export line only
- `tests/model.test.js` — new assertions

**Out of scope** (do NOT touch):
- The bodies of `modeIn` and `quickShareIconFor`. This plan makes them testable
  and tests them. If a test reveals a genuine bug, STOP and report rather than
  changing behaviour — a behaviour change needs its own review.
- `iconFor`, which `quickShareIconFor` delegates to. It is already exported and
  tested.
- The `"oma.nearby"` fixture strings elsewhere in `tests/model.test.js` — they
  are correctly parameterised arguments, not stale identity.
- `Service.qml`, `Panel.qml`, `QuickShare.qml`.

## Git workflow

- Branch: `advisor/007-export-and-test-model-helpers`
- Conventional commits; `test:` is right (the export is in service of the tests).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add both names to the export list

Append `modeIn` and `quickShareIconFor` to the object on the last line of
`Model.js`. Keep the single-line format — do not reflow it to multiple lines.

**Verify**: `node -e "const M=require('./Model.js'); console.log(typeof M.modeIn, typeof M.quickShareIconFor)"`
→ prints `function function`.

### Step 2: Test `modeIn` across the config shapes it actually receives

Add to `tests/model.test.js`, near the existing `receiverEnabledIn` block so the
two read together:

```js
// modeIn decides which pane the whole plugin opens in, and it reads persisted
// state out of shell.json. Its sibling receiverEnabledIn is covered against the
// same config shapes because a default-vs-persisted drift bug shipped there
// once; these cases are the equivalent guard.
assert.equal(Model.modeIn(null), "localsend", "no bar entry falls back to the pane that needs no build step")
assert.equal(Model.modeIn(undefined), "localsend")
assert.equal(Model.modeIn({}), "localsend", "an entry with no settings object must not throw")
assert.equal(Model.modeIn({settings:{}}), "localsend", "an unset mode is localsend")
assert.equal(Model.modeIn({settings:{mode:"quickshare"}}), "quickshare", "a persisted quickshare mode must read back")
assert.equal(Model.modeIn({settings:{mode:"localsend"}}), "localsend")
assert.equal(Model.modeIn({settings:{mode:"QuickShare"}}), "localsend", "the comparison is case-sensitive by design")
assert.equal(Model.modeIn({settings:{mode:"nonsense"}}), "localsend", "an unknown mode falls back rather than showing an empty pane")
assert.equal(Model.modeIn({settings:{mode:null}}), "localsend")
assert.equal(Model.modeIn({settings:{mode:0}}), "localsend")
```

Then add the round-trip case that mirrors how `Service.qml` actually calls it —
through `barEntry`, not with a hand-built object:

```js
const quickShareLayout = {version:1, bar:{layout:{right:[{id:"x.nearby", mode:"quickshare"}]}}, plugins:[]}
assert.equal(Model.modeIn(Model.barEntry(quickShareLayout, "x.nearby")), "quickshare",
  "a mode persisted in the bar entry must survive the barEntry round trip")
const bareLayout = {version:1, bar:{layout:{right:["x.nearby"]}}, plugins:[]}
assert.equal(Model.modeIn(Model.barEntry(bareLayout, "x.nearby")), "localsend",
  "a string bar entry has no settings and must default cleanly")
```

The second of those is the one that matters: a bar entry can be a bare string
rather than an object, and `barEntry` normalises it to `{id, settings:{}}`.

**Verify**: `node tests/model.test.js` → `Model tests passed`, exit 0.

### Step 3: Test `quickShareIconFor`

```js
// qs reports phone/tablet/computer/device; the LocalSend helper reports
// mobile/web/server/headless. This maps the former onto the shared icon set.
assert.equal(Model.quickShareIconFor("phone"), Model.iconFor("mobile"))
assert.equal(Model.quickShareIconFor("tablet"), Model.iconFor("mobile"))
assert.equal(Model.quickShareIconFor("computer"), Model.iconFor("desktop"))
assert.equal(Model.quickShareIconFor("device"), Model.iconFor("desktop"))
assert.equal(Model.quickShareIconFor(""), Model.iconFor("desktop"), "an absent type falls back rather than rendering blank")
assert.equal(Model.quickShareIconFor(undefined), Model.iconFor("desktop"))
```

Assert against `Model.iconFor(...)` rather than against literal glyph
characters: the glyphs are private-use-area codepoints that are easy to corrupt
in an editor, and the relationship is what the function promises.

**Verify**: `node tests/model.test.js` → exit 0.

### Step 4: Confirm the tests are not vacuous

Temporarily change `modeIn`'s return to always `"localsend"`, run
`node tests/model.test.js`, and confirm it **fails**. Restore the function
exactly as it was.

**Verify**: the suite fails with the function stubbed and passes when restored.
Report both observations. Confirm `git diff Model.js` afterwards shows only the
export-line change.

### Step 5: Confirm nothing else regressed

**Verify**: `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js`
→ exit 0, three pass lines.

## Test plan

- Extend `tests/model.test.js` with the assertions in Steps 2 and 3.
- Structural pattern: the existing `receiverEnabledIn` / `barEntry` block in the
  same file — flat top-level `assert` calls, fixtures declared inline.
- Coverage: `modeIn` over null/undefined/empty/valid/unknown/wrong-case/non-string
  inputs plus two `barEntry` round trips; `quickShareIconFor` over all four `qs`
  device types plus two absent-value cases.
- Step 4 proves the assertions bite.
- Verification: `node tests/model.test.js` → all pass.

## Done criteria

ALL must hold:

- [ ] `node -e "const M=require('./Model.js'); if(typeof M.modeIn!=='function'||typeof M.quickShareIconFor!=='function') process.exit(1)"` exits 0
- [ ] `node tests/model.test.js` exits 0
- [ ] `node tests/panel-state.test.js && node tests/service-state.test.js` exits 0
- [ ] `git diff --stat Model.js` shows exactly 1 line changed
- [ ] Stubbing `modeIn` makes `node tests/model.test.js` fail (verified in Step 4, then reverted)
- [ ] `git status --porcelain` lists only `Model.js` and `tests/model.test.js`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The export line or either function body does not match the excerpts in
  "Current state".
- Any assertion in Step 2 or 3 fails against the **unmodified** functions. That
  means a real behaviour bug exists — report the failing case and stop. Do not
  change `modeIn` or `quickShareIconFor` to make a test pass; the export is the
  only source change this plan authorises.
- `Model.js` turns out to be imported somewhere that would break if the export
  object grows (it should not — it is additive), for instance a test asserting
  the exact set of exported keys.

## Maintenance notes

- Every function added to `Model.js` must be added to the export line in the
  same change. That line is the boundary between "testable" and "invisible to
  CI", and it is easy to forget because QML does not need it.
- A reviewer should check that the `Model.js` diff really is one line. Any
  behaviour change smuggled in alongside the export defeats the point of the
  plan.
- Related and deliberately deferred: `iconFor`, `formatBytes`, `incomingSummary`
  and `compareVersions` are exported but thinly covered. Worth a follow-up, but
  they are long-standing upstream code rather than new fork surface, so they are
  lower priority than these two.
