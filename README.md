# Nearby Share

LocalSend and Google Quick Share in one Omarchy panel, switched by two buttons
at the top.

> **This is a fork.** The LocalSend engine, the Rust helper and the panel it
> lives in are [jfg96/omarchy-nearby](https://github.com/jfg96/omarchy-nearby)
> (MIT), unchanged except where noted below. What this fork adds is the Quick
> Share pane, the mode switcher, dependency installation on pull, and the
> firewall script. Upstream is kept as a git remote so fixes can be rebased in.
>
> Independent project. Not affiliated with or endorsed by LocalSend, Google or
> Omarchy.

## What the fork adds

- **Two panes, one widget.** A LocalSend pane (upstream's, native, unchanged)
  and a Quick Share pane, selected by two buttons under the header. The choice
  persists in `shell.json` and applies to every monitor.
- **Quick Share sending** — device discovery, file send, the phone's
  confirmation PIN, and transfer progress.
- **Dependencies installed on pull** — a tracked `post-merge` hook notices when
  an update introduced a program the machine does not have, and opens an
  installer in a terminal.
- **Firewall rules** — one script for both protocols, `ufw` and `firewalld`.

## Quick Share: how it works, and what it cannot do

Quick Share has no library this plugin can embed the way LocalSend does.
[rquickshare](https://github.com/Martichou/rquickshare) is a Tauri app that
ignores `argv`, and `rqs_lib` is a library rather than a daemon. This pane
therefore drives [`martinalderson/qs`](https://github.com/martinalderson/qs), a
CLI over a fork of `rqs_lib`, as short-lived subprocesses.

`qs` is **GPL-3.0**. It is not vendored, redistributed or linked here -- it is
built from source on your machine by `scripts/dependencies.sh` and executed as
a separate program. This repository stays MIT.

**Sending works. Receiving is fixed in the CLI, and not yet in the pane.**
The blocker this pane documented was `qs receive`: it refused to run without a
TTY unless given `--yes`, which auto-accepts every inbound transfer on the
network with no chance to decline. That is now fixed where it belongs.
`patches/qs-events.patch` adds `--events`, a line-oriented protocol that reports
an incoming request as an event and takes an accept or decline on stdin —
defaulting to decline on every path: no answer within the timeout, a closed
stream, a malformed command, an unknown id. `scripts/dependencies.sh` clones the
pinned revision and applies that patch before building.

What remains is the consumer: a receive engine in `QuickShare.qml` that speaks
the protocol and drives the request queue and the consent column this pane
already has for LocalSend. Until it lands, the pane still sends only, and the
LocalSend pane is still the one that can receive.

Quick Share also sends files only. `rqs_lib` can carry text, but the CLI
exposes no way to hand it any -- use LocalSend for clipboard text.

### The binary is not called `qs`

`/usr/bin/qs` is Quickshell's own CLI, shipped by the package the whole Omarchy
shell runs on. Installing this `qs` onto `PATH` either shadows Quickshell's
binary or is shadowed by it, and both fail silently. The build therefore
installs it as `bin/nearby-qs` and every caller uses that absolute path.

## Install

```sh
git clone https://github.com/t1nk333r/omarchy-nearby-share.git \
  ~/.config/omarchy/plugins/t1nk33r.nearby-share
cd ~/.config/omarchy/plugins/t1nk33r.nearby-share
./scripts/setup.sh          # hooks + dependencies
omarchy plugin enable t1nk33r.nearby-share
```

`setup.sh` points `core.hooksPath` at the tracked `.githooks` directory, which
is what makes the install-on-pull hook survive a fresh clone.

The LocalSend helper is a release asset of upstream, not of this fork. Fetch it
with upstream's installer or build it with `./build.sh` (needs Rust).

### Dependencies

Everything except the Rust toolchain is usually already present on Omarchy:

```sh
sudo pacman -S --needed rustup protobuf base-devel pkgconf dbus \
                        bluez bluez-libs bluez-utils wl-clipboard libnotify
rustup default stable
```

`protobuf` is needed because `rqs_lib`'s `build.rs` compiles its `.proto` files
at build time. `bluez` is needed because Quick Share discovery uses Bluetooth
LE. `scripts/dependencies.sh --json` reports what is missing and
`--install` installs it.

`qs` is built from a pinned revision (`QS_REV` in `scripts/dependencies.sh`,
also written to `bin/nearby-qs.rev` at install time) and with `--locked`, so
everyone builds the same code from upstream's own lockfile. Bumping that
revision is a behaviour change, not a chore: `QuickShare.qml` recovers the
confirmation PIN and the progress from this binary's stderr prose, so a new
revision has to be re-checked against that parser first.

## Firewall

`scripts/setup_firewall.sh` opens four rules:

| Port | Why |
|------|-----|
| `53317/tcp` | LocalSend transfers |
| `53317/udp` | LocalSend discovery |
| `5353/udp`  | mDNS, used by both protocols |
| `53318/tcp` | Quick Share transfers |

Quick Share normally binds an ephemeral port, which would mean opening the
whole high range to the LAN. `qs --port` pins it instead, and the plugin always
passes that flag, so one port is enough. Bluetooth LE discovery does not pass
through the firewall and needs no rule.

## IPC

```sh
omarchy-shell t1nk33r.nearby-share mode              # localsend | quickshare
omarchy-shell t1nk33r.nearby-share quickshare        # switch pane
omarchy-shell t1nk33r.nearby-share localsend
omarchy-shell t1nk33r.nearby-share receiverOn        # also receiverOff, receiverToggle
omarchy-shell t1nk33r.nearby-share quickshareStatus  # deps + device count
omarchy-shell t1nk33r.nearby-share status            # LocalSend engine
omarchy-shell t1nk33r.nearby-share configProbe       # where the settings came from
```

`status` reports `configured` beside `enabled`: a receiver that is off because
it was turned off and one that is off because its settings never resolved are
two different faults, and they used to look identical from here. `source` is
which `shell.json` entry the settings were read from and where a change is
written back — `layout`, `plugins`, or `items` for a widget a drawer hosts with
no `plugins[]` marker, which the shell will not write. `configProbe` reports
what the shell actually handed the plugin, for when settings do not stick.

Changing an `IpcHandler`'s methods needs `omarchy restart shell`; the method
table binds at registration and a hot-reload does not rebuild it. QML and
`shell.json` changes hot-reload normally.

## Settings

Every setting lives in the plugin's own `~/.config/omarchy/shell.json` entry —
`receiverEnabled`, `mode`, `deviceNameMode` and `deviceName`, as declared in
`manifest.json`. There is no second copy: the persisted value *is* the effective
value, so nothing can drift and the panel's switches survive a shell restart.

The engine reads that file directly and writes through the shell's per-entry
writer, `shell.updateEntryInline`. It does not read `shell.shellConfig`, which
the third-party plugin API (`services/PluginShellApi.qml`) does not have, and it
does not call `shell.mutateShellConfig`, which the shell only offers to a plugin
that implements a whole bar. Reads and writes resolve the same entry in the same
order the shell searches — a top-level `bar.layout` object entry, else the
top-level `plugins[]` marker, else the `items[]` list of a drawer hosting the
widget — so a saved setting is the one that is read back, wherever the widget is
placed. `tests/qml.test.sh` fails if either unavailable API comes back.

## Upstream documentation

Everything below is upstream's, describing the LocalSend engine this fork
builds on. It is accurate for the LocalSend pane.

---

## Screenshots

### Discover devices

![Nearby discovering compatible devices on the local network](assets/screenshots/nearby-discovery.png)

### Send files or clipboard text

![Nearby actions for sending files or clipboard text to a selected device](assets/screenshots/nearby-send-actions.png)

## Install

Install Nearby through Omarchy's plugin manager:

```sh
omarchy plugin add https://github.com/jfg96/omarchy-nearby --enable
```

Omarchy installs the tracked plugin source. When Nearby is enabled for the first
time, its tracked launcher downloads the exact Linux x86_64 helper pinned by that
checkout, verifies its committed size and SHA256, and stores it under
`$XDG_DATA_HOME/omarchy-nearby/helpers` (falling back to
`~/.local/share/omarchy-nearby/helpers`). Later starts reuse those verified bytes
without network access. Turning the receiver off does not start the launcher and
does not download anything.

For unattended installation, add `--yes`:

```sh
omarchy plugin add https://github.com/jfg96/omarchy-nearby --enable --yes
```

Nearby never requests administrator privileges, installs packages, requires
Rust, or compiles during this flow. Helper downloads are HTTPS-only, limited to
32 MiB and staged atomically on the same filesystem as their final XDG data
location.

The widget is placed in the right section of the bar by default. Remove it with
`omarchy plugin remove oma.nearby`.

## Features

- Discover compatible devices on the local network
- Send one or more files
- Send clipboard text
- Receive files and text with explicit accept/decline controls
- Optionally require a persistent PIN for incoming text and file transfers
- Transfer progress, completion, cancellation and error states
- Native Omarchy bar widget and popup
- HTTPS LocalSend interoperability with certificate fingerprint handling
- Receiver and passive discovery remain available while enabled; active discovery
  is limited to the open popup

## Requirements

Runtime:

- Omarchy Quattro (Quickshell-based shell)
- `omarchy-file-select` for file selection, which Omarchy ships
- `wl-clipboard` (`wl-copy` / `wl-paste`) for text sharing
- `omarchy-notification-send` for desktop notifications, which Omarchy ships
- Local network connectivity for LocalSend traffic (default TCP/UDP port `53317`)

The recommended prebuilt installation supports Linux x86_64. Building from source
requires a Rust toolchain with Cargo.

## Lifecycle

- **Nearby off:** helper/backend stopped; no receiver or discovery activity.
- **Nearby on, popup closed:** receiver and passive discovery remain available.
- **Nearby on, popup open:** active discovery is added.
- **Popup closed:** active discovery and fallback work are cancelled without
  disabling receiving.

Received files are written to the user's Downloads directory. Interrupted receives
use `.nearby-*.part` files. On startup, Nearby removes only its own partial files
that are older than 24 hours.

## Incoming PIN protection

Open **Incoming PIN** from Nearby's device list to enable, change or disable
receiver PIN protection. Nearby accepts 1–64 ASCII letters, numbers, dots,
underscores, tildes and hyphens for an incoming PIN so official LocalSend
senders can transmit it reliably.

The sender must provide the correct PIN before Nearby displays the transfer,
but the local user must still explicitly Accept or Decline it. Changes apply to
new requests immediately and do not restart discovery or interrupt an already
authorized transfer. Nearby stores the PIN in
`$XDG_STATE_HOME/omarchy-nearby/settings.json` (falling back to
`~/.local/state/omarchy-nearby/settings.json`) with user-only permissions and
never displays the saved value again.

## Architecture

```text
Bar widget (Panel.qml)      one per monitor, view only
        │
        │  reads state, calls methods
        ▼
Nearby engine (Service.qml) one per shell session
        │
        ├── Model.js
        │
        └── tracked launcher → JSON over stdin/stdout
                 │
                 ▼
       verified XDG-data helper (Rust)
                 │
                 ▼
        LocalSend-compatible LAN peer
```

The bar builds one widget per screen, while the helper binds a single
LocalSend port and the `oma.nearby` IPC target can only be registered once. The
engine is therefore a `service` entry point, which the shell loads once per
session, and every bar widget is a view onto it holding nothing but its own
cursor and popup.

The Rust helper vendors a modified `localsend-rs` library. See
`THIRD_PARTY_NOTICES.md` for attribution and licensing information, and
`VENDORED_LOCALSEND_RS.md` for the local patch and maintenance record.

## Discovery model

Nearby deliberately uses a cheap-first discovery hierarchy:

1. Passive listener while Nearby is enabled.
2. Immediate multicast announcement when the popup opens.
3. Short grace period for multicast/register responses.
4. Direct HTTP probes of recently known peer IPs as hints, never as proof of availability.
5. Full subnet HTTP scan only as a last resort.

Cached peers are revalidated over the network before being treated as confirmed.
Subnet fallback uses each interface's real IPv4 netmask. Networks up to `/22` are
scanned completely; larger networks are bounded to the local `/24` of each selected
interface to avoid generating tens of thousands of probes. Subnet probing has a
global concurrency limit.

The panel also provides **Search for new devices**, which bypasses cache-hit
short-circuiting and forces the bounded subnet scan when a new peer is missing.

### iOS note

During testing, the official LocalSend Android client responded to Nearby's active
discovery immediately and consistently. LocalSend on iOS was also discovered normally
when the app was opened or brought to the foreground while Nearby was already
scanning. A specific edge case was observed when the iOS app had already been open
before Nearby started scanning: it could remain visibly open yet stop responding to
the multicast discovery round. Fully closing and reopening LocalSend on iOS restored
immediate discovery. In that stale-open state, Nearby also falls back to a cached IP
probe, or to a bounded subnet scan when no usable cache entry exists.

## Build from source

The repository and every release contain the complete source. Install the plugin
without enabling it, build the helper, then enable it:

```sh
omarchy plugin add https://github.com/jfg96/omarchy-nearby.git --yes
cd ~/.config/omarchy/plugins/oma.nearby
./build.sh
omarchy plugin enable oma.nearby
```

`build.sh` runs Cargo and installs the resulting helper at:

```text
bin/omarchy-nearby-helper
```

Generated helper binaries are not tracked in the repository. `build.sh` also
writes an ignored `bin/.nearby-local-helper` marker, and the launcher only gives
that local `bin/omarchy-nearby-helper` build priority at runtime when the marker
is present. An unmarked helper binary left behind by an older published version
is treated as legacy residue and never shadows the verified helper. Published
installations contain only the tracked launcher, repair helper and release
metadata in the checkout.

## Updates

Update the plugin normally through Omarchy:

```sh
omarchy plugin update oma.nearby
```

For unattended updates, add `--yes`. The updated checkout carries
`helper-release.env`, which pins an independently published helper by tag, asset
name, byte size, SHA256, source commit and release workflow. On the next enabled
start, the launcher verifies and reuses that helper or downloads it atomically.

Nearby states the oldest helper it can drive in `manifest.json`:

```json
"minHelperVersion": "1.2.0"
```

A helper at or above that version keeps working when plugin-only changes do not
require a new helper. Below it, Nearby stops the backend and reports which
version it needs and which one is installed. Raise `minHelperVersion` in the
same change that starts depending on a new helper.

When the helper cache needs repair, the Nearby panel offers to do it. **Retry
helper** prefetches and verifies the exact helper selected by the checkout,
without writing an executable into the plugin directory, then restarts the
receiver. The same repair is available without the popup:

```sh
omarchy-shell oma.nearby retryHelper
omarchy-shell oma.nearby status
```

## Releases

Stable plugin releases use tags such as `v1.2.0`. Helpers have an independent
cycle with tags such as `helper-v1.2.0`; these technical releases are public
prereleases, so they appear in the complete Releases list without replacing the
latest stable plugin release. A plugin checkout selects one immutable helper in
`helper-release.env` instead of shipping an ELF in its source tree.

Helpers are built only by GitHub Actions and published with a SHA256 file,
third-party license notices and a build-provenance attestation binding the bytes
to their repository, workflow, commit and helper tag. The stable plugin release
workflow independently downloads and verifies that exact referenced helper
before publishing the plugin release.

To independently verify a stable plugin release, run **Verify release** with its
exact `vX.Y.Z` tag. The workflow reads the helper metadata from that plugin tag,
downloads the helper again and checks size, SHA256, attestation signer, source
commit/ref, GitHub-hosted runner and reported version. It does not reuse the job
that published either release.

Development on `main` uses the next plugin SemVer prerelease, such as
`1.2.1-dev`, as soon as it diverges from the preceding stable tag. The Rust
package advances only when helper behavior changes; the manifest's compatibility
floor and committed helper metadata identify which helper the plugin requires.

## Tests

Frontend tests, QML lint and the host's manifest check:

```sh
bash tests/all.sh
```

Backend tests:

```sh
cargo test --manifest-path backend/Cargo.toml
cargo test --manifest-path backend/vendor/localsend-rs/Cargo.toml --features https
```

Helper distribution tests:

```sh
bash tests/launcher.test.sh
bash tests/helper-repair.test.sh
```

A larger manual interoperability and robustness checklist is kept in
`ROBUSTNESS.md`.

## Security notes

Nearby validates transfer paths and writes incoming files through temporary partial
files before atomic finalization. TLS fingerprints are used for peer connections
where the LocalSend protocol exposes them.

Incoming PIN protection is an additional authorization gate, not authenticated
pairing and not a replacement for TLS or local Accept/Decline. Three incorrect
PIN submissions from one IP cause subsequent requests from that IP to receive
LocalSend's `429 Too Many Requests` response until the receiver security state
changes or the receiver restarts.

LocalSend discovery itself is LAN discovery and should not be treated as an
authenticated pairing mechanism. Use Nearby on networks you trust.

## License

Nearby is MIT licensed. See `LICENSE`.

The vendored `localsend-rs` code is separately MIT licensed and carries its own
notices. See `THIRD_PARTY_NOTICES.md`.
