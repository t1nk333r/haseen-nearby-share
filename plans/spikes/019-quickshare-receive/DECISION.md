# Decision: build `--events`, carry it locally if upstream says no

**Recommendation: proceed.** The receive pane is the largest asymmetry in the
product and the one users notice — a phone cannot push a photo to the desktop.
The missing piece is one small, well-shaped change in a CLI that already
publishes itself as script-friendly, and the consumer side is already built.
The risk is concentrated in one property (the desktop must never accept without
an explicit answer), and every path in the proposed design defaults to decline.

## Why the protocol is the right shape

The CLI's receive loop is already an event match over the library's
`TransferState` (`FINDINGS.md`), the decline is a first-class action
(`TransferAction::ConsentDecline`), the consent metadata already carries what a
prompt needs, and the non-interactive path already prints 10% progress buckets
and declines safely. `--events` does not add a protocol: it replaces the *source
of one answer* and routes the prose that is already being written to a stream.
`serde_json` is already a dependency, so it needs no new crates.

## Upstream

`martinalderson/qs` is a single-maintainer project with 0 stars, 0 forks and 0
issues: no evidence of receptivity either way, and no history to infer from. Its
README does argue in the proposal's favour — it advertises itself as "agent /
script friendly", states that a non-TTY `qs` never prompts and that its output
is line-oriented with machine output on stdout. `--events` is that promise
carried to the one command that cannot keep it today, because answering a
consent question is the only thing `receive` needs a terminal for.

So: raise it as an issue with `PROTOCOL.md` attached, and offer the prototype
diff. A maintainer who wrote that README section has already decided the shape.

**If upstream declines, or does not answer:** carry the patch in this plugin,
exactly as `backend/vendor/localsend-rs` is carried for the LocalSend side. That
costs one change to `scripts/dependencies.sh`: `cargo install --git` cannot apply
a patch, so the build becomes clone-at-`QS_REV` → `git apply` → `cargo install
--path`. That is a new plan, not part of this spike. The licensing boundary is
unchanged either way: `qs` stays a separate GPL-3.0 program that this MIT
repository patches and executes, and no GPL code is linked or redistributed
(`THIRD_PARTY_NOTICES.md`).

## Text and clipboard: bundle the question, not a feature

The library distinguishes text, URL and Wi-Fi payloads, and the consent
metadata already reports which one is coming (`FINDINGS.md`). But the CLI
exposes no way to *send* any of them, so receive-only support would serve a
payload nothing on this machine can produce. Fold it into the same upstream
conversation — "receive text and URL payloads" is one coherent request — rather
than smuggling half of it in locally.

## What it costs on this side

Smaller than plan 019 assumed, because the parts that are hard to get right
already exist and are tested:

| Piece | State |
|---|---|
| The request queue — `enqueueIncoming` / `removeIncoming` / `currentIncoming` | exists, `Model.js:48,61,67` |
| The consent UI — a column with Decline and Accept, plus "N more requests" | exists, `Panel.qml:659-662` |
| The reader template — `stdinEnabled`, `SplitParser`, `write(JSON.stringify(cmd) + "\n")` | exists, `Service.qml:403,853-854` |

What is genuinely new: a receive engine in `QuickShare.qml` speaking this
protocol, mirroring the LocalSend helper reader, and a state machine that feeds
`Model.js`'s queue and lets `Panel.qml` answer it. That is a medium plan, not a
large one — and it must not start until the event mode exists in a binary the
plugin actually builds.

## The security property, and how the design holds it

**The desktop never accepts a transfer without an explicit user answer.** In
this design:

1. The only code path that emits `ConsentAccept` is the one that received
   `{"command":"accept","id":…}` for that transfer id — the same path the
   interactive prompt drives today (`main.rs:157-165`).
2. No answer within the timeout declines.
3. The event stream closing (the frontend died, or a shell restart killed it)
   declines whatever is pending, and stops the service.
4. A malformed, unrecognised or stale command is ignored, never treated as an
   accept.
5. `--events` together with `--yes` is refused outright, and the existing
   non-TTY refusal is untouched for every other combination.
6. `--yes` remains the only way to accept without an answer, and it is a flag a
   person typed.

The consumer side inherits the same obligation: `Service.qml` may send `accept`
only from the panel's Accept action, never from a timeout, a reconnect or a
startup default. That belongs in the consumer plan's tests, in the
characterisation style plan 010 established.

## Open questions

- **Per-file sizes.** The consent metadata carries one total. Offering a size
  per file needs a library change; without it the protocol reports names and a
  total, which is what the prompt shows today and is probably enough.
- **Does the phone give up before we do?** Unknown without a device. The 60 s
  default is a guess that should be measured against a real phone.
- **Is `WaitingForUserConsent` emitted exactly once per transfer?** The
  prototype assumes it. A duplicate would re-emit `request` and start a second
  timer; the answer would still be honoured once. Worth confirming with a
  device, and cheap to defend against in the consumer regardless.
- **Renamed files.** Name-conflict resolution happens in the library, but the
  CLI reports the metadata's original names, so a second file of the same name
  is reported under the first one's name. Pre-existing behaviour, inherited by
  the `done` event; not this protocol's problem to fix, but worth knowing before
  the panel shows a path that is not quite the file that landed.
