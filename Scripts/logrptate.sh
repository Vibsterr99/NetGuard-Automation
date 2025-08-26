#!/usr/bin/env bash
set -Eeuo pipefail

green="\e[1;32m"; yellow="\e[1;33m"; red="\e[1;31m"; blue="\e[1;34m"; reset="\e[0m"
msg()  { echo -e "${green}[+]${reset} $*"; }
info() { echo -e "${blue}[*]${reset} $*"; }
warn() { echo -e "${yellow}[!]${reset} $*"; }
err()  { echo -e "${red}[x]${reset} $*" >&2; }
die()  { err "$*"; exit 1; }

MODE=""

usage() {
  cat <<'EOF'
Usage: sudo ./logrotate.sh -general | -secure | -enterprise
       -h | --help

Sets up log rotation for NetGuard-related logs:
  - Fail2Ban  : /var/log/fail2ban.log
  - ClamAV    : /var/log/clamav/*.log
  - Suricata  : /var/log/suricata/*.log and *.json
  - Wazuh/OSSEC:
       /var/ossec/logs/alerts.log
       /var/ossec/logs/alerts/alerts.json

Notes:
  - General  : conservative retention, lightweight
  - Secure   : moderate retention, same cadence
  - Enterprise: longer retention for central server
EOF
}

if [[ $# -eq 0 ]]; then usage; exit 1; fi
case "$1" in
  -general)    MODE="general" ;;
  -secure)     MODE="secure" ;;
  -enterprise) MODE="enterprise" ;;
  -h|--help)   usage; exit 0 ;;
  *) usage; die "Unknown option: $1" ;;
esac

[[ $EUID -eq 0 ]] || die "Please run as root."

case "$MODE" in
  general)
    ROT_F2B=8       
    ROT_CLAM=4      
    ROT_SURI=6      
    ROT_WAZUH=4     
    ;;
  secure)
    ROT_F2B=12
    ROT_CLAM=6
    ROT_SURI=8
    ROT_WAZUH=6
    ;;
  enterprise)
    ROT_F2B=16
    ROT_CLAM=8
    ROT_SURI=12
    ROT_WAZUH=8
    ;;
esac

info "Applying logrotate policies for mode: ${MODE}"

cat > /etc/logrotate.d/fail2ban <<CONF
/var/log/fail2ban.log {
    weekly
    rotate ${ROT_F2B}
    copytruncate
    missingok
    notifempty
    compress
}
CONF
msg "Configured: /etc/logrotate.d/fail2ban  (rotate=${ROT_F2B} weekly)"


cat > /etc/logrotate.d/clamav <<CONF
/var/log/clamav/*.log {
    weekly
    rotate ${ROT_CLAM}
    copytruncate
    missingok
    notifempty
    compress
}
CONF
msg "Configured: /etc/logrotate.d/clamav   (rotate=${ROT_CLAM} weekly)"

if [[ "$MODE" != "general" ]]; then
  cat > /etc/logrotate.d/suricata <<CONF
/var/log/suricata/*.log /var/log/suricata/*.json {
    weekly
    rotate ${ROT_SURI}
    dateext
    copytruncate
    missingok
    notifempty
    compress
}
CONF
  msg "Configured: /etc/logrotate.d/suricata (rotate=${ROT_SURI} weekly, dateext)"
else
  warn "Skipping Suricata rotation in 'general' mode."
fi

if [[ "$MODE" != "general" ]]; then
  cat > /etc/logrotate.d/ossec <<'CONF'
/var/ossec/logs/alerts.log /var/ossec/logs/alerts/alerts.json {
    weekly
    rotate 6
    notifempty
    missingok
    compress
    postrotate
        /var/ossec/bin/ossec-control restart > /dev/null 2>&1 || true
    endscript
}
CONF

  if [[ "$MODE" == "enterprise" ]]; then
    sed -i 's/rotate 6/rotate '"$ROT_WAZUH"'/g' /etc/logrotate.d/ossec || true
  elif [[ "$MODE" == "secure" && "$ROT_WAZUH" != "6" ]]; then
    sed -i 's/rotate 6/rotate '"$ROT_WAZUH"'/g' /etc/logrotate.d/ossec || true
  fi

  msg "Configured: /etc/logrotate.d/ossec   (rotate=${ROT_WAZUH} weekly, restart logger)"
else
  warn "Skipping Wazuh/OSSEC rotation in 'general' mode."
fi

msg "Custom log rotation policies installed for mode '${MODE}'."
