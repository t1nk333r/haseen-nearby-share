# Findings: the Quick Share receive path at `a63bc7b3`

Read at `qs` revision `a63bc7b3` (`git clone https://github.com/martinalderson/qs`),
with the library at the revision the lockfile resolves the branch to,
`rqs_lib 0.11.5` @ `66e8b6b7fd96c35b47deeae4c302a8038c7c361a`
(`Cargo.lock:1647-1649`). Line numbers below are `src/main.rs` in that checkout.

The CLI's receive loop is a near-copy of the library's own example,
`core_lib/examples/rx_service.rs` — which auto-accepts. The CLI's only
substantive change to it is that the consent answer comes from a prompt.

## Every state the loop observes

The loop matches on `Message::Client(..)` with `kind == TransferKind::Inbound`
and dispatches on `mc.state`:

| State | Line | What the CLI does |
|---|---|---|
| `WaitingForUserConsent` | `main.rs:156` | asks for consent, sends the answer back, and on a decline prints `Declined.` |
| `ReceivingFiles` | `main.rs:169` | feeds the progress UI from the metadata |
| `Finished` | `main.rs:172` | finishes the bar, reports the saved path(s) |
| `Rejected` / `Cancelled` / `Disconnected` | `main.rs:177` | abandons the bar, names the state in prose |

`SentIntroduction` (`main.rs:317`) and `SendingFiles` (`main.rs:328`) are the
send path's states and are out of scope here. The library's enum is at
`core_lib/src/hdl/mod.rs:51` and includes those five plus `SendingFiles` and
`SentIntroduction`.

## Where the consent decision is made, and what it sends back

`main.rs:157-165`:

```rust
let accept = prompt_consent(mc.metadata.as_ref(), yes, interactive).await;
let action = if accept { TransferAction::ConsentAccept } else { TransferAction::ConsentDecline };
let _ = sender.send(ChannelMessage { id: cm.id.clone(), msg: Message::Lib { action } });
```

That is the single decision point, and it is a `ChannelMessage` keyed by the
transfer id the library assigned (`cm.id`). **The decline is first-class**:
`TransferAction` is `{ConsentAccept, ConsentDecline, TransferCancel}`
(`core_lib/src/channel.rs:4-8`), so a wrong or missing answer never has to be
expressed as a timeout.

**The library does not time out the consent wait.** `process_introduction` sets
the state and returns (`core_lib/src/hdl/inbound.rs:1128`); the timeouts
elsewhere in that file are for the TCP upgrade (15 s, `:1702`) and a BLE
fallback (5 s, `:1725`), not for consent. A frontend that never answers leaves
the transfer pending until the phone gives up, which shows up as
`Disconnected` or `Rejected`.

**What is known at that moment**, via `summarize` (`main.rs:593-613`):

- the sender's device name and type (`"Pixel (phone)"`),
- the PIN, if the library produced one (`m.pin_code`),
- the payload's file **names** — or the placeholder `<text>`, `<url>` or
  `<wifi credentials>` for a non-file payload,
- `m.total_bytes` for the whole transfer.

**Not known: per-file sizes.** The metadata carries one total, not a size per
name, so a protocol cannot promise `{"name":…,"size":…}` per file at this
revision without a library change. Worth noting for the text/URL question
below: the payload *kind* is visible here — the CLI already distinguishes
files, text, URL and Wi-Fi credentials in `summarize`.

## What `--yes` does differently

Two places, and only two:

- `main.rs:123-127` — without `--yes`, a non-interactive stdin or stderr is a
  hard refusal: it prints the reason and returns **2** before the service even
  starts. With `--yes` it proceeds.
- `main.rs:216-219` — `prompt_consent` prints `Auto-accepting.` and returns
  `true` **before** it reaches the interactive branch, so no prompt is shown.

The interactive branch itself is `dialoguer::Confirm` with `.default(false)`
and `.unwrap_or(false)` (`main.rs:221-232`): a closed stdin or an error while
prompting declines rather than accepts. And when not interactive *and* not
`--yes`, `prompt_consent` returns `false` (`main.rs:220-222`) — the CLI already
declines safely in the situation a frontend would put it in.

## What a protocol can reuse, and the one conflict

Reusable as-is: the decision point (a message keyed by transfer id), the
first-class decline, the metadata summary, the 10%-bucket progress the
non-interactive path already emits from `ack_bytes / total_bytes`
(`main.rs:571-575`), and the saved-path reporting.

One conflict to design around: `report_received` writes the saved path to
**stdout** (`main.rs:231`), which is the obvious channel for a line-oriented
event stream. In `--events` mode the path belongs in the `done` event instead.

## Reproducibility note for plan 009

`--locked` pins more than `qs`: `Cargo.lock:1649` resolves the
`feat/ble-receiver-connect-back` branch to the commit above, so the library a
user builds is fixed too. Without `--locked` the branch would be re-resolved on
every install, which is the same class of drift plan 009 removed at the top
level.

## The prototype, and what it was actually run against

`PROTOTYPE.patch` beside this file is the whole of it: a diff against the pinned
revision implementing `--events` and `--consent-timeout`, built in a scratch
clone outside this repository. It compiles (`cargo build`, ~12 s with a warm
cache) and the following were run:

| Check | Result |
|---|---|
| `receive --events --yes` refuses to start | exit 2, reason on stderr |
| `receive --events` with stdin a pipe, not a TTY | starts; emits exactly one `ready` line on stdout; human prose stays on stderr |
| stdin closed → service stops | exit 0, reason on stderr |
| A garbage line, then an `accept` for an unknown id | both ignored with a note on stderr; no crash, no accept |
| `--help` lists both flags | present |

Note what the second row means: the existing hard refusal at `main.rs:123-127`
had to become conditional, because in event mode the answer comes from the
stream and a terminal is not required. That is the one place where this change
loosens an existing guard, and the guard it loosens is the one that exists to
prevent an unattended auto-accept — which is why `--events --yes` is refused
outright rather than tolerated.

### What was not exercised, and cannot be here

**No phone was available.** Every device-facing claim in `PROTOCOL.md` is
therefore unverified by observation:

- no `request` event was ever emitted, so the shape and the arrival order of
  `request` → `progress` → `done` are inferred from the source, not seen;
- `accept` and `decline` were never driven against a real pending consent, so
  the round trip through `ChannelMessage` is unproven in practice;
- the timeout path never ran (it needs a request to time out);
- the EOF-while-pending path never ran for the same reason — only the
  EOF-with-nothing-pending path was exercised;
- whether the phone gives up before the 60-second default is unknown;
- whether `WaitingForUserConsent` arrives once per transfer is unknown.

The prototype's own code is otherwise complete: it emits all four events, reads
both commands, handles an early answer that arrives before its request, and
treats every unanswerable path as a decline.

