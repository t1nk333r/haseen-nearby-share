# Third-party notices

## qs (Quick Share CLI)

The Quick Share pane executes `qs`, a CLI over a fork of `rqs_lib`.

- Project: https://github.com/martinalderson/qs
- License: GPL-3.0-or-later
- Pinned revision: `a63bc7b3`, recorded in `scripts/dependencies.sh` as
  `QS_REV` and written to `bin/nearby-qs.rev` at install time
- Build: cloned at that revision, `patches/qs-events.patch` applied, then
  `cargo install --path … --locked`, so the revision is fixed, the patch is the
  one this repository reviewed, and the dependency graph comes from upstream's
  own `Cargo.lock` rather than being re-resolved from crates.io on every run
- Underlying library: https://github.com/Martichou/rquickshare (`rqs_lib`),
  via the fork https://github.com/martinalderson/rquickshare, branch
  `feat/ble-receiver-connect-back`

`qs` is **not** vendored or linked in this repository.
`scripts/dependencies.sh` clones it at the pinned revision, applies the patch
below, and builds it on the user's own machine; the plugin invokes the resulting
binary as a separate program over its documented command-line interface.

**One exception, stated plainly.** `patches/qs-events.patch` is a diff against
that GPL-3.0-or-later program, so *as a work* it is derived from GPL-3.0-or-later
code and is carried under that licence — the patch file alone, not the
repository around it, which remains MIT. The distinction is the point: this
repository patches and **executes** a separate program, it does not link one, and
it does not ship the program itself. Building it unpatched would simply mean a
Quick Share pane that cannot receive.

## Quick Share protocol

This is an independent integration compatible with Google's Quick Share
(formerly Nearby Share). It is not affiliated with or endorsed by Google.

## localsend-rs

Nearby vendors a modified copy of `localsend-rs` as a Rust library dependency.

- Project: https://github.com/CrossCopy/localsend-rs
- Package license: MIT
- Upstream package metadata version in this tree: `0.1.2`
- Local copy: `backend/vendor/localsend-rs`

The vendored crate's own `THIRD_PARTY_NOTICES.md` is retained. The vendored copy
contains local changes used by Nearby; it should not be assumed to be identical
to an upstream release or commit unless a future release explicitly records one.
See `VENDORED_LOCALSEND_RS.md` for the local patch and maintenance record.

## LocalSend protocol

Nearby is an independent implementation/integration compatible with the
LocalSend protocol. It is not affiliated with or endorsed by the LocalSend
project. See the vendored crate's third-party notices for its protocol-related
attribution.
