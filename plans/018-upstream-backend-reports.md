# Plan 018: Prepare upstream bug reports for the five backend findings

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- backend/src/`
> This must report **no changes**. If `backend/src/` has been modified, treat it
> as a STOP condition — the premise of this plan is that it has not been.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW — produces documents, changes no code
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

An audit found five real defects in `backend/src/main.rs`. None of them is this
fork's code: `git log 3f54d18..HEAD -- backend/` is empty, so the Rust helper is
byte-identical to upstream `jfg96/omarchy-nearby` at v1.1.1.

That fact determines the right response. Patching them here would fork the
backend, and the fork's whole current premise — including plan 015's release
model — rests on `backend/` staying identical to upstream so rebases stay cheap.
Fixing these locally spends that permanently, for bugs that affect every upstream
user equally.

So the deliverable is **five self-contained reports**, ready to file as issues or
turn into pull requests against upstream. Two of the five are things users hit
routinely.

## The five findings

Each was verified by reading the cited code during the audit.

**1. Error classification matches substrings, so ordinary filenames misreport.**
`human_error` lowercases the whole `anyhow` chain and dispatches on `contains`.
The chain includes file paths and OS messages. `text.contains("pin")` therefore
matches **mapping**, **shipping**, **stripping**; `text.contains("403")` matches
any path with `403` in it. Sending `shipping-invoice.pdf` and hitting an I/O
error reports "PIN required", and the user retries a PIN forever. Only
`LocalSendError::RateLimited` is matched by type.

**2. A finished discovery round emits no terminal event.** In
`start_active_discovery`, the `tokio::select!` takes the `run` arm on normal
completion and then falls through to `let _ = stop_rx.await;` — so
`discovery_stopped` is emitted only after an explicit stop command. With the
popup open and a round that found nothing, the panel shows "Finding devices…"
indefinitely instead of "No devices nearby". Worse, `discovery` stays `Some`, so
a later non-forced `discovery_start` is a silent no-op.

**3. The incoming byte total is summed unchecked.** `request.files().values()
.map(|f| f.size).sum::<u64>()` sums sizes **declared by the remote sender**. Two
files near `u64::MAX` overflow it. In debug builds (overflow checks on) that
panics inside the event-forwarding task — a remote DoS of the event stream. In
release the profile sets `panic = "abort"` but not `overflow-checks`, so it wraps
silently and the accept dialog shows a bogus size for the transfer the user is
being asked to approve.

**4. The peer registry is unbounded and keyed by a remote-supplied fingerprint.**
`record_peer` inserts into a `HashMap` keyed by `device.fingerprint`, with no
cap and no dedupe, and emits a `device` event on **every** announcement even when
nothing changed. The only bound is a 90-second TTL sweep. A host emitting
announcements with a fresh fingerprint per packet grows the map and drives one
stdout write per packet into the frontend.

**5. The TLS identity is written non-atomically and rotates silently on any read
error.** The load path uses `if let Ok(data) = std::fs::read(&path)` with a
nested `if let Ok(stored)`, swallowing every failure and falling through to
generating a new certificate. The key is written with `std::fs::write` (created
at `0666 & !umask`) and chmod'ed to `0600` only afterwards, with no temp-file +
rename. A transient read failure or an earlier truncated write silently rotates
the device's persistent identity and fingerprint — defeating the documented
"single persistent TLS identity" decision and invalidating any pinned
fingerprint. `backend/src/settings.rs` already contains the correct pattern:
`create_new` + `mode(0o600)` + `sync_all` + `rename`.

## Current state

The upstream project: `https://github.com/jfg96/omarchy-nearby`, MIT, active
(the fork point `3f54d18` is `chore: prepare v1.1.1 release`, and recent history
shows merged pull requests from outside contributors).

This repository keeps upstream as a git remote:

```
upstream	https://github.com/jfg96/omarchy-nearby.git (fetch)
```

Upstream's own contribution norms, from `AGENTS.md` in this tree (inherited from
upstream, so they are upstream's rules):

> Prioritize correctness, security, and user-visible regressions over stylistic
> preferences. Keep patches minimal and do not mix unrelated refactors into bug
> fixes.

> Regression tests must exercise the reported failure and should fail against the
> pre-fix behavior for the expected reason. Do not claim that Omarchy,
> Quickshell, portals, peer discovery, or real-device transfers were tested when
> they were not.

That last sentence governs how these reports must be written.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Confirm backend is unmodified | `git diff --stat 3f54d18..HEAD -- backend/` | no output |
| Confirm line numbers | `sed -n '<N>,<M>p' backend/src/main.rs` | shows the cited code |
| Rust tests (unchanged) | `cargo test --locked --manifest-path backend/Cargo.toml` | pass |
| Formatting | `cargo fmt --manifest-path backend/Cargo.toml --all -- --check` | exit 0 |

## Scope

**In scope** (create only):
- `plans/upstream/001-error-classification.md`
- `plans/upstream/002-discovery-completion-event.md`
- `plans/upstream/003-incoming-size-overflow.md`
- `plans/upstream/004-peer-registry-bounds.md`
- `plans/upstream/005-tls-identity-persistence.md`

**Out of scope** (do NOT touch):
- **`backend/` — any file, for any reason.** Modifying it invalidates the plan's
  premise and plan 015's release model. Not one line.
