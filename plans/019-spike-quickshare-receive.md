# Plan 019: Spike a JSON event protocol so Quick Share can receive

> **Executor instructions**: This is a **spike**, not a build. Its deliverable is
> a written protocol proposal, a throwaway prototype, and a decision document —
> not a shipped feature. Follow the steps, run every verification command, and
> honour the STOP conditions. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- QuickShare.qml Service.qml Model.js README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: L (coarse — spans an upstream CLI change)
- **Risk**: MED — auto-accept is a security boundary; a wrong design here is
  worse than no feature
- **Depends on**: `plans/009-pin-quickshare-cli.md`, `plans/010-test-quickshare-cli-contract.md`
- **Category**: direction
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

Quick Share currently **sends only**. That is the single largest asymmetry in the
product, and it is asymmetric in the direction users notice most: a phone cannot
push a photo to the desktop, which is the canonical Quick Share use case.

The blocker is precise and already documented in this repo's own `README.md`:

> `qs receive` refuses to run without a TTY unless given `--yes`, which
> auto-accepts every inbound transfer … Receiving needs a `qs` that can report
> an incoming request as an event and take an accept/decline answer back; until
> then, use the LocalSend pane, which has a real consent prompt.

So the panel's two options today are: auto-accept everything on the LAN, or
screen-scrape a pty. Neither is acceptable, which is why the pane ships without
receive rather than with a bad version of it.

**Almost everything else is already built.** The consent UI is protocol-agnostic:
`Model.js`'s `enqueueIncoming` / `removeIncoming` / `currentIncoming` are a
plain request queue, `Panel.qml`'s incoming column with accept/decline is wired
and tested, and `QuickShare.qml` was deliberately written to mirror
`Service.qml`'s viewState vocabulary. What is missing is one line-oriented event
protocol on the CLI side — and this project already carries a dependency on a
*fork* of `rqs_lib`, so patching that chain is a road already taken.

This plan does not build the feature. It establishes whether the protocol is
right and whether upstream will take it, before anyone writes QML against it.

## Current state

`README.md` states the constraint (quoted above).

`Model.js` — the queue, already protocol-agnostic (it keys on a request object,
not on anything LocalSend-specific):

```js
function enqueueIncoming(queue, request)
function removeIncoming(queue, id)
function currentIncoming(queue)
```

`QuickShare.qml`'s header states the mirroring intent:

```qml
// Mirrors Service.qml's vocabulary so the panel can switch on the same
// strings: nearby | target | sending | success | error.
```

The shape to copy is the LocalSend helper's existing protocol:
`bin/omarchy-nearby-helper` speaks newline-delimited JSON over stdin/stdout, and
`Service.qml` reads it with `stdout: SplitParser { onRead: ... }` and writes
commands with `backend.write(JSON.stringify(command) + "\n")`. That reader is the
template for anything this spike proposes.

The dependency chain, from `THIRD_PARTY_NOTICES.md`:

- `qs` — `https://github.com/martinalderson/qs`, GPL-3.0
- built on `rqs_lib` from `https://github.com/martinalderson/rquickshare`,
  branch `feat/ble-receiver-connect-back`, itself a fork of
  `Martichou/rquickshare`

`qs`'s receive loop is already an event match on `TransferState` —
`WaitingForUserConsent`, `ReceivingFiles`, `Finished`, `Rejected` / `Cancelled` /
`Disconnected` — which is why this is a small patch rather than a rewrite. The
consent prompt is a `dialoguer` call on that first state.

**The licensing constraint**, from `THIRD_PARTY_NOTICES.md`, which any proposal
must not violate:

> `qs` is **not** vendored, redistributed, linked or derived from in this
> repository. … No GPL-licensed code is present in or distributed by this
> repository.

Driving a patched `qs` as a subprocess preserves that. Vendoring it does not.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Read the pinned CLI's source | `cargo install --git https://github.com/martinalderson/qs --rev <QS_REV> --root <tmp>` | not needed — clone and read instead |
| Clone for reading | `git clone https://github.com/martinalderson/qs /tmp/qs-spike` | a checkout to read |
| Existing suites stay green | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |

Prototyping happens **outside this repository**, in a scratch directory. Nothing
in this repo changes except the documents in Scope.

## Scope

**In scope** (create only):
- `plans/spikes/019-quickshare-receive/PROTOCOL.md` — the proposed event protocol
- `plans/spikes/019-quickshare-receive/FINDINGS.md` — what the prototype showed
- `plans/spikes/019-quickshare-receive/DECISION.md` — recommendation and open
  questions

**Out of scope** (do NOT touch):
- `QuickShare.qml`, `Service.qml`, `Panel.qml`, `Model.js`. **No QML is written
  in this spike.** Writing the consumer before the protocol is agreed is exactly
  the mistake this plan exists to prevent.
- `scripts/dependencies.sh`. Do not repoint `QS_REPO` at a personal fork; that
  is a shipping decision, not a spike decision.
- Filing anything upstream. The spike produces a proposal; opening the PR is the
  maintainer's call.

## Git workflow

- Branch: `advisor/019-spike-quickshare-receive`
- Conventional commits; `docs:` is correct.
- Do NOT push or open a PR.

## Steps

### Step 1: Read the receive path and record what it already knows

Clone `qs` at the pinned revision into a scratch directory and read
`cmd_receive` and its surrounding helpers. Record, in `FINDINGS.md`:

- Every `TransferState` the loop observes, and what data is available at each
  (file names, sizes, sender name, PIN).
- Exactly where the consent decision is made and what it sends back into the
  library.
