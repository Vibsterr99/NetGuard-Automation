#!/usr/bin/env bash
set -Eeuo pipefail

MODE=""
SSH_PORT="${SSH_PORT:-22}" 

log()   { echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn()  { echo -e "\e[1;33m[WARN]\e[0m $*"; }
err()   { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; }
die()   { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
UFW profile switcher for NetGuard hosts

Usage:
  sudo ./ufw.sh -enterprise
  sudo ./ufw.sh -secure
  sudo ./ufw.sh -general
  sudo ./ufw.sh -h|--help

Modes
  -enterprise   Default deny inbound, allow outbound. Open required SIEM ports:
                ${SSH_PORT}/tcp (SSH, rate-limited), 5601/tcp (Kibana/Wazuh UI),
                1514/tcp (Wazuh agent), 1515/tcp (Wazuh registration),
                19999/tcp (Netdata dashboard), 3000/tcp (Grafana, optional).
                Logging: medium. IPv6 mirrored (sets IPV6=yes in UFW config).
  -secure       Default deny inbound, allow outbound. Only open minimal ports:
                ${SSH_PORT}/tcp (SSH, rate-limited) and 5601/tcp (if using the dashboard).
                Adjust inside script to add other ports if needed. Logging: low. IPv6 mirrored.
  -general      Baseline: deny incoming, allow outgoing, limit SSH, low logging.
                No application ports opened by default. IPv6 mirrored.

Notes
  - Script is idempotent: it resets and reapplies the selected profile on each run.
  - "SSH limit" uses UFW’s rate-limiter for basic brute-force protection.
  - To mirror IPv6 rules, /etc/default/ufw must have IPV6=yes (this script enables it if run as root).
EOF
}

if [[ $# -eq 0 ]]; then usage; die "No mode specified"; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -enterprise) MODE="enterprise"; shift ;;
    -secure)     MODE="secure";     shift ;;
    -general)    MODE="general";    shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "Unknown flag: $1 (see -h)" ;;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root (sudo)."

if grep -q '^IPV6=no' /etc/default/ufw 2>/dev/null; then
  warn "Enabling IPv6 in /etc/default/ufw (IPV6=yes) to mirror rules for IPv6."
  sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
fi

log "Resetting UFW..."
ufw --force reset >/dev/null

log "Setting default policies (deny incoming, allow outgoing)..."
ufw default deny incoming   >/dev/null
ufw default allow outgoing  >/dev/null

log "Applying SSH rate limit on port ${SSH_PORT}..."
ufw limit ${SSH_PORT}/tcp >/dev/null

case "$MODE" in
  enterprise)
    log "Applying ENTERPRISE profile rules..."
    ufw allow 5601/tcp    >/dev/null   
    ufw allow 1514/tcp    >/dev/null   
    ufw allow 1515/tcp    >/dev/null   
    ufw allow 19999/tcp   >/dev/null   
    ufw allow 3000/tcp    >/dev/null   
    ufw logging medium    >/dev/null
    ;;
  secure)
    log "Applying SECURE profile rules (minimal exposure)..."
    ufw allow 5601/tcp    >/dev/null  
    ufw logging low       >/dev/null
    ;;
  general)
    log "Applying GENERAL profile rules (no external services)..."
    ufw logging low       >/dev/null
    ;;
  *)
    die "Internal error: unknown MODE '$MODE'"
    ;;
esac

log "Enabling UFW..."
ufw --force enable >/dev/null

log "Current UFW status:"
ufw status verbose
