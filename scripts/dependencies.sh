#!/usr/bin/env bash
# Dependency detection and installation for Nearby Share.
#
# One table, three consumers: the panel asks for --json to decide whether to
# offer an install button, the post-merge hook asks for --check to decide
# whether a pull left something missing, and --install does the work in a
# terminal where a sudo prompt has somewhere to appear.
set -uo pipefail

plugin_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

readonly QS_REPO="https://github.com/martinalderson/qs"
# Pinned deliberately. `cargo install --git` with no --rev tracks the default
# branch, so two users on the same plugin commit could build different binaries
# -- and cargo runs each crate's build.rs during that build. This is also the
# revision QuickShare.qml's stderr parser and exit-code mapping were written
# against, so moving it without re-checking that parser is a behaviour change.
readonly QS_REV="a63bc7b3"

# NOT installed as plain `qs`, and never invoked by bare name.
#
# /usr/bin/qs is Quickshell's CLI, shipped by the package the whole Omarchy
# shell runs on. `cargo install --root ~/.local` produces ~/.local/bin/qs,
# which either shadows Quickshell's binary or -- when /usr/bin sorts first, as
# it does by default -- is itself shadowed, so a probe for `qs` succeeds and
# then hands Quick Share arguments to Quickshell. Both outcomes are silent.
#
# The binary therefore lands in the plugin's own bin/ under a distinct name and
# every caller uses this absolute path. bin/* is gitignored, so it also stays
# out of the way of `omarchy plugin update`'s fast-forward.
readonly QS_BIN="${plugin_dir}/bin/nearby-qs"

# id|label|probe command|pacman packages|scope
#
# scope is what the dependency blocks, so the panel can say "Quick Share needs
# this" rather than reporting one undifferentiated pile. `core` breaks both
# panes; `quickshare` breaks only the Quick Share pane.
deps() {
  cat <<'TABLE'
wl-clipboard|Clipboard access|wl-copy|wl-clipboard|core
libnotify|Desktop notifications|notify-send|libnotify|core
bluez|Bluetooth stack|bluetoothctl|bluez bluez-utils|quickshare
protobuf|Protocol buffer compiler|protoc|protobuf|quickshare-build
pkgconf|Build configuration|pkgconf|pkgconf|quickshare-build
cc|C toolchain|cc|base-devel|quickshare-build
cargo|Rust toolchain|cargo|rustup|quickshare-build
qs|Quick Share CLI|qs|-|quickshare
TABLE
}

have() { command -v "$1" >/dev/null 2>&1; }

# `qs` installs to ~/.local/bin, which is not always on a non-login shell's
# PATH. Look for the file too, so a present binary is never reported missing.
have_dep() {
  local id=$1 probe=$2
  if [[ $id == qs ]]; then
    [[ -x $QS_BIN ]]
    return
  fi
  have "$probe"
}

missing_ids() {
  local id label probe pkgs scope
  while IFS='|' read -r id label probe pkgs scope; do
    [[ -n $id ]] || continue
    have_dep "$id" "$probe" || printf '%s\n' "$id"
  done < <(deps)
}

emit_json() {
  local id label probe pkgs scope first=1
  printf '{"deps":['
  while IFS='|' read -r id label probe pkgs scope; do
    [[ -n $id ]] || continue
    (( first )) || printf ','
    first=0
    local present=false
    have_dep "$id" "$probe" && present=true
    printf '{"id":"%s","label":"%s","scope":"%s","present":%s}' \
      "$id" "$label" "$scope" "$present"
  done < <(deps)
  printf ']}\n'
}

install_missing() {
  local missing
  mapfile -t missing < <(missing_ids)

  if (( ${#missing[@]} == 0 )); then
    echo "All Nearby Share dependencies are present."
    sleep 1.5
    return 0
  fi

  # Collect pacman packages for everything missing except qs, which cargo owns.
  local id label probe pkgs scope
  local -a pac=()
  local want_qs=0
  for id in "${missing[@]}"; do
    if [[ $id == qs ]]; then want_qs=1; continue; fi
    while IFS='|' read -r label probe pkgs scope; do :; done < <(
      deps | awk -F'|' -v id="$id" '$1==id {print $2"|"$3"|"$4"|"$5}'
    )
    [[ $pkgs == "-" ]] || pac+=($pkgs)
  done

  cat <<EOF
============================================================
            Nearby Share Dependency Installer
============================================================
Missing: ${missing[*]}
EOF

  if (( ${#pac[@]} )); then
    cat <<EOF

Exact command that will be executed:
  sudo pacman -S --needed ${pac[*]}
EOF
  fi

  if (( want_qs )); then
    cat <<EOF

Quick Share CLI will be built from source:
  cargo install --git $QS_REPO --rev $QS_REV --locked --root <staging>
  installed as: $QS_BIN

This compiles ~300 crates and takes several minutes on first run.
It is GPL-3.0 software from a third party, built on your machine at the
pinned revision above.
EOF
  fi

  echo "============================================================"

  if [[ -t 0 ]]; then
    printf 'Press Enter to proceed with installation, or Ctrl+C to cancel: '
    read -r _
  fi

  if (( ${#pac[@]} )); then
    echo "Running pacman with root privileges..."
    sudo pacman -S --needed "${pac[@]}" || {
      local status=$?
      echo "Package installation failed (exit code: $status)."
      sleep 2.5
      return "$status"
    }
  fi

  if (( want_qs )); then
    # rustup ships no default toolchain, so cargo exists but resolves to
    # nothing until one is selected. Installing here rather than failing in
    # the middle of the build with rustup's own error.
    if have rustup && ! rustup show active-toolchain >/dev/null 2>&1; then
      echo "Selecting a stable Rust toolchain..."
      rustup default stable || { echo "rustup failed."; sleep 2.5; return 1; }
    fi
    echo "Building the Quick Share CLI (this takes a while)..."
    local stage
    stage=$(mktemp -d "${plugin_dir}/bin/.qs-build.XXXXXX") || return 1
    # shellcheck disable=SC2064
    trap "rm -rf -- '$stage'" RETURN
    cargo install --git "$QS_REPO" --rev "$QS_REV" --locked --root "$stage" || {
      local status=$?
      echo "Building qs failed (exit code: $status)."
      sleep 2.5
      return "$status"
    }
    [[ -x $stage/bin/qs ]] || { echo "Build produced no qs binary."; sleep 2.5; return 1; }
    mkdir -p "${plugin_dir}/bin"
    mv -- "$stage/bin/qs" "$QS_BIN"
    chmod 0755 "$QS_BIN"
    # Record what was actually built, so a later run can tell the pinned
    # revision from whatever a hand-run cargo install left behind.
    printf '%s\n' "$QS_REV" > "${QS_BIN}.rev"
    echo "Installed $QS_BIN"
  fi

  echo
  echo "Dependencies installed successfully."
  sleep 1.5
}

case "${1:---json}" in
  --json) emit_json ;;
  --check)
    # Exit 0 when nothing is missing, 1 otherwise. Prints the missing ids so a
    # hook can name them without parsing JSON.
    mapfile -t m < <(missing_ids)
    (( ${#m[@]} == 0 )) && exit 0
    printf '%s\n' "${m[@]}"
    exit 1
    ;;
  --install) install_missing ;;
  -h | --help)
    echo "Usage: dependencies.sh [--json | --check | --install]"
    ;;
  *)
    echo "dependencies.sh: unknown option: $1" >&2
    exit 2
    ;;
esac
