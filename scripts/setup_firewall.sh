#!/usr/bin/env bash
# Firewall rules for Nearby Share.
#
# Three rules, one port each. The Quick Share rule is a single port rather than
# the high-port range it would otherwise need: rqs_lib binds an ephemeral port
# by default, but `qs --port` pins it, and the plugin always passes that flag.
# Opening 1024-65535/tcp to the LAN would have been the alternative.
set -euo pipefail

readonly LOCALSEND_PORT=53317
readonly QUICKSHARE_PORT=53318
readonly MDNS_PORT=5353

cat <<EOF
============================================================
              Nearby Share Firewall Setup
============================================================
Nearby Share needs three inbound rules on your local network:

  ${LOCALSEND_PORT}/tcp   LocalSend transfers
  ${LOCALSEND_PORT}/udp   LocalSend discovery
  ${MDNS_PORT}/udp    mDNS -- discovery for both protocols
  ${QUICKSHARE_PORT}/tcp   Quick Share transfers (pinned via 'qs --port')

Quick Share also uses Bluetooth LE for discovery, which does not
pass through the firewall and needs no rule.
============================================================
EOF

apply_ufw() {
  cat <<EOF
Detected firewall: UFW (Uncomplicated Firewall)

Commands that will be executed:
  sudo ufw allow ${LOCALSEND_PORT}/tcp comment 'Nearby Share (LocalSend)'
  sudo ufw allow ${LOCALSEND_PORT}/udp comment 'Nearby Share (LocalSend)'
  sudo ufw allow ${MDNS_PORT}/udp comment 'Nearby Share (mDNS)'
  sudo ufw allow ${QUICKSHARE_PORT}/tcp comment 'Nearby Share (Quick Share)'
  sudo ufw reload
============================================================
EOF

  if [[ -t 0 ]]; then
    printf 'Press Enter to apply UFW rules, or Ctrl+C to cancel: '
    read -r _
  fi

  echo "Applying UFW firewall rules with root privileges..."
  sudo ufw allow "${LOCALSEND_PORT}/tcp" comment 'Nearby Share (LocalSend)'
  sudo ufw allow "${LOCALSEND_PORT}/udp" comment 'Nearby Share (LocalSend)'
  sudo ufw allow "${MDNS_PORT}/udp" comment 'Nearby Share (mDNS)'
  sudo ufw allow "${QUICKSHARE_PORT}/tcp" comment 'Nearby Share (Quick Share)'
  sudo ufw reload
}

apply_firewalld() {
  cat <<EOF
Detected firewall: firewalld

Commands that will be executed:
  sudo firewall-cmd --permanent --add-port=${LOCALSEND_PORT}/tcp
  sudo firewall-cmd --permanent --add-port=${LOCALSEND_PORT}/udp
  sudo firewall-cmd --permanent --add-service=mdns
  sudo firewall-cmd --permanent --add-port=${QUICKSHARE_PORT}/tcp
  sudo firewall-cmd --reload
============================================================
EOF

  if [[ -t 0 ]]; then
    printf 'Press Enter to apply firewalld rules, or Ctrl+C to cancel: '
    read -r _
  fi

  echo "Applying firewalld rules with root privileges..."
  sudo firewall-cmd --permanent --add-port="${LOCALSEND_PORT}/tcp"
  sudo firewall-cmd --permanent --add-port="${LOCALSEND_PORT}/udp"
  sudo firewall-cmd --permanent --add-service=mdns
  sudo firewall-cmd --permanent --add-port="${QUICKSHARE_PORT}/tcp"
  sudo firewall-cmd --reload
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
  ${LOCALSEND_PORT}/tcp, ${LOCALSEND_PORT}/udp, ${MDNS_PORT}/udp, ${QUICKSHARE_PORT}/tcp
EOF
  sleep 2
fi
