# Plan 003: Stop LocalSend columns rendering inside the Quick Share pane

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
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

This plugin's popup has two panes — LocalSend and Quick Share — chosen by two
buttons at the top. Each pane's columns are gated on `!root.quickShareMode` so
only one pane's content renders at a time.

Two of those ten gates are missing parentheses. In JavaScript and QML, `&&`
binds tighter than `||`, so `!mode && a || b` parses as `(!mode && a) || b` —
the second condition escapes the mode guard entirely. The result is that the
LocalSend "receiving" column and the LocalSend "success/error" column render
underneath the Quick Share pane whenever LocalSend enters those states.

It is worse than a cosmetic overlap. Keyboard activation in Quick Share mode
never routes to `finishTerminal()`, so a LocalSend error column that appears
this way **cannot be dismissed from the keyboard** and stays pinned to the
bottom of the Quick Share pane. If Quick Share is also in `error`, two "Done"
buttons render and the shared `selectedIndex === 0` highlights both.

## Current state

File: `Panel.qml` — the bar widget and popup. The bar instantiates one per
monitor, so it is a pure view: it owns no process and no transfer state.

The popup body is a `Column` holding one child `Column` per view state. Eight of
the ten mode gates are correct; these are the two that are not.

Grep for `visible: !root.quickShareMode` and you will find exactly ten lines.
The two defective ones read:

```qml
          visible: !root.quickShareMode && root.viewState==="sending"||root.viewState==="receiving"; width:parent.width; spacing:Style.space(8)
```

```qml
          visible: !root.quickShareMode && root.viewState==="success"||root.viewState==="error"; width:parent.width; spacing:Style.space(8)
```

For contrast, a correct one — it needs no parentheses because it uses only `&&`:

```qml
          visible: !root.quickShareMode && root.viewState === "incoming" && root.incoming; width:parent.width; spacing:Style.space(8)
```

**Repo conventions that apply here:**

- `Panel.qml` writes these gate lines compactly, with `;`-separated properties
  on one line and no spaces around `===` inside the compact blocks. Match the
  surrounding line exactly; change only the grouping.
- The test suite for this file is `tests/panel-state.test.js`. It works in two
  modes: it `vm`-evaluates functions extracted from the QML source, and it runs
  regex assertions against the raw source text. A regex assertion here is the
  appropriate tool, because a `visible:` binding is a property binding that the
  function extractor cannot reach.
- Existing regex assertions in that file look like:
  ```js
  assert.match(source, /id:nearbyActions/,
    "secondary Nearby actions should share one compact row")
  ```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Panel tests | `node tests/panel-state.test.js` | prints `panel state tests passed`, exit 0 |
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |
| Count the gates | `grep -c 'visible: !root.quickShareMode' Panel.qml` | `10` |

There is no QML compiler or `qmllint` available on the development machine, so
the Node suites plus a careful read are the available verification. Do not
attempt to install one.

## Scope

**In scope**:
- `Panel.qml` — only the two `visible:` bindings named above
- `tests/panel-state.test.js` — add a regression assertion

**Out of scope** (do NOT touch):
- The eight other `visible: !root.quickShareMode` gates — they are correct.
- `moveCursor` / `activateCursor` — plan 004 changes those functions. Editing
  them here causes a conflict.
- The Quick Share columns' own `visible:` bindings (`root.quickShareMode && ...`)
  — they use only `&&` and are correct.
- `Service.qml`, `QuickShare.qml`, `Model.js`.

## Git workflow

- Branch: `advisor/003-fix-visibility-precedence`
- Conventional commits; `fix:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Parenthesise the two defective gates

Change the `sending`/`receiving` gate to:

```qml
          visible: !root.quickShareMode && (root.viewState==="sending"||root.viewState==="receiving"); width:parent.width; spacing:Style.space(8)
```

Change the `success`/`error` gate to:

```qml
          visible: !root.quickShareMode && (root.viewState==="success"||root.viewState==="error"); width:parent.width; spacing:Style.space(8)
