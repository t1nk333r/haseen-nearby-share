# Plan 006: Make the firewall rules match what the script tells the user

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 57c60b6..HEAD -- scripts/setup_firewall.sh README.md tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: MED — a subnet-scoped rule stops working when the user's LAN prefix
  changes (VPN, tethering, new router), which reads as "the plugin broke"
- **Depends on**: `plans/005-firewall-fail-loudly.md`
- **Category**: security
- **Planned at**: commit `57c60b6`, 2026-08-26

## Why this matters

`scripts/setup_firewall.sh` tells the user, in its opening banner, that it needs
inbound rules "on your local network". It then installs rules with no source
restriction at all. Under UFW, `ufw allow 53317/tcp` is allow-from-anywhere.
Under firewalld, `--add-port` with no `--zone` lands in whatever the default
zone is, commonly `public`.

Those rules persist across networks. A laptop configured at home carries
53317/tcp, 53317/udp, 5353/udp and 53318/tcp open to every peer on the next café
or airport network it joins — exposing the LocalSend receiver, which is enabled
by default, to arbitrary strangers. The user authorised something they were told
was narrower than what was installed.

There is a second, smaller inaccuracy in the same file: its header comment says
"Three rules, one port each" while the script installs four. `README.md`
correctly documents four.

**This plan contains a decision the maintainer may want to make differently.**
See "The decision" below — read it before starting, and honour the STOP
condition attached to it.

## The decision

Two defensible options:

- **(A) Scope the rules to the detected local prefix.** Tightest, and matches
  what the banner already claims. Cost: the rules stop matching when the machine
  moves to a different subnet, so the user must re-run the script — and re-runs
  must not pile up stale rules.
- **(B) Leave the rules global and correct the banner** to say plainly that
  these ports will be open on *every* network the machine joins. Zero behaviour
  change; the user's consent becomes informed.

**This plan implements (B), plus the option to opt into (A) via a flag.** The
reasoning: the plugin is for a roaming desktop Linux machine, silent breakage
after a network change is a worse failure mode than a documented open port, and
(B) cannot regress anyone who already ran the script. Making (A) available but
explicit means the security-conscious user gets it without the roaming user
being surprised.

If the maintainer prefers (A) as the default, that is a small edit to Step 2 —
but do not make that choice yourself. See STOP conditions.

## Current state

File: `scripts/setup_firewall.sh`. **This plan assumes plan 005 has landed**, so
the `apply_ufw` / `apply_firewalld` functions already loop over rules,
accumulate `rc`, and `return "$rc"`.

The header comment, whose count is wrong:

```bash
#!/usr/bin/env bash
# Firewall rules for Nearby Share.
#
# Three rules, one port each. The Quick Share rule is a single port rather than
# the high-port range it would otherwise need: rqs_lib binds an ephemeral port
# by default, but `qs --port` pins it, and the plugin always passes that flag.
```

The banner, which claims local-network scope:

```bash
Nearby Share needs three inbound rules on your local network:
```

(Note it also says "three" while listing four ports below it.)

The ports, as `readonly` constants at the top:

```bash
readonly LOCALSEND_PORT=53317
readonly QUICKSHARE_PORT=53318
readonly MDNS_PORT=5353
```

The dispatcher branches on `command -v ufw` then `command -v firewall-cmd`.
Note `command -v` tests for *installation*, not for which firewall is actually
enforcing — on a host with both installed, the inactive one wins the branch and
rules go to the wrong backend while the script reports success.

**Repo conventions:** full-sentence *why* comments; `set -euo pipefail` in this
file; shell tests follow `tests/updater.test.sh` (stubs on `PATH`, `mktemp`
sandbox per case). Plan 005 created `tests/firewall.test.sh` — extend it rather
than creating a second file.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Syntax check | `bash -n scripts/setup_firewall.sh` | exit 0 |
| Firewall tests | `bash tests/firewall.test.sh` | pass line, exit 0 |
| Other shell tests | `bash tests/updater.test.sh` | pass line, exit 0 |