- What the `--yes` path does differently.
- Whether the library exposes a decline as a first-class action or only as a
  timeout.

**Verify**: `FINDINGS.md` names each state and cites `src/main.rs:<line>` in the
cloned checkout.

### Step 2: Draft the protocol

Write `PROTOCOL.md`. Model it on the LocalSend helper's existing shape, because
`Service.qml` already has a working reader for exactly that shape and the panel
should not need two mental models.

Minimum viable event set, one JSON object per line on **stdout**:

- `{"event":"request","id":"...","sender":"...","files":[{"name":"...","size":N}],"total":N,"pin":"..."}`
- `{"event":"progress","id":"...","received":N,"total":N}`
- `{"event":"done","id":"...","path":"..."}`
- `{"event":"failed","id":"...","reason":"rejected|cancelled|disconnected|error"}`

Commands in, one JSON object per line on **stdin**:

- `{"command":"accept","id":"..."}`
- `{"command":"decline","id":"..."}`

Specify explicitly, because these are where such protocols go wrong:

- **What happens when no answer arrives.** There must be a timeout, and it must
  decline, not accept.
- **What happens on stdin EOF** — the frontend died. Must decline everything
  pending and exit; must never fall back to accepting.
- Whether `--events` implies `--yes` is forbidden. It must: the two are
  contradictory and allowing both is how an auto-accept ships by accident.
- Whether human-readable output continues on stderr (it should, unchanged).

**Verify**: `PROTOCOL.md` specifies every event, every command, the timeout
behaviour, the EOF behaviour, and the `--yes` interaction.

### Step 3: Prototype it in the scratch clone

Implement `--events` in the scratch clone — enough to emit the four events and
read the two commands. Drive it by hand with a phone if one is available.

Record in `FINDINGS.md`: whether the states arrive in the order the protocol
assumes, whether the PIN is available at `request` time, whether a decline
propagates to the phone, and what happens on stdin EOF mid-transfer.

**Be honest about what was and was not exercised.** `AGENTS.md` in this repo is
explicit: do not claim device paths were tested when they were not. If no phone
was available, say so and mark the protocol's device-facing claims unverified.

**Verify**: `FINDINGS.md` distinguishes what was observed from what was
inferred, and names which parts had a real device in the loop.

### Step 4: Write the decision

`DECISION.md` covers:

- Recommend / do not recommend proceeding, and why.
- The upstream question: is `martinalderson/qs` receptive? Check its issues and
  recent activity. **What happens if upstream declines** — carry a fork, or drop
  receive? Write the answer down now, while it is cheap.
- Whether `--events` should also carry the **text and clipboard** payload the
  README notes is missing (`rqs_lib` can carry text; the CLI exposes no way to
  hand it any). Bundling both into one upstream conversation is cheaper than two.
- What it would cost on this side: a receive engine in `QuickShare.qml`, reusing
  `Model.js`'s queue and `Panel.qml`'s incoming column, plus the `Service.qml`
  reader as a template.
- Explicitly: the security property that must hold — **the desktop never accepts
  without an explicit user answer** — and how the design guarantees it.

**Verify**: `DECISION.md` contains a clear recommendation and an answer to
"what if upstream says no".

### Step 5: Confirm this repo is unchanged apart from the documents

**Verify**: `git status --porcelain` → only `plans/spikes/` entries;
`node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js`
→ exit 0.

## Test plan

- A spike produces documents and a throwaway prototype; there are no tests to
  add to this repository.
- The prototype's own verification is Step 3's manual exercise, honestly scoped.
- The repository's existing suites must remain green and untouched — that is the
  check that the spike stayed a spike.

## Done criteria

ALL must hold:

- [ ] `plans/spikes/019-quickshare-receive/PROTOCOL.md` specifies all events, all commands, timeout, EOF, and the `--yes` interaction
- [ ] `FINDINGS.md` cites the CLI's source and separates observed from inferred
- [ ] `DECISION.md` gives a recommendation and answers "what if upstream declines"
- [ ] `git diff --stat -- QuickShare.qml Service.qml Panel.qml Model.js` shows no changes
- [ ] `git status --porcelain` lists only `plans/spikes/` entries
- [ ] `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` exits 0
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- You find yourself writing QML. The spike's whole value is deciding the
  protocol before the consumer exists.
- The prototype shows the library cannot report a request *before* accepting it
  — that would mean in-panel consent is impossible through this CLI at all, and
  the answer is to record that and stop, not to work around it.
- Any design you consider would let a transfer be accepted without an explicit
  user answer, including on timeout or on frontend crash. That is the one
  invariant; if it cannot be met, the feature does not ship.
- Plan 009 has not landed, so there is no pinned revision to prototype against.
- The scratch clone would need to be added to this repository to proceed. It must
  not — the GPL boundary in `THIRD_PARTY_NOTICES.md` depends on `qs` staying an
  external program.

## Maintenance notes

- If this spike recommends proceeding, the follow-on work is: (1) upstream PR
  adding `--events`, (2) a `QuickShare.qml` receive engine modelled on
  `Service.qml`'s reader, (3) reusing `Model.js`'s queue and `Panel.qml`'s
  incoming column rather than building new UI, (4) re-pinning `QS_REV` and
  re-running plan 010's fixtures.
- The security invariant — never accept without an explicit answer — should be
  restated in `AGENTS.md` if this ships, because it is the kind of property a
  later "convenience" change erodes.
- Text/clipboard send over Quick Share is gated on the same upstream
  conversation. Whoever opens that PR should raise both.
