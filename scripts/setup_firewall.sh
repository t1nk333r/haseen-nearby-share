#!/usr/bin/env bash
# Firewall rules for Nearby Share.
#
# LocalSend needs its transfer and discovery ports, plus mDNS discovery.
set -euo pipefail

readonly LOCALSEND_PORT=53317
readonly MDNS_PORT=5353

# Both appliers below are called as the condition of an `if`, and bash suspends
# `set -e` for the entire invocation in that position -- the errexit that would
# normally stop this file at the first failing command is switched off exactly
# where a failing `sudo ufw allow` matters most. It would fall through to `ufw
# reload`, whose status is usually 0, and the caller would print "Firewall rules
# applied successfully" over a firewall that is missing a rule.
#
# So each command is checked here, and the one that failed says so: a rule the
# user cannot see is a rule they cannot fix.
run_checked() {
  "$@" || {
    local status=$?
    echo "Command failed (exit code: $status): $*" >&2
    return "$status"
  }
}

cat <<EOF
============================================================
              Nearby Share Firewall Setup
============================================================
Nearby Share needs these inbound rules on your local network:

  ${LOCALSEND_PORT}/tcp   LocalSend transfers
  ${LOCALSEND_PORT}/udp   LocalSend discovery
  ${MDNS_PORT}/udp    mDNS discovery
============================================================
EOF

apply_ufw() {
  cat <<EOF
Detected firewall: UFW (Uncomplicated Firewall)

Commands that will be executed:
  sudo ufw allow ${LOCALSEND_PORT}/tcp comment 'Nearby Share (LocalSend)'
  sudo ufw allow ${LOCALSEND_PORT}/udp comment 'Nearby Share (LocalSend)'
  sudo ufw allow ${MDNS_PORT}/udp comment 'Nearby Share (mDNS)'
  sudo ufw reload
============================================================
EOF

  if [[ -t 0 ]]; then
    printf 'Press Enter to apply UFW rules, or Ctrl+C to cancel: '
    read -r _
  fi

  echo "Applying UFW firewall rules with root privileges..."
  run_checked sudo ufw allow "${LOCALSEND_PORT}/tcp" \
    comment 'Nearby Share (LocalSend)' || return $?
  run_checked sudo ufw allow "${LOCALSEND_PORT}/udp" \
    comment 'Nearby Share (LocalSend)' || return $?
  run_checked sudo ufw allow "${MDNS_PORT}/udp" \
    comment 'Nearby Share (mDNS)' || return $?
  run_checked sudo ufw reload || return $?
}

apply_firewalld() {
  cat <<EOF
Detected firewall: firewalld

Commands that will be executed:
  sudo firewall-cmd --permanent --add-port=${LOCALSEND_PORT}/tcp
  sudo firewall-cmd --permanent --add-port=${LOCALSEND_PORT}/udp
  sudo firewall-cmd --permanent --add-service=mdns
  sudo firewall-cmd --reload
============================================================
EOF

  if [[ -t 0 ]]; then
    printf 'Press Enter to apply firewalld rules, or Ctrl+C to cancel: '
    read -r _
  fi

  echo "Applying firewalld rules with root privileges..."
  run_checked sudo firewall-cmd --permanent \
    --add-port="${LOCALSEND_PORT}/tcp" || return $?
  run_checked sudo firewall-cmd --permanent \
    --add-port="${LOCALSEND_PORT}/udp" || return $?
  run_checked sudo firewall-cmd --permanent --add-service=mdns || return $?
  run_checked sudo firewall-cmd --reload || return $?
}

if command -v ufw >/dev/null 2>&1; then
  if apply_ufw; then
    echo
    echo "Firewall rules applied successfully."
    sleep 1.5
  else
    status=$?
    echo
    echo "Failed to configure UFW rules (exit code: $status)."
    sleep 2.5
    exit "$status"
  fi
elif command -v firewall-cmd >/dev/null 2>&1; then
  if apply_firewalld; then
    echo
    echo "Firewall rules applied successfully."
    sleep 1.5
  else
    status=$?
    echo
    echo "Failed to configure firewalld rules (exit code: $status)."
    sleep 2.5
    exit "$status"
  fi
else
  cat <<EOF
No supported firewall service (ufw / firewalld) detected.

If you use iptables or nftables directly, allow inbound:
  ${LOCALSEND_PORT}/tcp, ${LOCALSEND_PORT}/udp, ${MDNS_PORT}/udp
EOF
  sleep 2
fi
