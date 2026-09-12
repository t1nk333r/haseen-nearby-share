# Plan 025: A receive engine for the Quick Share pane

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If a
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat ed645de..HEAD -- QuickShare.qml Service.qml Panel.qml Model.js scripts/dependencies.sh patches/qs-events.patch`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: HIGH — this is the consent boundary. A path that accepts without an
  answer is worse than no receive at all, which is why the pane shipped without
  it for as long as it did.
- **Depends on**: `plans/019-spike-quickshare-receive.md` (the protocol), and the
  build change that carries it (`patches/qs-events.patch`, in `ed645de`)
- **Category**: feature
- **Planned at**: commit `ed645de`, 2026-09-12

## Why this matters

Quick Share sends only. A phone cannot push a photo to this desktop, which is
the canonical use of the protocol. The blocker was never the UI: `qs receive`
had no way to ask a frontend for consent — without a TTY it refuses or
auto-accepts everything on the LAN.

That is fixed. `patches/qs-events.patch`, built by
`scripts/dependencies.sh`, gives `qs receive --events`: a `request` event when
someone wants to send, `accept`/`decline` on stdin, a consent timeout, EOF
declining everything pending, and `--events --yes` refused outright.
`plans/spikes/019-quickshare-receive/PROTOCOL.md` is the specification and
`FINDINGS.md` records what is and is not verified (no phone was available).

What is missing is the consumer. This plan is it, and it is deliberately the
*middle* of the feature: the CLI side already exists and is tested, and the
queue, the consent column and the reader template already exist on this side.

## Current state

The pieces that make this medium rather than large. Verify each before writing
code; a mismatch is a STOP.

**The request queue, protocol-agnostic already** — `Model.js`:

- `function enqueueIncoming(queue, request)` — `Model.js:48`
- `function removeIncoming(queue, requestId)` — `Model.js:61`
- `function currentIncoming(queue)` — `Model.js:67`

**The consent column, wired and tested for LocalSend** — `Panel.qml`:

```qml
  readonly property var incomingQueue: engine ? engine.incomingQueue : []
  ...
  Text { visible:root.incomingQueue.length>1; ... text:(root.incomingQueue.length-1)+(... " more request" ...) }
  Button { ... text:"Decline"; ... onClicked:root.declineIncoming() }
  Button { ... text:"Accept";  ... onClicked:root.acceptIncoming() }
```

`Panel.qml:83` and `Panel.qml:659-662`; keyboard routing at `Panel.qml:343`.

**The reader template, in the same idiom this engine needs** — `Service.qml`:

```qml
    backend.write(JSON.stringify(command) + "\n")     // Service.qml:403
    stdinEnabled: true                                 // Service.qml:853
    stdout: SplitParser { onRead: … }                  // Service.qml:854
