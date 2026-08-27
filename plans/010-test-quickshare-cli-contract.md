# Plan 010: Cover the Quick Share CLI contract with tests

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
- **Risk**: LOW — new test file only
- **Depends on**: `plans/009-pin-quickshare-cli.md`
- **Category**: tests
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

`QuickShare.qml` is an entire second protocol engine — 224 lines — with **zero
direct test coverage**. `tests/panel-state.test.js` and
`tests/service-state.test.js` stub it as a call-logger; those stubs verify that
`Panel.qml` and `Service.qml` *call* the engine, and can verify nothing about
what the engine does.

The untested logic is unusually brittle by construction. The engine drives an
external CLI and recovers two critical values from its **human-readable stderr**:
the confirmation PIN the user must match on their phone, and the transfer
progress. It then maps the process's **exit codes** to user-facing verdicts.
Both are pinned to a third-party binary's presentation layer.

Two concrete failure modes with no error path today:

- If the PIN line's wording changes upstream, the regex stops matching, and the
  user stares at "Connecting…" while the phone waits for a code the panel never
  shows. Nothing logs, nothing errors.
- If the exit-code contract changes, a failed transfer reports **"Sent"**.

Plan 009 pins the CLI revision, which is what makes fixtures meaningful — that
is why this plan depends on it.

## Current state

File: `QuickShare.qml`. Four functions are pure enough to extract and test
(they only read arguments and write `root` properties):

`noteSendLine` — the stderr parser:

```qml
  function noteSendLine(line) {
    var text = String(line || "")
    var pin = text.match(/\(PIN\s+([^)]+)\)/)
    if (pin) { transferPin = pin[1]; statusText = "Waiting for " + transferPeer + " to accept"; return }
    var pct = text.match(/^\s*(\d{1,3})%\s*$/)
    if (pct) {
      progress = Math.max(0, Math.min(1, Number(pct[1]) / 100))
      statusText = "Sending"
      return
    }
    if (text.indexOf("Sent") >= 0 && text.indexOf("file") >= 0) progress = 1
  }
```

`finishSend` — the exit-code mapping:

```qml
  function finishSend(code) {
    pendingPaths = []
    transferPin = ""
    if (code === 0) {
      progress = 1
      viewState = "success"
      statusText = "Sent"
      return
    }
    if (code === 130) { viewState = "nearby"; statusText = "Cancelled"; selectedDevice = null; return }
    viewState = "error"
    errorText = code === 2
      ? "Declined by " + transferPeer + ", or it stopped responding."
      : "Quick Share could not send to " + transferPeer + "."
    statusText = errorText
  }
```

`noteDevices` — parses the CLI's `devices --json` output into the device list.
`noteDependencies` — parses `scripts/dependencies.sh --json`.

**The CLI's actual contract**, as documented by its author and observed at the
pinned revision:

- `qs devices --json` prints a JSON array to **stdout**; each element has
  `name`, `id` (which is `"ip:port"`), `ip`, `port`, `type` (one of `phone`,
  `tablet`, `computer`, `device`).
- Everything about a transfer goes to **stderr** as prose.
- When stderr is not a TTY, progress is emitted as a bare percentage on its own
  line, at 10% granularity: `10%`, `20%`, …
- The PIN appears inside a line of the form `Waiting for <name> to accept…  (PIN 1234)`.
- Completion prints a line containing `Sent N file(s) to <name>`.
- Exit codes: `0` sent, `2` declined / timed out / no device found, `130`
  cancelled, `1` error.

**The harness to copy**: `tests/service-state.test.js` extracts functions out of
QML source text and runs them in a `vm` sandbox against a stubbed context. Read
its `extractFunction` helper and its context-building block before writing
anything — the same technique applies here unchanged, because the four functions
above touch only `root` properties that the sandbox can provide.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| New tests | `node tests/quickshare-state.test.js` | pass line, exit 0 |
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |

## Scope

**In scope**:
- `tests/quickshare-state.test.js` (create)
- `.github/workflows/ci.yml` — register the new suite

**Out of scope** (do NOT touch):
- `QuickShare.qml`. This plan **characterises** current behaviour; it does not
  change it. Plans 011 and 013 change the engine, and they rely on these tests
  existing first. If a test reveals a bug, write the test to assert what the code
  does today, mark it clearly with a comment naming the suspected bug, and report
  it — do not fix it here.
- `Panel.qml`, `Service.qml`, `Model.js`.

## Git workflow