```

Change nothing else on those lines.

**Verify**: `grep -c 'visible: !root.quickShareMode' Panel.qml` → `10`, and
`grep -c 'visible: !root.quickShareMode && (' Panel.qml` → `2`.

### Step 2: Add a regression assertion

In `tests/panel-state.test.js`, alongside the other source-text assertions near
the top of the file, add:

```js
// `&&` binds tighter than `||`, so a mode gate written as
// `!quickShareMode && a || b` lets `b` escape the guard entirely and renders a
// LocalSend column inside the Quick Share pane. Every gate that ORs two view
// states must parenthesise them.
for (const states of [`"sending"||root.viewState==="receiving"`, `"success"||root.viewState==="error"`]) {
  assert.match(source, new RegExp(`visible: !root\\.quickShareMode && \\(root\\.viewState===${states.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\)`),
    `the ${states} gate must parenthesise its OR so the mode guard covers both states`)
}
assert.doesNotMatch(source, /visible: !root\.quickShareMode && root\.viewState==="[a-z]+"\|\|/,
  "a mode gate must never OR a second view state outside its parentheses")
```

If the escaping above proves awkward, a simpler equivalent is acceptable as long
as it asserts both the positive form and the `doesNotMatch` negative form — the
negative one is the load-bearing half, because it fails if anyone reintroduces
the pattern anywhere in the file.

**Verify**: `node tests/panel-state.test.js` → `panel state tests passed`, exit 0.

### Step 3: Confirm the assertion actually catches the bug

Temporarily revert one parenthesis pair (remove the `(` and `)` you added to the
`success`/`error` gate), run `node tests/panel-state.test.js`, and confirm it
**fails**. Then restore the parentheses and confirm it passes again.

**Verify**: the test fails with the parentheses removed and passes with them
restored. Report both observations.

### Step 4: Confirm nothing else regressed

**Verify**: `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js`
→ exit 0, three pass lines.

## Test plan

- Extend `tests/panel-state.test.js` with the assertions in Step 2 — a positive
  match for each corrected gate and one negative match that forbids the pattern
  anywhere in the file.
- Structural pattern: the existing source-text assertions in the same file
  (`assert.match(source, /id:nearbyActions/, "...")`).
- Step 3 is the proof the test is real rather than vacuous. Do not skip it.
- Verification: `node tests/panel-state.test.js` → all pass.

## Done criteria

ALL must hold:

- [ ] `grep -c 'visible: !root.quickShareMode && (' Panel.qml` returns `2`
- [ ] `grep -c 'visible: !root.quickShareMode' Panel.qml` returns `10`
- [ ] `node tests/panel-state.test.js` exits 0
- [ ] `node tests/model.test.js && node tests/service-state.test.js` exits 0
- [ ] Removing one added parenthesis pair makes `node tests/panel-state.test.js` fail (verified in Step 3, then reverted)
- [ ] `git status --porcelain` lists only `Panel.qml` and `tests/panel-state.test.js`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `grep -c 'visible: !root.quickShareMode' Panel.qml` does not return `10`, or
  the two defective lines do not match the excerpts in "Current state".
- The test in Step 3 passes even with a parenthesis pair removed — the assertion
  is vacuous and must be rewritten before the plan can be called done.
- Fixing this appears to require changing `activateCursor` so the LocalSend
  terminal column can be dismissed in Quick Share mode. It does not: this plan
  stops those columns from rendering there at all. Routing is plan 004.

## Maintenance notes

- Any new pane-gated column added to `Panel.qml` must parenthesise a multi-state
  condition. The negative assertion added in Step 2 enforces this repo-wide.
- A reviewer should confirm the change is grouping-only — no view state added,
  removed, or renamed on those two lines.
- Related but deliberately out of scope: when a LocalSend transfer request
  arrives while the Quick Share pane is selected, the accept/decline column is
  correctly hidden but the user still gets a notification and an "Incoming" hero
  with no way to act on it. That is a separate design question about whether an
  inbound request should force a pane switch, and it is tracked as its own
  finding rather than fixed here.