**Never run `scripts/setup_firewall.sh` directly** — it would modify this
machine's live firewall. Everything goes through the stubbed harness.

## Scope

**In scope**:
- `scripts/setup_firewall.sh`
- `tests/firewall.test.sh` — extend
- `README.md` — only the firewall table's surrounding prose

**Out of scope** (do NOT touch):
- Failure propagation — plan 005 owns it. If it looks wrong, report; do not
  re-fix it here.
- The port numbers themselves. `QUICKSHARE_PORT=53318` is deliberately pinned to
  match what `QuickShare.qml` passes as `qs --port`; changing it here would
  silently break Quick Share. If you believe a port is wrong, STOP.
- `QuickShare.qml`, `Panel.qml`, and every other script.

## Git workflow

- Branch: `advisor/006-scope-firewall-rules`
- Conventional commits; `fix:` or `docs:` depending on the final shape — `fix:`
  is right since behaviour and text both change.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Correct the two wrong counts

In the header comment, change `Three rules, one port each.` to
`Four rules, one port each.`

In the banner here-doc, change
`Nearby Share needs three inbound rules on your local network:` to
`Nearby Share needs four inbound rules:`

**Verify**: `grep -c 'Three rules' scripts/setup_firewall.sh` → `0`;
`grep -c 'three inbound rules' scripts/setup_firewall.sh` → `0`.

### Step 2: State the actual scope in the banner

Immediately after the four-port list in the banner here-doc, and before the
existing sentence about Bluetooth LE, add:

```
These rules are not restricted by source address, so the ports stay
open on every network this machine joins -- including untrusted ones.
Pass --local to restrict them to your current network instead.
```

**Verify**: `grep -c 'every network this machine joins' scripts/setup_firewall.sh` → `1`.

### Step 3: Add the opt-in `--local` flag

At the top of the script, after the `readonly` port constants, parse a single
optional argument:

```bash
# Off by default: a source-scoped rule silently stops matching when the machine
# moves to another network, and a plugin that quietly stops working is a worse
# outcome for most users than a documented open port. Opt in when the machine
# does not roam.
scope_local=0
case "${1:-}" in
  --local) scope_local=1 ;;
  "") ;;
  -h | --help)
    echo "Usage: setup_firewall.sh [--local]"
    echo "  --local  restrict the rules to the current network's IPv4 prefix"
    exit 0
    ;;
  *)
    echo "setup_firewall.sh: unknown option: $1" >&2
    exit 2
    ;;
esac
```

Add a helper that resolves the current prefix, returning empty on failure:

```bash
# The prefix of the interface carrying the default route. Empty when it cannot
# be determined, which the caller must treat as "do not scope" rather than
# "scope to nothing".
local_prefix() {
  local dev
  dev=$(ip route show default 2>/dev/null | awk '/^default/ { print $5; exit }') || return 0
  [[ -n $dev ]] || return 0
  ip -o -f inet addr show dev "$dev" 2>/dev/null | awk '{ print $4; exit }'
}
```

**Verify**: `bash -n scripts/setup_firewall.sh` → exit 0;
`bash scripts/setup_firewall.sh --help` → prints usage, exit 0;
`bash scripts/setup_firewall.sh --nonsense; echo "exit=$?"` → `exit=2`.

### Step 4: Apply the scope when requested

In `apply_ufw`, before the rule loop, resolve the prefix once:

```bash
  local from=""
  if (( scope_local )); then
    from=$(local_prefix)
    if [[ -z $from ]]; then
      echo "Could not determine the local network prefix; refusing to guess." >&2
      return 1
    fi
    echo "Restricting rules to $from"
  fi
```

Then build each rule's argv accordingly. UFW's scoped form is
`ufw allow from <cidr> to any port <port> proto <tcp|udp>`, which differs
structurally from the unscoped `ufw allow <port>/<proto>` — so split the port
constant into number and protocol and branch:

```bash
    local number=${port%%/*}
    local proto=${port#*/}
    if [[ -n $from ]]; then
      sudo ufw allow from "$from" to any port "$number" proto "$proto" comment "$label"
    else
      sudo ufw allow "$port" comment "$label"
    fi
```

