# Plan 016: Reconcile the fork's documentation with the fork

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- AGENTS.md README.md ROBUSTNESS.md scripts/setup_firewall.sh`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: `plans/015-settle-fork-release-identity.md` (015 deletes
  `install.sh`, which this plan's README edits reference)
- **Category**: docs
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

`AGENTS.md` is the file every agent and contributor reads first. It currently
describes **upstream's** plugin: it names an IPC target that no longer exists,
omits every file the fork added, lists a smaller test suite than CI runs, and
forbids the dependency the fork deliberately introduced. An agent following it
has documented grounds to reject work the maintainer intended.

`README.md` is worse in one specific way: it does not merely omit, it actively
instructs. Under a section explicitly framed as "upstream's … accurate for the
LocalSend pane", it tells users to `curl` upstream's installer, to enable
`oma.nearby`, and — the sharpest edge — to uninstall with
`omarchy plugin remove oma.nearby`, which for a fork user does nothing at all.
That framing is defensible for *behavioural* prose; it does not hold for
install, uninstall, update and build commands, which name a different plugin id
and a different repository.

Two plugin ids in one README is exactly the failure mode
`tests/service-state.test.js` was written to prevent inside the code.

## Current state

`AGENTS.md`, the architecture section — note the IPC target:

```
- `Service.qml` owns the helper process, the transfer state machine, and the
  `oma.nearby` IPC target. The shell loads a `service` kind once per session.
```

The actual target in `Service.qml` is `t1nk33r.nearby-share`, and
`tests/service-state.test.js` asserts the target equals `manifest.id`.

`AGENTS.md`, the dependency rule the fork violates by design:

```
- Avoid new runtime dependencies unless they are necessary and available on a
  stock Omarchy installation.
```

`scripts/dependencies.sh` builds a ~300-crate third-party CLI from git.

`AGENTS.md`, the validation block — it omits `tests/updater.test.sh`, which both
`ci.yml` and `release.yml` run:

```sh
node tests/model.test.js
node tests/panel-state.test.js
node tests/service-state.test.js
cargo fmt --manifest-path backend/Cargo.toml --all -- --check
cargo check --locked --manifest-path backend/Cargo.toml
cargo test --locked --manifest-path backend/Cargo.toml
cargo test --locked --manifest-path backend/vendor/localsend-rs/Cargo.toml --features https
```

`README.md` — the upstream-identity lines. Verified locations:

- line ~139: `curl -fsSL https://raw.githubusercontent.com/jfg96/omarchy-nearby/main/install.sh \`
- line ~146: "…enables `oma.nearby`. Nearby never requests administrator privileges…"
- line ~156: "Remove it with `omarchy plugin remove oma.nearby`."
- lines ~278-281: `omarchy plugin add https://github.com/jfg96/omarchy-nearby.git --yes` /
  `cd ~/.config/omarchy/plugins/oma.nearby` / `omarchy plugin enable oma.nearby`
- line ~300: `~/.config/omarchy/plugins/oma.nearby/install.sh`
- lines ~324-325: `omarchy-shell oma.nearby updateHelper` / `omarchy-shell oma.nearby status`

Line ~181 is the divider that frames everything below as upstream's.

`scripts/setup_firewall.sh`'s header says "Three rules, one port each" and the
script installs four — **unless plan 006 already fixed it.** Check before
editing.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Find stale ids | `grep -rn 'oma\.nearby' --include='*.md' . \| grep -v '^./plans/'` | no matches at the end |
| All Node suites | `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` | exit 0 |
| Shell tests | `bash tests/updater.test.sh` | pass line, exit 0 |

## Scope

**In scope**:
- `AGENTS.md`
- `README.md`
- `scripts/setup_firewall.sh` — only the "Three rules" count, and only if plan
  006 has not already corrected it

**Out of scope** (do NOT touch):
- `CHANGELOG.md` — plan 015 writes the fork's entry.
- `THIRD_PARTY_NOTICES.md` — plan 009 records the pinned revision there.
- `ROBUSTNESS.md` — it documents the LocalSend engine's manual test matrix and
  is still accurate for it. Adding a Quick Share matrix is a separate piece of
  work and requires real devices to write honestly.
- Any `.qml`, `.js`, or `backend/` file.
- The `"oma.nearby"` literals in `tests/model.test.js` — they are *arguments* to
  functions taking `pluginId` as a parameter, correctly parameterised, and
  changing them is churn.

## Git workflow

- Branch: `advisor/016-reconcile-fork-documentation`
- Conventional commits; `docs:` is correct.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Correct `AGENTS.md`'s architecture section

Change the IPC target to `t1nk33r.nearby-share`, and add a paragraph describing
the fork's surface. Keep the existing per-monitor rule intact — it governs the
Quick Share engine too:

```
- `Service.qml` owns the helper process, the transfer state machine, and the
  `t1nk33r.nearby-share` IPC target. The shell loads a `service` kind once per
  session. The IPC target must equal `manifest.id`; a test asserts it.
- `QuickShare.qml` is the second protocol engine, a singleton child of
  `Service.qml`. Unlike the LocalSend helper it drives short-lived subprocesses:
  the `qs` CLI, installed at `bin/nearby-qs`. It is never invoked as `qs` on
  PATH, because `/usr/bin/qs` is Quickshell's own CLI and either binary would
  silently shadow the other. Quick Share sends files only; it does not receive.
- `scripts/dependencies.sh`, `scripts/setup_firewall.sh` and `.githooks/post-merge`
  are the fork's install and setup surface. Anything privileged in them must be
  reachable only from an explicit user action.
```

**Verify**: `grep -c 'oma\.nearby' AGENTS.md` → `0`;
`grep -c 't1nk33r.nearby-share' AGENTS.md` → at least `2`.