- Branch: `advisor/010-test-quickshare-cli-contract`
- Conventional commits; `test:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Stand up the harness

Create `tests/quickshare-state.test.js` following
`tests/service-state.test.js`'s structure: read `QuickShare.qml` as text,
extract the four functions by name, and run them in a `vm` context that provides
the `root` properties they write.

The context needs at least: `devices`, `selectedDevice`, `viewState`,
`statusText`, `errorText`, `progress`, `transferName`, `transferPeer`,
`transferPin`, `pendingPaths`, `available`, `depsChecked`, `missingDeps`, and a
`cursorRequested` stub.

Open with a header comment in this repo's register — full sentences explaining
why this file exists and what it is pinned to. State the `qs` revision the
fixtures were taken from (`a63bc7b3`, per plan 009), because that is what makes
them re-checkable when the pin moves.

**Verify**: `node tests/quickshare-state.test.js` → runs and exits 0 even with
no assertions yet.

### Step 2: Table-drive `noteSendLine`

Cases, each asserting the resulting `root` state:

1. `Waiting for Pixel to accept…  (PIN 1234)` → `transferPin === "1234"`.
2. A PIN line arriving twice with different values → assert what the code does
   today (the second overwrites the first). Comment that this is characterised,
   not endorsed.
3. `10%` → `progress === 0.1`; `100%` → `progress === 1`.
4. `  50%  ` (surrounding whitespace) → `progress === 0.5`.
5. `Sending 50% of 3 files` → **no** progress change, because the regex is
   anchored to a bare percentage. Characterise it and comment that a
   prefixed/suffixed percentage is not recognised.
6. `999%` → clamped to `1`.
7. `✓ Sent 3 file(s) to Pixel` → `progress === 1`.
8. A filename echoed in a line that happens to contain both `Sent` and `file` —
   for example `Sent-invoice-file.pdf` → characterise that this also sets
   progress to 1, and comment that it is a false positive.
9. Empty string, `null`, and a line of unrelated prose → no state change.

**Verify**: `node tests/quickshare-state.test.js` → all pass.

### Step 3: Table-drive `finishSend`

Cases over `{0, 2, 130, 1, 127}`:

- `0` → `viewState === "success"`, `statusText === "Sent"`, `progress === 1`.
- `2` → `viewState === "error"` and `errorText` names the peer.
- `130` → `viewState === "nearby"`, `statusText === "Cancelled"`,
  `selectedDevice === null`.
- `1` and `127` → `viewState === "error"` with the generic message.
- Every case → `pendingPaths` is emptied and `transferPin` is cleared.

Add a comment on the `130` case noting that `130` is a *shell* convention for
128+SIGINT and may not be what the process reports through QProcess — plan 013
addresses that, and this test will need updating when it does.

**Verify**: `node tests/quickshare-state.test.js` → all pass.

### Step 4: Cover `noteDevices` against malformed input

- A well-formed two-element array → two devices, sorted by alias.
- Non-JSON text → `devices` becomes `[]`, no throw.
- `[]` → `devices` becomes `[]`.
- `null` / empty string → no throw.
- An element missing `name` → alias falls back to `Unknown`.
- An element with an **empty `id`** → characterise that it is currently kept and
  becomes selectable; comment that this feeds an empty `--to` argument.
- An element whose `name` contains markup → characterise current behaviour. If
  plan 008 has landed, this asserts the sanitised form instead; note which case
  you wrote.

**Verify**: `node tests/quickshare-state.test.js` → all pass.

### Step 5: Cover `noteDependencies`

- Valid payload with all `present: true` → `available === true`,
  `missingDeps === []`, `depsChecked === true`.
- Valid payload with `qs` absent → `available === false` and `missingDeps`
  contains `qs`.
- Non-JSON → `depsChecked === true` and `missingDeps` is **unchanged**.
  Characterise this and comment that it means a probe failure is
  indistinguishable from "the CLI is simply missing" — plan 011 fixes it.

**Verify**: `node tests/quickshare-state.test.js` → all pass.

### Step 6: Register in CI

Add `tests/quickshare-state.test.js` to the frontend test step in
`.github/workflows/ci.yml`, alongside the three existing Node suites.

**Verify**: `python3 -c "print(open('.github/workflows/ci.yml').read().count('quickshare-state.test.js'))"` → `1`.

## Test plan

- New file `tests/quickshare-state.test.js`, ~30 assertions across the four
  functions.
- Structural pattern: `tests/service-state.test.js`'s `extractFunction` + `vm`
  sandbox.
- Several cases deliberately characterise behaviour that is arguably wrong
  (cases 2, 5, 8 in Step 2; the empty-`id` case in Step 4; the non-JSON case in
  Step 5). Each must carry a comment saying so and naming the plan that
  addresses it. A characterisation test that silently looks like an endorsement
  is worse than no test.
- Verification: `node tests/quickshare-state.test.js` → all pass.

## Done criteria

ALL must hold:

- [ ] `node tests/quickshare-state.test.js` exits 0
- [ ] `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` exits 0
- [ ] `git diff --stat QuickShare.qml` shows **no** changes
- [ ] The new file's header names the `qs` revision the fixtures came from
- [ ] Every characterisation-of-a-suspected-bug case carries a comment naming it
- [ ] `.github/workflows/ci.yml` runs the new suite
- [ ] `git status --porcelain` lists only `tests/quickshare-state.test.js` and `.github/workflows/ci.yml`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The four functions do not match the excerpts in "Current state".
- `tests/service-state.test.js` has no reusable `extractFunction` helper.
  Extending the technique is fine; rewriting the existing harness is not.
- You conclude a test can only pass if `QuickShare.qml` changes. That is the
  signal to characterise instead and report — this plan must not modify the
  engine.
- Plan 009 has not landed, so the CLI revision is unpinned. The fixtures would be
  written against a moving target; say so and stop.

## Maintenance notes

- These fixtures are pinned to one `qs` revision. When `QS_REV` in
  `scripts/dependencies.sh` is bumped, re-run this suite against the new binary's
  real output before shipping — that is the whole reason the header records the
  revision.
- A reviewer should look for characterisation cases that lost their explanatory
  comment; without it, the next reader will assume the behaviour is intended.
- Plans 011 and 013 change engine behaviour and will legitimately need some of
  these assertions updated. That is expected — the tests exist so those changes
  are visible, not so they are blocked.