Wrap that in the same `if ! ...; then echo "  FAILED: ..." >&2; rc=1; fi` shape
plan 005 established — do not lose the failure reporting.

For `apply_firewalld`, the equivalent is to target a trusted zone rather than a
CIDR: when `scope_local` is set, pass `--zone=home` to each `--add-port` /
`--add-service` call. Do **not** attempt a rich-rule CIDR form; it is
substantially more complex and the zone mechanism is what firewalld is for.

**Verify**: `bash -n scripts/setup_firewall.sh` → exit 0.

### Step 5: Extend `tests/firewall.test.sh`

Add cases to the file plan 005 created:

1. Default (no flag): recorded `ufw` argv contains `allow 53317/tcp` and does
   **not** contain `from`.
2. `--local` with a stub `ip` on `PATH` reporting a default route and a prefix:
   recorded argv contains `from <prefix>` and `proto tcp` for each rule.
3. `--local` with a stub `ip` that produces no default route: the script exits
   non-zero and stderr mentions refusing to guess. It must not fall back to a
   global rule.
4. `--nonsense` exits 2; `--help` exits 0 and prints usage.
5. The banner names four ports and contains the "every network" sentence in the
   default case.

**Verify**: `bash tests/firewall.test.sh` → pass line, exit 0.

### Step 6: Document it

In `README.md`, in the firewall section that currently presents the four-row
port table, add two sentences after the table: that the rules are unrestricted
by default and therefore apply on every network, and that `--local` scopes them
to the current network's prefix at the cost of needing a re-run after a network
change.

**Verify**: `grep -c 'not restricted by source' README.md` → at least `1`.

## Test plan

- Extend `tests/firewall.test.sh` with the five cases in Step 5.
- Structural pattern: the cases plan 005 added to that same file.
- Case 3 is the important one — a scoping feature that silently degrades to
  "open to the world" when detection fails would be worse than not having it.
- Verification: `bash tests/firewall.test.sh` → all pass.

## Done criteria

ALL must hold:

- [ ] `bash -n scripts/setup_firewall.sh` exits 0
- [ ] `bash tests/firewall.test.sh` exits 0 with plan 005's cases still passing plus five new ones
- [ ] `bash scripts/setup_firewall.sh --help` exits 0; `--nonsense` exits 2
- [ ] `grep -c 'Three rules' scripts/setup_firewall.sh` returns `0`
- [ ] `grep -c 'every network this machine joins' scripts/setup_firewall.sh` returns `1`
- [ ] `grep -c 'not restricted by source' README.md` returns at least `1`
- [ ] `git status --porcelain` lists only `scripts/setup_firewall.sh`, `tests/firewall.test.sh`, `README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- **The maintainer has not confirmed option (B).** This plan makes global rules
  the default and scoping opt-in. If you have any signal that option (A) —
  scoped by default — is wanted instead, stop and ask rather than guessing; the
  two produce materially different security postures.
- Plan 005 has not landed, so `apply_ufw` does not have the loop-and-accumulate
  shape described in "Current state". Land 005 first.
- You conclude a port constant is wrong. `QUICKSHARE_PORT` must equal the value
  `QuickShare.qml` passes to `qs --port`; if they disagree, that is a separate
  bug — report it, do not change either.
- Any verification would touch the real firewall.

## Maintenance notes

- If `QuickShare.qml`'s `port` property ever changes, `QUICKSHARE_PORT` here must
  change with it. They are two copies of one number with no mechanical link — a
  future improvement would be to have the QML read the value from this script or
  from a shared constant, and it is deliberately not attempted here.
- `command -v ufw` tests for installation, not for which firewall is enforcing.
  On a host with both `ufw` and `firewalld` installed, the wrong backend can win
  the branch and the script still reports success. Gating on `systemctl is-active`
  as well is a known follow-up, deliberately deferred out of this plan to keep
  the scoping change reviewable on its own.
- Re-running with `--local` after a network change will add a second scoped rule
  rather than replacing the first. Rule cleanup is not implemented; note it if
  a user reports accumulating rules.