```

**The engine's vocabulary** — `QuickShare.qml` mirrors `Service.qml`'s
viewState strings (`nearby | target | sending | success | error`) on purpose, so
the panel switches on one set of strings for both protocols.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| The CLI's new surface | `~/.config/omarchy/plugins/t1nk33r.nearby-share/bin/nearby-qs receive --help` | lists `--events` and `--consent-timeout` |
| Refusal check | `… receive --events --yes` | exit 2, reason on stderr |
| Handshake without a phone | `… receive --events --out /tmp/x </dev/null` | one `ready` line on stdout, exit 0 on EOF |
| Existing suites | `bash tests/all.sh` | pass line, exit 0 |
| New suite | `node tests/quickshare-receive.test.js` | pass line, exit 0 |

## Scope

**In scope**:

- `QuickShare.qml` — the receive engine: spawn, parse, answer, and expose
  `incomingQueue` / `acceptIncoming()` / `declineIncoming()` exactly as the
  pane already consumes them for LocalSend
- `tests/quickshare-receive.test.js` (create) and `.github/workflows/ci.yml`
- the docs that describe the pane (`README.md`, `CHANGELOG.md`)

**Out of scope** (do NOT touch):

- `patches/qs-events.patch` and the build — landed in `ed645de`
- `Model.js` — the queue is already protocol-agnostic; if it needs a change,
  that is a STOP and a plan of its own
- `Panel.qml` — it already draws the consent column and routes the keys. If it
  needs a change to consume this engine, say so and stop: that means the engine
  does not match the interface the LocalSend path already proved
- the LocalSend pane's own receive path

## The rules the engine must hold

These are the security property, restated as implementation rules. Each one gets
a test in Step 4.

1. **`accept` is sent only from the user's Accept action.** Not on a timer, not
   on reconnection, not on startup, not as a default. If the panel is not in
   front of a person, the answer is decline.
2. **Every other path declines**: the CLI's timeout (already implemented on the
   CLI side), the engine shutting down, the process dying, the panel closing
   with requests pending. The engine's own exit path must not leave a transfer
   hanging on a promise it can no longer keep — if the process is stopping, it
   declines what it is holding.
3. **A malformed or unrecognised event is ignored**, never enqueued and never
   answered. The CLI is a local binary, but this is still a parser over data
   that arrived from the network.
4. **The engine is one process for the session, owned by `Service.qml`.** The
   bar builds one `Panel.qml` per monitor (`AGENTS.md`), so anything that may
   exist only once belongs in the service; two engines would race for the port
   and each would answer the same request differently.

## Steps

### Step 1: Spawn and parse

Add the receive engine to `QuickShare.qml`: a `Process` running
`[binary, "--port", String(root.port), "receive", "--events",
"--out", <download dir>]` with `stdinEnabled: true` and a `SplitParser` over
stdout, in the shape `Service.qml` already uses for the LocalSend helper.

Parse each line as JSON and dispatch on `event`:

| Event | Action |
|---|---|
| `ready` | the engine is live; clear any previous error state |
| `request` | `enqueueIncoming(queue, {id, sender, files, total, pin})` and surface the queue to the panel |
| `progress` | update that request's progress in place |
| `done` | `removeIncoming(queue, id)`, record the path(s), and notify as the LocalSend path does |
| `failed` | `removeIncoming(queue, id)`; `reason: "timeout"` says so in the status text rather than reading like a refusal by the phone |

Runs only while the user has receive enabled — a toggle in the pane's settings
or a control in the panel, matching how the LocalSend receiver's
`receiverEnabled` works. Off by default if the LocalSend precedent is off by
default; follow it either way rather than inventing a third convention.

**Verify**: with the engine running and no phone, a non-TTY handshake — start
the process, observe `ready`, kill it, and confirm nothing is left in
`incomingQueue`.

### Step 2: Answer

`acceptIncoming()` and `declineIncoming()` write one JSON line each
(`{"command":"accept","id":…}` / `{"command":"decline","id":…}`) to the
process's stdin, exactly as `Service.qml:403` writes to the helper.

Guard both: an id that is not in the queue is not written. The CLI ignores an
unknown id anyway; this keeps the two ends from disagreeing about state.

**Verify**: stop the CLI's process while a request is pending (kill it between
`request` and the answer) and confirm the engine clears the queue and does not
write to a dead stdin.

### Step 3: Let the panel answer

Point the pane at the engine: `Panel.qml` reads `engine.incomingQueue`, its
Accept calls `engine.acceptIncoming()`, its Decline `engine.declineIncoming()`.
If the LocalSend path's names differ, match them — the pane must not learn a
second vocabulary.

**Verify**: with the engine running, `omarchy shell t1nk33r.nearby-share status`
(or the pane's own IPC) reports the queue; a request cannot be produced without
a phone, so this step's verification is the interface, not the flow.

### Step 4: Tests

`tests/quickshare-receive.test.js`, in the extract-and-sandbox style plan 010
established for `QuickShare.qml` (`tests/quickshare-state.test.js`), covering
the four rules above:

- a `request` event enqueues exactly one entry, with the fields the panel draws;
- `accept` is written **only** for the user action — no other function in the
  engine writes `"accept"`, asserted by scanning the extracted source for the
  literal;
- `decline` is written for a user decline, for an engine shutdown with a request
  pending, and for a process exit with a request pending;
- a malformed line, an unknown `event` value, and a `request` missing an `id`
  are all ignored without throwing and without an answer;
- `failed` with `reason: "timeout"` clears the queue and does not read like the
  phone refused.

**Verify**: `node tests/quickshare-receive.test.js` → all pass; and
`node tests/quickshare-state.test.js` still passes (the extraction technique is
shared, not copied twice).

### Step 5: Register and document

Add the suite to `.github/workflows/ci.yml` beside the others. Update the
README's Quick Share section: receive works now, with the consent prompt in the
panel, and say what is still unverified (the device-facing flow has not been
run against a phone). Add a CHANGELOG entry.

**Verify**: `python3 -c "print(open('.github/workflows/ci.yml').read().count('quickshare-receive.test.js'))"` → `1`.

## Test plan

- One new suite, the four rules above, in the plan-010 house style.
- A device-facing flow cannot be tested here: **no phone**. Every claim that
  needs one — that a `request` arrives, that an `accept` completes a transfer,
  that a phone's decline arrives as `Rejected` — is marked unverified in the
  README and in your report. `plans/spikes/019-quickshare-receive/FINDINGS.md`
  lists exactly which parts those are; do not claim more than it does.

## Done criteria

ALL must hold:

- [ ] `bash tests/all.sh` exits 0
- [ ] `node tests/quickshare-receive.test.js` exits 0 and is in CI
- [ ] No code path writes `"accept"` except the user action (asserted in the suite)
- [ ] `QuickShare.qml`, `Service.qml`, `Panel.qml`, `Model.js` are the only
      product files changed, and `patches/qs-events.patch` is untouched
- [ ] The receive engine runs only when receive is enabled, and is owned by the
      service, not the per-monitor widget
- [ ] `README.md` says what works and what remains unverified without a phone
- [ ] `git status --porcelain` lists only in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report (do not improvise) if:

- the CLI's `--events` surface does not match `PROTOCOL.md` — the patch and the
  protocol have drifted, and the protocol is the reviewed one;
- `Model.js`'s queue functions do not accept the same request shape the LocalSend
  path uses;
- `Panel.qml` needs a change beyond pointing at the engine — that means the
  engine interface is wrong, not the panel;
- you conclude the flow needs a phone to be written correctly. It does not:
  write it to the protocol, test the protocol, and say plainly which half is
  unverified.

## A known risk to settle before shipping

`plans/spikes/019-quickshare-receive/FINDINGS.md` records it in full: the phone
expects **both** peers to send `KEEP_ALIVE` frames every ~10 seconds and
terminates an idle connection without them, while `rqs_lib` only answers them.
A consent prompt is the first thing in this pane to hold the connection idle, so
a request can be dropped by the phone mid-prompt and reach the user as a request
that never arrived.

Settle it before shipping, one way or the other: patch the library's connection
loop to send its own keep-alives (a local patch plus a `[patch]` override in the
build, the way `qs-events.patch` is carried), or shorten the consent timeout to
sit well inside the phone's patience. Neither can be verified here — put it in
the same device-testing session as the rest of the "no phone" list.

## Maintenance notes

- The patch and `QS_REV` travel together. Moving the pin means re-checking
  `patches/qs-events.patch` against the new revision (`git apply` will say so,
  and `dependencies.sh` fails the build rather than shipping unpatched), then
  re-running plan 019's protocol notes against whatever changed.
- When a phone is available, the checks worth running first: does `request`
  arrive once per transfer, is the PIN present at that moment, does a decline
  reach the phone as a rejection rather than a timeout, and does the phone give
  up before the 60-second consent timeout does.
- The consent column is now shared by two protocols. If a third arrives, the
  queue is the seam to generalise — not the engine.
