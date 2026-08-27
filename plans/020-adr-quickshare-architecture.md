# Plan 020: Decide in writing whether Quick Share belongs in the Rust helper

> **Executor instructions**: This plan produces **one decision document**. It
> changes no code. Follow the steps, run every verification command, and honour
> the STOP conditions. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- QuickShare.qml scripts/dependencies.sh THIRD_PARTY_NOTICES.md backend/Cargo.toml`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S (to decide; L if the decision is "yes")
- **Risk**: LOW to investigate; HIGH to execute carelessly — the wrong answer
  contaminates an MIT project with GPL code
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

The Quick Share pane drives an external CLI and recovers state by parsing its
human-readable stderr. That design was chosen because the alternative was
unavailable — `rquickshare` is a GUI that ignores `argv`, and `rqs_lib` is a
library rather than a daemon — but it was never written down as a decision. It
now looks accidental rather than deliberate, and it has a visible ceiling:

- Three regexes over prose recover the confirmation PIN and the progress.
  `QuickShare.qml` says so itself: "Everything `qs` says about a transfer goes to
  stderr as prose, so this is a parser rather than a protocol."
- A ten-line comment in `scripts/dependencies.sh` exists solely to explain why
  the binary cannot be called `qs` — because `/usr/bin/qs` is Quickshell's own
  CLI and either would silently shadow the other.
- Users build ~300 crates on their own machine, from a third-party branch.
- Receive is impossible through the current CLI surface at all (see plan 019).

The project already has a working pattern for the alternative: vendor a Rust
protocol library into `omarchy-nearby-helper`, patch it locally, keep a
maintenance record — that is exactly what `backend/vendor/localsend-rs` and
`VENDORED_LOCALSEND_RS.md` are.

**But there is a blocker that makes this a licensing question rather than an
engineering one**, and it is already written down in this repo.
`THIRD_PARTY_NOTICES.md` keeps this repository MIT *specifically because* `qs` is
"not vendored, redistributed, linked or derived from" and is executed as a
separate program. `rqs_lib` is GPL-3.0. Linking it into the MIT helper is the one
thing that reasoning forbids.

So the decision is being made **by inertia**. This plan makes it explicit, either
way. Writing it down is cheap; discovering the constraint after a week of
vendoring is not.

## Current state

`QuickShare.qml`, the parser's own admission:

```qml
  // Everything `qs` says about a transfer goes to stderr as prose, so this is
  // a parser rather than a protocol. Only three shapes are load-bearing: the
  // PIN, the percentage ProgressUi emits every 10% when it is not on a TTY,
  // and the final confirmation. Anything else is left for the log.
```

`scripts/dependencies.sh`, the complexity that exists only because the engine is
an external binary:

```bash
# NOT installed as plain `qs`, and never invoked by bare name.
#
# /usr/bin/qs is Quickshell's CLI, shipped by the package the whole Omarchy
# shell runs on. `cargo install --root ~/.local` produces ~/.local/bin/qs,
# which either shadows Quickshell's binary or -- when /usr/bin sorts first, as
# it does by default -- is itself shadowed, so a probe for `qs` succeeds and
# then hands Quick Share arguments to Quickshell. Both outcomes are silent.
```

`THIRD_PARTY_NOTICES.md`, the constraint:

```
`qs` is **not** vendored, redistributed, linked or derived from in this
repository. `scripts/dependencies.sh` builds it from source on the user's own
machine, and the plugin invokes the resulting binary as a separate program over
its documented command-line interface. No GPL-licensed code is present in or
distributed by this repository.
```

`backend/Cargo.toml`, the existing vendoring pattern:

```toml
localsend-rs = { path = "vendor/localsend-rs", default-features = false, features = ["https"] }
```

with `VENDORED_LOCALSEND_RS.md` as its maintenance record, and `LICENSE` making
this repository MIT.

Relevant fact from the audit: `git log 3f54d18..HEAD -- backend/` is empty. The
fork has never modified the Rust helper, and plan 015's release model depends on
that staying true.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Confirm the licence of this repo | `head -3 LICENSE` | MIT |
| Confirm backend provenance | `git log --oneline 3f54d18..HEAD -- backend/` | no output |
| Existing suites stay green | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |

## Scope

**In scope** (create only):
- `docs/adr/001-quickshare-engine-architecture.md`

Create the `docs/adr/` directory if it does not exist. That path is chosen
because it is the conventional location an audit tool or a future contributor
will glob for.

**Out of scope** (do NOT touch):
- `backend/` — any file. Investigating does not mean prototyping here.
- `QuickShare.qml`, `scripts/dependencies.sh`, `THIRD_PARTY_NOTICES.md`,
  `Cargo.toml`. If the ADR concludes "yes", the work that follows is a separate
  plan.
- `LICENSE`. Changing the project's licence is not a decision an executor makes.

## Git workflow

- Branch: `advisor/020-adr-quickshare-architecture`
- Conventional commits; `docs:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Establish the licensing facts before anything else

This is the load-bearing step. Record, with citations:

- This repository's licence (`LICENSE`).
- `rqs_lib`'s licence and that of the fork the project depends on.
- `qs`'s licence (GPL-3.0-or-later, per `THIRD_PARTY_NOTICES.md`).
- Whether GPL-3.0 permits what each option requires. In particular: linking
  GPL-3.0 code into a binary distributed under MIT, versus shipping a **separate**
  GPL-3.0 binary alongside an MIT one and invoking it over a documented
  interface.

State plainly where you are uncertain. This is a legal question with an
engineering surface, and an executor guessing at it is worse than an executor
saying "this needs the maintainer to decide".

**Verify**: the ADR's context section cites each licence and names what is
uncertain.

### Step 2: Lay out the options honestly

At least these three:

**(A) Status quo — external CLI, prose parser.** Keep the subprocess design.
Costs: the parser's fragility, the user-machine build, the name collision, the
unpinned-branch supply chain (plan 009 mitigates), and receive being impossible
(plan 019 addresses). Benefit: the MIT boundary is clean and unarguable, and the
fork carries no Rust divergence — which plan 015's release model depends on.

**(B) A separate GPL-3.0 helper binary.** Write
`omarchy-nearby-qs-helper` around `rqs_lib`, GPL-3.0, distributed *alongside* the
MIT plugin rather than linked into it, speaking the same newline-JSON protocol as
`omarchy-nearby-helper`. Gets a real protocol and makes receive tractable
in-process. Costs: a second Rust binary to build and ship, a second licence in
the distribution, and it breaks the "backend identical to upstream" property
unless the new binary lives outside `backend/`.

**(C) Vendor `rqs_lib` into the existing helper.** Simplest architecturally,
matches the `localsend-rs` pattern — and is the option `THIRD_PARTY_NOTICES.md`'s
reasoning appears to forbid outright. Include it so the ADR records *why* it was
rejected rather than leaving it looking unconsidered.

For each: engineering cost, licensing consequence, effect on the upstream-rebase
story, and effect on plan 019's receive work.

**Verify**: the ADR presents all three with costs and consequences, not just the
preferred one.

### Step 3: Recommend, and record the consequences

Write a recommendation and, whichever way it goes, the consequences that follow:

- If **(A)**: the prose parser must be *hardened and tested* rather than
  tolerated — that is plans 010 and 011 — and receive depends entirely on plan
  019's upstream conversation succeeding. Record what happens if it does not.
- If **(B)**: name where the new binary would live, how it would be built and
  distributed, and how the licence separation is made visible to users. Note that
  this reopens plan 015's release-model decision, because the fork would then be
  shipping its own binaries.
- If **(C)**: it must not proceed without an explicit licensing conclusion, and
  the ADR must say so.

Use the standard ADR shape: Status, Context, Decision, Consequences. Mark it
`Proposed` unless the maintainer has actually decided — an executor does not get
to mark a decision `Accepted`.

**Verify**: the ADR has all four sections and a status of `Proposed`.

### Step 4: Confirm nothing else changed

**Verify**: `git status --porcelain` → only `docs/adr/` entries;
`git log --oneline 3f54d18..HEAD -- backend/` → no output;
`node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js`
→ exit 0.

## Test plan

- No code changes and therefore no tests.
- The verification is that the ADR exists, is complete, cites its facts, and that
  nothing else in the repository moved.

## Done criteria

ALL must hold:

- [ ] `docs/adr/001-quickshare-engine-architecture.md` exists
- [ ] It has Status / Context / Decision / Consequences sections
- [ ] Status is `Proposed`, not `Accepted`
- [ ] It cites the licences of this repo, `qs`, and `rqs_lib`, and names what is legally uncertain
- [ ] It presents options A, B and C with costs — including why C is likely foreclosed
- [ ] It states the consequences of the recommended option, including for plan 019
- [ ] `git log --oneline 3f54d18..HEAD -- backend/` produces no output
- [ ] `git status --porcelain` lists only `docs/adr/` entries
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- You cannot establish `rqs_lib`'s licence from its repository. Do not assume it
  matches `qs`'s.
- You find yourself writing Rust, editing `Cargo.toml`, or cloning anything into
  `backend/`. This plan decides; it does not build.
- The licensing question turns out to hinge on something you cannot resolve by
  reading the licences. Write the question down precisely and stop — "the
  maintainer must answer this" is a legitimate ADR outcome and a much better one
  than a confident guess.
- You are inclined to mark the ADR `Accepted`. Only the maintainer does that.

## Maintenance notes

- An ADR is worth having even if the decision is "keep doing what we are doing".
  The current design then reads as deliberate, and the next contributor spends
  their effort hardening the parser instead of proposing a rewrite.
- If the ADR is later accepted as (B) or (C), plan 015's release model needs
  revisiting in the same change — it currently assumes the fork ships no binaries
  of its own.
- `docs/adr/` is a new directory. If more decisions follow, keep the numbering
  monotonic and never edit an accepted ADR in place — supersede it with a new one.
