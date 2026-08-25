# Third-party notices

## qs (Quick Share CLI)

The Quick Share pane executes `qs`, a CLI over a fork of `rqs_lib`.

- Project: https://github.com/martinalderson/qs
- License: GPL-3.0-or-later
- Underlying library: https://github.com/Martichou/rquickshare (`rqs_lib`),
  via the fork https://github.com/martinalderson/rquickshare, branch
  `feat/ble-receiver-connect-back`

`qs` is **not** vendored, redistributed, linked or derived from in this
repository. `scripts/dependencies.sh` builds it from source on the user's own
machine, and the plugin invokes the resulting binary as a separate program over
its documented command-line interface. No GPL-licensed code is present in or
distributed by this repository.

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
