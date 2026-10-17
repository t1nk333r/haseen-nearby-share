# Nearby helper: `--version` and safe diagnostics — staged, NOT built, NOT landed

## Why this is not landed

`cargo` and `rustc` 1.98.0 are installed, but the build **cannot** be done
offline on this machine and network egress was not authorised:

```
139 of the 255 registry crates in backend/Cargo.lock are absent from
~/.cargo/registry/cache — including axum, hyper, aws-lc-sys, rcgen,
x509-parser, async-stream, tokio-rustls and rustls-pemfile.
```

`cargo build --release --offline --locked` fails at resolution
(`no matching package named 'rustls-pemfile'`, a dev-dependency; stripping
dev-dependencies moves the failure to `async-stream`, a real dependency of the
vendored crate). Nothing was fetched. No binary was produced. The live
`bin/omarchy-nearby-helper` is untouched, and `backend/` in the plugin directory
is still byte-identical to upstream (`git diff 3f54d18..HEAD -- backend/` is
empty), so `install.sh` still sees a clean tree.

## What the patch does

`nearby-helper-version-and-safe-diagnostics.patch` — `git apply -p1` from the
plugin root; verified with `git apply --check` against the current tree.

1. **`--version` / `--help` are parsed before any runtime setup.**
   `main` is now a plain `fn main()` that reads argv and dispatches; the daemon
   moved to `#[tokio::main] async fn run()`. `--version` prints
   `CARGO_PKG_VERSION` and exits 0 with no Tokio runtime, no TLS identity load,
   no interface selection, no bind and no announcement. `--help` prints usage.
   An unrecognised argument prints usage to stderr and exits 2.
   Previously there was no argument parsing at all, so `--version` fell through
   to the daemon and announced this machine on every multicast-capable
   interface, tailnet included.
2. **Diagnostics and protocol output are no longer crash sites.** All 34
   `eprintln!` calls in `backend/src/main.rs` and the `emit()` stdout writer go
   through `writeln!` with the error dropped (`diag!` macro / `emit`). Same for
   the 6 `eprintln!` calls in the vendored `discovery/multicast.rs`, via a
   `diag!` macro local to that module.
3. **`VENDORED_LOCALSEND_RS.md` records the vendor patch** as local
   modification 7, with the upstream line numbers it applies to, per this
   repo's convention.

### Print-site audit

| Location | Sites | Verdict |
|---|---|---|
| `backend/src/main.rs` `eprintln!` | 34 | all on live paths (startup, discovery, announce, error reporting) — all converted |
| `backend/src/main.rs` `emit()` → `println!` | 1 | the JSON protocol channel; converted |
| `backend/vendor/.../discovery/multicast.rs` | 6 (110, 113, 215, 219, 225, 281, 329) | compiled and on the startup/announce/receive paths — all converted |
| `backend/vendor/.../src/cli/**` | 38 | **not compiled**: the helper depends on `localsend-rs` with `default-features = false, features = ["https"]`, and the `println!`s live behind the `cli` feature. Left alone. |

## Why not `SIGPIPE` → `SIG_DFL`

It would have covered the vendored crate without patching it, and it is the
wrong tool here. Rust ignores `SIGPIPE` at process start precisely so that a
write to a closed socket surfaces as `io::ErrorKind::BrokenPipe` rather than
killing the process. This helper serves HTTPS uploads to LocalSend peers that
disconnect mid-transfer, so restoring the default disposition would make every
socket write a potential process kill: a rare crash traded for a common one.
Dropping the error on the two diagnostic streams fixes the reported crash and
changes nothing about how the network paths report failure.

## The plugin's own version handshake

`Service.qml` does **not** and should not use `--version`. It reads
`helperVersion` from the `ready` event (`backend/src/main.rs`, the `emit` of
`{"event":"ready", ...}` carrying `env!("CARGO_PKG_VERSION")`) and checks it
against the manifest's `minHelperVersion` floor via `Model.helperSatisfies`.
That is the better source: it reports the version of the binary that is
actually running, not of whatever binary a probe happened to execute. This
patch adds `--version` for a human at a terminal only; nothing in the plugin
invokes it, which is why the defect needed a person to trigger it.

## What was verified without a build

- `cargo fmt --all -- --check` passes on the patched tree (exit 0).
- The new CLI logic and the `diag!` macro were extracted verbatim into a
  standalone program and compiled with `rustc --edition 2024`:
  - `--version`, `-V` → `1.1.1`, exit 0
  - `--help`, `-h` → usage, exit 0
  - no arguments → the daemon branch
  - `--bogus` → usage on stderr, exit 2
  - `--version | head -1` → exit 0
  - `--version` with an unwritable stdout (`>/dev/full`) → exit 0, no panic
  - `--bogus` with an unwritable stderr → exit 2, no panic
  - the macro is warning-clean under `-D warnings` alongside the file-level
    `use std::io::Write` that `main.rs` already has
- The failure being fixed was reproduced in isolation: a two-line program using
  `println!`/`eprintln!` compiled with `-C panic=abort`, run with
  `>/dev/full`, exits **134** (SIGABRT).

## Not verified — needs the build

- That the full crate compiles (`cargo check`, `cargo test`, `cargo clippy`).
- That `--version` binds nothing, proven the way it was asked for:
  `ss -lntup | grep 53317` empty during the run and no `interfaces selected:`
  line. **The current binary fails this test**; the patched one is expected to
  pass it but has not been run.
- That the daemon path still reaches `ready:true` with the rebuilt binary.

## To build and land

```sh
# Requires network access for ~139 crates. Ask the owner first.
cd ~/.config/omarchy/plugins/haseen.nearby-share
git apply -p1 /tmp/nearby-rust-patch/nearby-helper-version-and-safe-diagnostics.patch
CARGO_TARGET_DIR=/tmp/nearby-rust-target cargo build --release --locked --manifest-path backend/Cargo.toml
cargo test --locked --manifest-path backend/Cargo.toml
cargo test --locked --manifest-path backend/vendor/localsend-rs/Cargo.toml --features https
cargo clippy --locked --manifest-path backend/Cargo.toml -- -D warnings

# Prove the fix before replacing anything live:
stamp=$(date '+%Y-%m-%d %H:%M:%S')
/tmp/nearby-rust-target/release/omarchy-nearby-helper --version
/tmp/nearby-rust-target/release/omarchy-nearby-helper --version | head -1
ss -lntup | grep 53317 || echo "nothing bound"
coredumpctl list --since "$stamp" || echo "no coredumps"

# Only then, keeping the old binary in a staging area and not in the plugin dir:
cp -a bin/omarchy-nearby-helper /tmp/nearby-backup/omarchy-nearby-helper.$(date +%Y%m%dT%H%M%S)
install -Dm755 /tmp/nearby-rust-target/release/omarchy-nearby-helper bin/omarchy-nearby-helper
omarchy-restart-shell
omarchy-shell haseen.nearby-share status   # expect ready:true, helper:"1.1.1"
```

`bin/` is untracked (`.gitignore`), so replacing the binary is not a source
change; the patch above is.

## Interim: do not poke the current binary

Until this lands, running `bin/omarchy-nearby-helper` by hand — with **any**
arguments, `--version` included — starts the full receiver: it binds :53317 and
announces this machine on every multicast-capable interface, including
`tailscale0`. Piping it into a command that exits early additionally aborts it
with a core dump. Nothing in the plugin does this, so the live receiver is
unaffected; the hazard is a human investigating the binary.
