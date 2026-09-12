# Proposed protocol: `qs receive --events`

A line-oriented event protocol so a frontend can answer Quick Share's consent
question without owning a terminal. It is modelled on the LocalSend helper's
existing protocol, which `Service.qml` already reads with a `SplitParser` and
writes to with `JSON.stringify(command) + "\n"`, so the panel needs one mental
model for both panes rather than two.

Written against `qs` `a63bc7b3`; the state names, the metadata available at
consent time and the absence of a consent timeout are all recorded in
`FINDINGS.md` with line references.

## Shape

- **stdout** carries one JSON object per line, and nothing else.
- **stdin** takes one JSON object per line.
- **stderr** keeps today's human-readable prose, unchanged, so a terminal user
  and a log reader see no difference.

## Events (stdout)

Exactly one `ready` first, then per transfer: one `request`, zero or more
`progress`, and exactly one terminal event (`done` or `failed`).

```json
{"event":"ready","v":1,"name":"luna","out":"/home/u/Downloads"}
{"event":"request","id":"…","sender":"Pixel (phone)","payload":"files",
 "files":["holiday.jpg","notes.txt"],"total":1834771,"pin":"1234"}
{"event":"progress","id":"…","received":917120,"total":1834771}
{"event":"done","id":"…","paths":["/home/u/Downloads/holiday.jpg"]}
{"event":"failed","id":"…","reason":"rejected"}
```

- `ready` is not in the plan's minimum set and is added deliberately: without
  it a frontend cannot tell "the service is listening" from "the process died
  before it said anything", which is the exact ambiguity that makes an
  auto-accept bug invisible. It carries the protocol version.
- `files` is a list of **names**, not objects, because the metadata at consent
  time carries one total and no per-file size (`FINDINGS.md`). A `size` per
  file would need a library change, so the protocol does not promise one.
- `payload` is `files`, `text`, `url` or `wifi`, taken from the payload variant
  the library already distinguishes. A frontend can phrase itself accordingly
  ("wants to send you a link") without parsing the file list.
- `pin` is `null` when the library produced none.
- `paths` is a list because one transfer can deliver several files; the current
  CLI prints one path per file on stdout (`main.rs:224-236`), which in event
  mode belongs here instead — stdout must carry events only.
- `reason` is one of `rejected`, `cancelled`, `disconnected`, `timeout`,
  `error`. `timeout` is an addition to the plan's list: a consent that was never
  answered is worth distinguishing from one the phone refused.

## Commands (stdin)

```json
{"command":"accept","id":"…"}
{"command":"decline","id":"…"}
```

Any other line is ignored, with a note on stderr. **An unrecognised, malformed
or unparseable line is never treated as an accept.**

## The rules that matter

**A missing answer must decline.** Each `request` starts a timer — 60 s by
default, `--consent-timeout <seconds>` to change it — at the end of which the
CLI sends `ConsentDecline`, prints the same `Declined.` prose it prints today,
and emits `failed` with `reason: "timeout"`. The timer exists because the
library has none (`FINDINGS.md`): without it a transfer hangs until the phone
gives up.

**stdin EOF must decline everything pending and exit.** A frontend that dies —
a shell restart, a crash, a killed panel — closes the pipe. On EOF the CLI
declines every request still waiting, emits `failed` with
`reason: "cancelled"` for each, stops the service, and exits 0. It must never
fall back to accepting, and it must never keep answering transfers after the
stream that is supposed to answer them has gone.

**`--events` with `--yes` is an error.** The two are contradictory — one asks
the stream, the other answers for it — and permitting both is how an
auto-accept ships by accident. The CLI refuses to start, prints why, and exits
2. The same reasoning as the existing refusal at `main.rs:123-127`, which stays
exactly as it is for every other combination: without `--events` and without
`--yes`, a non-interactive stdin is still a hard refusal.

**Consent state is per transfer id.** An `accept` or `decline` naming an
unknown or already-answered id is ignored. The first answer for an id wins; a
second is ignored, not applied.

**One terminal event per id.** After `done` or `failed` for an id, nothing more
is emitted for it.

## Why this is safe to hand a panel

The security property the feature has to hold is: **the desktop never accepts a
transfer without an explicit user answer.** In this design,

- the default for every path — no answer, a timeout, EOF, a malformed command,
  an unknown id — is decline;
- the only code path that emits `ConsentAccept` is the one that received
  `{"command":"accept","id":…}` for that id, and it is the same path the
  interactive prompt drives today (`main.rs:157-165`);
- `--yes` remains the one way to accept without an answer, it is unchanged, and
  it is now impossible to combine with the event stream.

## What this does not include

Text and clipboard payloads. The library can carry them and the payload kind is
already visible (`FINDINGS.md`), but the CLI exposes no way to *send* one, and
adding receive-only support for a payload nobody can send is not worth a
protocol revision. The decision document takes this up as a question for
upstream rather than a feature to smuggle in here.
