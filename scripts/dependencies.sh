#!/usr/bin/env bash
# Dependency detection and installation for the LocalSend widget.
set -uo pipefail

deps() {
  cat <<'TABLE'
wl-clipboard|Clipboard access|wl-copy|wl-clipboard
libnotify|Desktop notifications|notify-send|libnotify
TABLE
}

have() { command -v "$1" >/dev/null 2>&1; }

missing_ids() {
  local id label probe packages
  while IFS='|' read -r id label probe packages; do
    [[ -n $id ]] || continue
    have "$probe" || printf '%s\n' "$id"
  done < <(deps)
}

emit_json() {
  local id label probe packages first=1 present
  printf '{"deps":['
  while IFS='|' read -r id label probe packages; do
    [[ -n $id ]] || continue
    (( first )) || printf ','
    first=0
    present=false
    have "$probe" && present=true
    printf '{"id":"%s","label":"%s","scope":"core","present":%s}' \
      "$id" "$label" "$present"
  done < <(deps)
  printf ']}\n'
}

install_missing() {
  local id table_id label probe packages
  local -a missing=() pac=()
  mapfile -t missing < <(missing_ids)

  if (( ${#missing[@]} == 0 )); then
    echo "All Nearby Share dependencies are present."
    return 0
  fi

  for id in "${missing[@]}"; do
    while IFS='|' read -r table_id label probe packages; do
      [[ $table_id == "$id" ]] || continue
      pac+=($packages)
    done < <(deps)
  done

  cat <<EOF
============================================================
            Nearby Share Dependency Installer
============================================================
Missing: ${missing[*]}

Exact command that will be executed:
  sudo pacman -S --needed ${pac[*]}
============================================================
EOF

  if [[ -t 0 ]]; then
    printf 'Press Enter to proceed with installation, or Ctrl+C to cancel: '
    read -r _
  fi

  echo "Running pacman with root privileges..."
  sudo pacman -S --needed "${pac[@]}"
}

case "${1:---json}" in
  --json) emit_json ;;
  --check)
    mapfile -t missing < <(missing_ids)
    (( ${#missing[@]} == 0 )) && exit 0
    printf '%s\n' "${missing[@]}"
    exit 1
    ;;
  --install) install_missing ;;
  -h | --help) echo "Usage: dependencies.sh [--json | --check | --install]" ;;
  *)
    echo "dependencies.sh: unknown option: $1" >&2
    exit 2
    ;;
esac