- Filing the issues. This plan writes the reports; publishing them is the
  maintainer's call and needs their GitHub account. Do not run `gh issue create`.
- The rest of this repository.

## Git workflow

- Branch: `advisor/018-upstream-backend-reports`
- Conventional commits; `docs:` is correct.
- Do NOT push or open a PR — least of all against upstream.

## Steps

### Step 1: Re-verify every citation before writing a word

For each of the five findings, open the cited region in `backend/src/main.rs`
and confirm the code matches the description above. Record the **exact current
line numbers**; the descriptions above name behaviour, not line numbers, because
line numbers drift.

Specifically locate: `fn human_error`, the `tokio::select!` inside
`start_active_discovery`, the `.sum::<u64>()` over `request.files()`, `fn
record_peer`, and the identity load/save pair.

**Verify**: for each finding, you can quote the current code and give a
`backend/src/main.rs:<line>` reference that resolves.

If any finding does **not** match, stop — see STOP conditions.

### Step 2: Write each report in a fileable shape

One file per finding, each self-contained (an upstream maintainer has not read
this repo or this plan). Use this structure:

```markdown
# <Imperative title>

**Affects**: omarchy-nearby v1.1.1 (`backend/src/main.rs`)
**Found by**: code review of an unmodified v1.1.1 checkout
**Severity**: <user-visible bug | security | robustness>

## What happens

<Two or three sentences. Observable behaviour, not implementation.>

## Where

`backend/src/main.rs:<line>` — <one line on what is there>

```rust
<short excerpt, quoted exactly>
```

## Why it happens

<The mechanism. Short.>

## Reproducing

<Concrete steps, or an honest statement that it was found by reading and what
would be needed to observe it. Do not invent a repro you did not run.>

## Suggested fix

<One paragraph. Point at an in-repo pattern where one exists.>

## Suggested regression test

<What the test should assert and why it fails pre-fix — upstream requires
regression tests that fail against the pre-fix behaviour for the right reason.>
```

Notes for individual reports:

- **Report 1**: give concrete triggering strings (`shipping`, `mapping`) — they
  are what make the bug obviously real. Suggest matching `LocalSendError`
  variants and `std::io::ErrorKind` via `error.chain().find_map(downcast_ref)`
  first, keeping the string fallbacks beneath.
- **Report 2**: note the frontend consequence (the panel's `discoveryActive`
  clears only on `discovery_stopped`), since upstream owns that frontend too.
- **Report 3**: state plainly that the debug/release behaviours differ and why
  (`panic = "abort"`, no `overflow-checks`). Suggest
  `fold(0u64, u64::saturating_add)`.
- **Report 4**: frame as robustness against a hostile or buggy LAN peer, not as
  an exploit. Suggest an LRU cap evicting by `last_seen`, refusing *new*
  fingerprints when full so a flood cannot push out established peers, plus
  emitting only on change.
- **Report 5**: point at `backend/src/settings.rs`'s existing atomic write as the
  in-repo pattern, and note that `ErrorKind::NotFound` should mean "generate"
  while every other error should be fatal — which is what `settings::load`
  already does.

**Verify**: each file exists and contains a `backend/src/main.rs:` reference,
a quoted excerpt, and a suggested test.

### Step 3: Add an index

Create `plans/upstream/README.md` listing the five, stating that they are for
`jfg96/omarchy-nearby` and not for this fork, that `backend/` here is
byte-identical to upstream at v1.1.1, and that nothing in this directory has
been filed yet.

**Verify**: `ls plans/upstream/` → six files.

### Step 4: Prove the backend is still untouched

**Verify**: `git diff --stat 3f54d18..HEAD -- backend/` → no output.
`git status --porcelain` → only `plans/upstream/` entries.

## Test plan

- No code changes, so no new tests here. Each report *specifies* a regression
  test for upstream to write, which is the deliverable.
- The one hard verification is Step 4: `backend/` must remain byte-identical to
  upstream.

## Done criteria

ALL must hold:

- [ ] Five report files plus an index exist under `plans/upstream/`
- [ ] Every report cites a `backend/src/main.rs:<line>` that resolves to the code it quotes
- [ ] Every report names a suggested regression test
- [ ] No report claims a repro that was not actually run
- [ ] `git diff --stat 3f54d18..HEAD -- backend/` produces no output
- [ ] `git status --porcelain` lists only `plans/upstream/` entries
- [ ] No issue was filed and `gh` was not invoked
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `git diff --stat 3f54d18..HEAD -- backend/` shows **any** change. The fork has
  started diverging and this plan's premise — and plan 015's release model —
  need revisiting first.
- A finding does not match the current code. Do not write a report for a bug you
  cannot see; report which one and what you found instead.
- You are tempted to fix any of them in `backend/`. That is the one thing this
  plan exists to avoid.
- Upstream turns out to have already fixed one (check
  `git log upstream/main -- backend/src/main.rs` after a `git fetch upstream`,
  if the network is available). Drop that report and say so.

## Maintenance notes

- These reports are pinned to v1.1.1. If upstream releases a newer version,
  re-verify each finding against it before filing — some may be fixed.
- If upstream declines a fix or goes quiet, the decision changes: carrying a
  local patch then becomes reasonable, and the cost is the rebase burden plan
  015 currently avoids. Revisit deliberately rather than drifting into it.
- Findings 1 and 2 are the ones users actually hit; if only some are filed, file
  those first.
