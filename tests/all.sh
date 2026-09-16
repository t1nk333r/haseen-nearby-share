#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

node "$ROOT_DIR/tests/model.test.js"
node "$ROOT_DIR/tests/service-state.test.js"
node "$ROOT_DIR/tests/panel-state.test.js"
# The Quick Share engine's stderr parser, exit-code mapping and dependency
# verdict. CI has run this suite since it landed while this file did not, so the
# one place a local run and CI disagreed was here.
node "$ROOT_DIR/tests/quickshare-state.test.js"
"$ROOT_DIR/tests/qml.test.sh"

# The updater test drives the real bin/nearby-update-helper, which install.sh
# fetches and build.sh does not produce. A checkout without it is not a failure.
if [[ -x $ROOT_DIR/bin/nearby-update-helper ]]; then
  "$ROOT_DIR/tests/updater.test.sh"
else
  echo "tests/all.sh: bin/nearby-update-helper is not installed, skipping updater.test.sh" >&2
fi

# The host's own manifest check. `omarchy` is a dispatcher, so on a machine
# where only the helper is installed -- or where /usr/share/omarchy/bin is not
# on PATH -- call the helper directly. Neither present is not a failure: the
# suite has to run on a machine that is not an Omarchy install.
if command -v omarchy >/dev/null; then
  omarchy plugin validate "$ROOT_DIR"
elif command -v omarchy-plugin-validate >/dev/null; then
  omarchy-plugin-validate "$ROOT_DIR"
else
  echo "tests/all.sh: no omarchy plugin validator on PATH, skipping" >&2
fi

echo "all tests passed"
