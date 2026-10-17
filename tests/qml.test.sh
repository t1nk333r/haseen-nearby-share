#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OMARCHY_SOURCE=${OMARCHY_PATH:-/usr/share/omarchy}
QMLLINT_BIN=$(command -v qmllint 2>/dev/null || true)
[[ -n $QMLLINT_BIN ]] || QMLLINT_BIN=/usr/lib/qt6/bin/qmllint
QML_FILES=(Service.qml Panel.qml)

TMP=$(mktemp -d)
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# LocalSend is the widget's only transport. Keep removed Quick Share code from
# returning through an overlooked QML entry point, test, or build patch.
for removed in QuickShare.qml patches/qs-events.patch tests/quickshare-state.test.js; do
  [[ ! -e $ROOT_DIR/$removed ]] || fail "$removed must not ship with the LocalSend-only widget"
done

for source in Service.qml Panel.qml Model.js manifest.json scripts/dependencies.sh scripts/setup_firewall.sh; do
  if grep -qiE 'quick.?share|nearby-qs|rquickshare' "$ROOT_DIR/$source"; then
    fail "$source must not retain a Quick Share runtime path"
  fi
done

# The QML and the library must agree on the function set: Model.js is shared by
# the service and the widget, and a call to a name it does not export fails at
# runtime, in a signal handler, with nothing but a console warning.
while read -r fn; do
  grep -q "^function $fn(" "$ROOT_DIR/Model.js" \
    || fail "the QML calls Model.$fn but Model.js does not define it"
  grep -q "\b$fn\b" <(sed -n 's/.*module.exports = {\(.*\)}.*/\1/p' "$ROOT_DIR/Model.js") \
    || fail "Model.js defines $fn but does not export it, so the tests cannot reach it"
done < <(grep -oh 'Model\.[A-Za-z_]*(' "$ROOT_DIR"/*.qml | sed 's/.*Model\.\(.*\)(/\1/' | sort -u)

jq -e '.entryPoints.service == "Service.qml"' "$ROOT_DIR/manifest.json" >/dev/null \
  || fail "manifest.json service entry point is not Service.qml"
jq -e '.entryPoints.barWidget == "Panel.qml"' "$ROOT_DIR/manifest.json" >/dev/null \
  || fail "manifest.json barWidget entry point is not Panel.qml"

# The IPC target and the helper live on the service: it is loaded once per
# session, whereas the bar widget is built once per monitor.
grep -q 'target: "t1nk33r.nearby-share"' "$ROOT_DIR/Service.qml" \
  || fail "IpcHandler target does not match the plugin id"
grep -q 'manageIpc: false' "$ROOT_DIR/Panel.qml" \
  || fail "the bar widget must not register the service's IPC target"

# services/PluginShellApi.qml is the whole surface an installed third-party
# plugin gets. It has no shellConfig, and shell.qml only wires mutateShellConfig
# up for a manifest declaring the `bar` kind, so a call to either is a read that
# silently returns undefined or a write that silently returns false.
for forbidden in shellConfig mutateShellConfig; do
  # Comment lines are stripped first: both names are named in the notes that
  # explain why they are not used.
  found=$(sed 's://.*::' "$ROOT_DIR"/*.qml | grep -n "shell\.$forbidden" || true)
  [[ -z $found ]] || { echo "$found" >&2; fail "shell.$forbidden is not on the third-party plugin API; see Service.qml's config notes"; }
done
grep -q 'shell\.updateEntryInline' "$ROOT_DIR/Service.qml" \
  || fail "settings must be written through the sanctioned per-entry writer"

# The view's engine cannot come from the shell alone. `serviceFor()` answers on
# Omarchy's own bar, which hands a registered widget a service-capable facade;
# a replacement bar is handed `pluginShellForBarEntry` instead, which has no
# `_serviceLookup` at all, so the lookup is null by construction for the whole
# session - the icon paints the "turned off" colour over a receiver that is
# running, and nothing in the popup can start it. This is not hypothetical: it
# is what the bar on this machine did until Bridge.qml existed. So the plugin
# carries its own door, and these hold it open.
grep -q '^singleton Bridge 1\.0 Bridge\.qml$' "$ROOT_DIR/qmldir" \
  || fail "qmldir must declare the Bridge singleton the two halves share"
grep -q '^pragma Singleton$' "$ROOT_DIR/Bridge.qml" \
  || fail "Bridge.qml must be a singleton: a per-importer copy would leave the view without an engine again"
grep -q 'Component\.onCompleted: Bridge\.service = root' "$ROOT_DIR/Service.qml" \
  || fail "the service must publish itself to Bridge.qml for the bars the shell will not let the view ask"
grep -q 'if (Bridge\.service === root) Bridge\.service = null' "$ROOT_DIR/Service.qml" \
  || fail "a rebuild must not clear the registration the newer service has already made"
grep -q 'viaShell || Bridge\.service' "$ROOT_DIR/Panel.qml" \
  || fail "the view must fall back to Bridge.qml when the host has no service lookup; see Bridge.qml"
for kind in $(jq -r '.kinds[]' "$ROOT_DIR/manifest.json"); do
  [[ $kind != bar ]] || fail "this plugin does not implement a full bar; mutateShellConfig assumptions changed"
done

# qmllint: the mock-typed `bar` and host imports produce warnings on every
# plugin, so only hard errors fail the run.
if [[ -x $QMLLINT_BIN && -d $OMARCHY_SOURCE/shell/Commons ]]; then
  mkdir -p -- "$TMP/lint/qs"
  cp -- "$ROOT_DIR/Model.js" "$TMP/lint/"
  # Bridge.qml and its qmldir travel with the two files that import the
  # singleton, or qmllint reports "Bridge is not a type" for both.
  cp -- "$ROOT_DIR/Bridge.qml" "$ROOT_DIR/qmldir" "$TMP/lint/"
  for file in "${QML_FILES[@]}"; do cp -- "$ROOT_DIR/$file" "$TMP/lint/"; done
  ln -s -- "$OMARCHY_SOURCE/shell/Commons" "$TMP/lint/qs/Commons"
  ln -s -- "$OMARCHY_SOURCE/shell/Ui" "$TMP/lint/qs/Ui"
  lint_targets=()
  for file in "${QML_FILES[@]}"; do lint_targets+=("$TMP/lint/$file"); done
  "$QMLLINT_BIN" --signal-handler-parameters disable -I "$TMP/lint" \
    "${lint_targets[@]}" >"$TMP/qmllint.log" 2>&1 || {
      sed -n '1,120p' "$TMP/qmllint.log" >&2
      fail "qmllint reported errors"
    }
  ! grep -q '^Error:' "$TMP/qmllint.log" || {
    grep '^Error:' "$TMP/qmllint.log" >&2
    fail "qmllint reported errors"
  }
else
  echo "qml.test.sh: no qmllint or no omarchy shell source, skipping the lint leg" >&2
fi

echo "qml.test.sh: lint and source checks passed"
