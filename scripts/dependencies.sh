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
# The receive patch, and what it buys: `--events` plus the consent timeout it
# implies. Without it a panel cannot answer Quick Share's consent question at
# all — the CLI declines every inbound transfer it cannot prompt for.
readonly PATCH_QS_EVENTS="${plugin_dir}/patches/qs-events.patch"

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
#
# `iw` is listed because the radio probe below reads it, not because the CLI
# calls it: without the row, a machine missing `iw` would be told its driver has
# no Wi-Fi Direct and offered nothing to install, when the fix is a package.
deps() {
  cat <<'TABLE'
wl-clipboard|Clipboard access|wl-copy|wl-clipboard|core
libnotify|Desktop notifications|notify-send|libnotify|core
bluez|Bluetooth stack|bluetoothctl|bluez bluez-utils|quickshare
iw|Wi-Fi Direct tooling|iw|iw|quickshare
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

# Radio capability, for the Quick Share half only.
#
# Quick Share finds a phone over Bluetooth LE and moves the bytes over Wi-Fi,
# so a machine with every dependency installed but the radio down can do
# nothing -- which is the ordinary state of a desktop that lives on Ethernet.
# The engine gates on this probe rather than on a hand-set flag, so the pane
# comes back by itself on the day the radio does, with no edit anywhere.
#
# `ready` is the whole verdict; `reason` is the sentence the pane shows. It is
# written here rather than in QML so both halves of the plugin word it the same.
#
# The two values that reach this JSON from outside -- the interface name and the
# sentence built from it -- go through json_str. An interface name is
# kernel-constrained and cannot hold a quote or a backslash, but the cost of
# being wrong is a pane that renders nothing at all, and one parameter expansion
# is cheaper than that bet.
json_str() {
  local text=$1
  text=${text//\\/\\\\}
  text=${text//\"/\\\"}
  printf '%s' "$text"
}

radio_json() {
  local bt_present=false bt_powered=false
  local wifi_iface="" wifi_up=false wifi_connected=false wifi_p2p=false
  local reason=""

  if compgen -G "/sys/class/bluetooth/hci*" >/dev/null 2>&1; then
    bt_present=true
    local bt_show
    bt_show=$(timeout 5 bluetoothctl show 2>/dev/null)
    [[ $bt_show == *"Powered: yes"* ]] && bt_powered=true
  fi

  local entry iface=""
  for entry in /sys/class/net/wl*; do
    [[ -e $entry ]] || continue
    iface="${entry##*/}"
    break
  done

  # Matched with [[ … ]] over captured output, never `producer | grep -q`:
  # under `set -o pipefail`, grep -q exits on its first match, the writer takes
  # SIGPIPE, and the pipeline reports 141 — which reads exactly like "capability
  # absent" for any output still in flight. That is how a P2P-capable card got
  # reported as incapable the first time this probe was written.
  if [[ -n $iface ]]; then
    wifi_iface="$iface"
    # Administrative state, not carrier state: a Wi-Fi Direct group is created
    # by a radio that is switched on, and it does not need the interface to be
    # associated with anything. IFF_UP is bit 0 of the flags word.
    local flags link phy info
    flags=$(cat "/sys/class/net/$iface/flags" 2>/dev/null)
    (( flags & 0x1 )) && wifi_up=true
    link=$(timeout 5 iw dev "$iface" link 2>/dev/null)
    [[ $link == "Connected to"* ]] && wifi_connected=true
    phy=$(basename "$(readlink -f "/sys/class/net/$iface/phy80211" 2>/dev/null)" 2>/dev/null)
    if [[ -n $phy ]]; then
      info=$(timeout 5 iw phy "$phy" info 2>/dev/null)
      [[ $info == *"P2P-GO"* ]] && wifi_p2p=true
    fi
  fi

  # The first failing condition, in the order a person would check them.
  #
  # Each of the two tools that is not on every machine is tested immediately
  # before the reading it produces, so its absence is never reported as the
  # hardware verdict it mimics: with no bluetoothctl, `bt_powered` stays false
  # and reads as "the adapter is powered off"; with no iw, `wifi_p2p` stays
  # false and reads as "the driver does not support Wi-Fi Direct". A sysfs fact
  # (adapter present, interface present, radio administratively up) still comes
  # first -- it is true regardless of what is installed, and it is the answer a
  # machine with no Wi-Fi hardware needs.
  if   [[ $bt_present == false ]]; then reason="no Bluetooth adapter is present"
  elif ! have bluetoothctl;      then reason="bluetoothctl is not installed"
  elif [[ $bt_powered == false ]]; then reason="the Bluetooth adapter is powered off"
  elif [[ -z $wifi_iface ]];     then reason="this machine has no Wi-Fi interface"
  elif [[ $wifi_up == false ]];  then reason="the Wi-Fi radio ($wifi_iface) is down"
  elif ! have iw;                then reason="iw is not installed"
  elif [[ $wifi_p2p == false ]]; then reason="the Wi-Fi driver ($wifi_iface) does not support Wi-Fi Direct"
  fi

  printf '"radio":{"bluetooth":{"present":%s,"powered":%s},"wifi":{"iface":"%s","up":%s,"connected":%s,"p2p":%s},"ready":%s,"reason":"%s"}' \
    "$bt_present" "$bt_powered" "$(json_str "$wifi_iface")" "$wifi_up" "$wifi_connected" "$wifi_p2p" \
    "$([[ -z $reason ]] && echo true || echo false)" "$(json_str "$reason")"
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
  printf '],'
  radio_json
  printf '}\n'
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
  #
  # The accumulation is inside the `while`, not after it: `read` assigns every
  # variable it names on every call, including the one that hits EOF, and it
  # clears them there. Reading the table after the loop therefore read the empty
  # string, matched nothing against the `-` sentinel, added no package, and made
  # this script's headline `--install` path a silent no-op for every input.
  #
  # The table is matched in shell rather than through an `awk` filter, which is
  # what it used to be: that program's last field carried an unbalanced quote
  # ("$5""), so it was a syntax error on every awk, printed nothing, and left
  # the list empty even once the accumulation was moved into the loop. A second
  # language embedded in single quotes is not worth the parse.
  local id tid label probe pkgs scope
  local -a pac=()
  local want_qs=0
  for id in "${missing[@]}"; do
    if [[ $id == qs ]]; then want_qs=1; continue; fi
    while IFS='|' read -r tid label probe pkgs scope; do
      [[ $tid == "$id" ]] || continue
      # Unquoted on purpose: the table's package field holds space-separated
      # names ("bluez bluez-utils"), and pacman wants them as separate words.
      [[ $pkgs == "-" ]] || pac+=($pkgs)
    done < <(deps)
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
  git clone $QS_REPO → checkout $QS_REV → apply patches/qs-events.patch
  cargo install --path <clone> --locked --root <staging>
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
    local stage src
    stage=$(mktemp -d "${plugin_dir}/bin/.qs-build.XXXXXX") || return 1
    src=$(mktemp -d "${plugin_dir}/bin/.qs-src.XXXXXX") || return 1
    # shellcheck disable=SC2064
    trap "rm -rf -- '$stage' '$src'" RETURN
    # Cloned and patched rather than `cargo install --git`: the event protocol
    # in patches/qs-events.patch is what lets the widget answer Quick Share's
    # consent prompt without owning a terminal, and `--locked` keeps the
    # dependency graph on upstream's own lockfile. A failed apply is a hard
    # stop, not a warning — building unpatched would silently drop receive back
    # to the TTY-only path that cannot be driven from a panel at all.
    git clone --quiet "$QS_REPO" "$src" || {
      echo "Cloning the Quick Share CLI failed."
      sleep 2.5
      return 1
    }
    git -C "$src" checkout --quiet "$QS_REV" || {
      echo "The pinned revision $QS_REV is not in that clone."
      sleep 2.5
      return 1
    }
    git -C "$src" apply "$PATCH_QS_EVENTS" || {
      echo "$PATCH_QS_EVENTS does not apply to $QS_REV — refusing to build an unpatched CLI."
      sleep 2.5
      return 1
    }
    cargo install --path "$src" --locked --root "$stage" || {
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