### Step 2: Scope the no-new-dependencies rule honestly

The rule as written forbids what the fork deliberately does. Replace it with one
that states the exception and its reasoning, so a reviewing agent does not reject
intended work:

```
- Avoid new runtime dependencies for the LocalSend pane unless they are
  necessary and available on a stock Omarchy installation.
- The Quick Share pane is a deliberate exception: it requires the `qs` CLI,
  which is GPL-3.0, is not packaged for Arch, and is built from a pinned
  revision on the user's machine by `scripts/dependencies.sh`. It is executed as
  a separate program and never linked, which is what keeps this repository MIT.
  Do not extend that exception to further dependencies without the same
  reasoning.
```

**Verify**: `grep -c 'deliberate exception' AGENTS.md` → `1`.

### Step 3: Complete the validation block

Add the two commands CI runs that `AGENTS.md` omits, so an agent following it
runs the same suite as CI:

```sh
bash tests/updater.test.sh
```

plus any test files that have landed from other plans — check which of
`tests/dependencies.test.sh`, `tests/firewall.test.sh`,
`tests/quickshare-state.test.js` actually exist before listing them. Do not list
a file that is not there.

**Verify**: `grep -c 'tests/updater.test.sh' AGENTS.md` → `1`; every test path
listed in `AGENTS.md` exists —
`for f in $(grep -oE 'tests/[a-z-]+\.test\.(js|sh)' AGENTS.md | sort -u); do test -f "$f" || echo "MISSING: $f"; done`
→ no output.

### Step 4: Purge upstream install commands from `README.md`

For each location listed in "Current state", rewrite so only fork-correct
commands appear anywhere in the file:

- The `curl … install.sh` block: delete it. Plan 015 removed `install.sh`; the
  fork installs by `git clone` plus `scripts/setup.sh`, which the README already
  documents higher up.
- "enables `oma.nearby`" → the fork's id.
- `omarchy plugin remove oma.nearby` → `omarchy plugin remove t1nk33r.nearby-share`.
- The build-from-source block: replace the `omarchy plugin add …jfg96…` and
  `cd …/oma.nearby` lines with the fork's clone URL and directory.
- `~/.config/omarchy/plugins/oma.nearby/install.sh` → remove; point at
  `./build.sh` instead, which is what actually rebuilds the helper in this tree.
- `omarchy-shell oma.nearby updateHelper` / `status` → `t1nk33r.nearby-share`.

Keep upstream's *behavioural* prose — the discovery model, the lifecycle
section, the PIN documentation, the security notes. Those remain accurate for
the LocalSend pane and rewriting them would lose real information. Adjust the
divider text at ~line 181 so it says the section describes the LocalSend engine's
behaviour, not that its commands are usable as written.

**Verify**: `grep -rn 'oma\.nearby' README.md` → no matches;
`grep -rn 'jfg96' README.md` → only in attribution/credit contexts, not in a
command block. Inspect each remaining hit and confirm.

### Step 5: Fix the firewall rule count

Only if plan 006 has not already done it: change "Three rules, one port each" to
"Four rules, one port each" in `scripts/setup_firewall.sh`, and the banner's
"three inbound rules" likewise.

**Verify**: `grep -c 'Three rules' scripts/setup_firewall.sh` → `0`.

### Step 6: Confirm nothing regressed

**Verify**: `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js && bash tests/updater.test.sh`
→ exit 0.

## Test plan

- This plan changes documentation and one comment; there is no behaviour to test.
- The verification is the greps above plus the existing suites staying green.
- The one mechanical check worth keeping is Step 3's loop asserting every test
  path named in `AGENTS.md` exists — that is the assertion which would have
  caught the omission in the first place.

## Done criteria

ALL must hold:

- [ ] `grep -c 'oma\.nearby' AGENTS.md` returns `0`
- [ ] `grep -rn 'oma\.nearby' README.md` returns no matches
- [ ] `grep -c 'tests/updater.test.sh' AGENTS.md` returns `1`
- [ ] Every `tests/*` path named in `AGENTS.md` exists on disk
- [ ] `grep -c 'Three rules' scripts/setup_firewall.sh` returns `0`
- [ ] `AGENTS.md` mentions `QuickShare.qml`, `bin/nearby-qs`, and the GPL exception
- [ ] `node tests/model.test.js && node tests/panel-state.test.js && node tests/service-state.test.js` exits 0
- [ ] `git status --porcelain` lists only `AGENTS.md`, `README.md`, and possibly `scripts/setup_firewall.sh`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 015 has not landed, so `install.sh` still exists. Deleting its README
  references while the file remains would make the docs wrong in the other
  direction. Either land 015 first or report.
- You find a README command block whose fork-correct form you cannot determine —
  for example an `omarchy-shell` method the fork renamed. Check `Service.qml`'s
  `IpcHandler` for the real method names rather than guessing.
- Correcting `AGENTS.md`'s dependency rule appears to require a decision about
  whether the Quick Share dependency should exist at all. It exists; this plan
  documents it. The question of whether it *should* is plan 018's ADR.

## Maintenance notes

- `AGENTS.md` is the highest-leverage file in the repo for agent-executed work
  and the easiest to let drift, because nothing tests it. The one mechanical
  guard added here is that its listed test paths must exist; consider extending
  that idea if it drifts again.
- The rule for the README's upstream section: behavioural prose may stay,
  commands may not. Any future merge from upstream needs the same filter.
- Deliberately deferred: a Quick Share entry in `ROBUSTNESS.md`'s manual test
  matrix. It needs a real phone and real transfers to write honestly, and
  `AGENTS.md` explicitly forbids claiming device paths were tested when they
  were not.
