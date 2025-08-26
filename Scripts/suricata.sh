#!/usr/bin/env bash
set -Eeuo pipefail

green="\e[1;32m"; yellow="\e[1;33m"; red="\e[1;31m"; reset="\e[0m"
msg()  { echo -e "${green}[+]${reset} $*"; }
warn() { echo -e "${yellow}[!]${reset} $*"; }
err()  { echo -e "${red}[x]${reset} $*" >&2; }
die()  { err "$*"; exit 1; }

IFACE="${IFACE:-eth0}"
HOME_NET="${HOME_NET:-}"
MODE=""

usage() {
  cat <<EOF
Usage: sudo ./suricata.sh -general | -secure | -enterprise
       -h | --help

Modes:
  -general      (Basic) Suricata not installed (IDS skipped in General profile).
  -secure       (One PC) Install Suricata IDS (alert-only mode).
  -enterprise   (Network) Install Suricata IDS (alert-only by default; IPS later if desired).

Env overrides:
  IFACE    (default: eth0) Network interface for Suricata to monitor.
  HOME_NET (optional CIDR) Define HOME_NET in Suricata config (e.g., 192.168.1.0/24).

Notes:
  - IDS by default (no packet drop). For IPS you must add NFQUEUE/iptables and tune rules.
  - UFW should allow only what your stack needs; Suricata itself does not open ports.
EOF
}

if [[ $# -eq 0 ]]; then usage; exit 1; fi
case "$1" in
  -general|-secure|-enterprise) MODE="${1#-}" ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown option: $1"; usage; exit 1 ;;
esac

[[ $EUID -eq 0 ]] || die "Please run as root (sudo)."

if [[ "$MODE" == "general" ]]; then
  msg "General profile: Suricata is not included. Skipping installation."
  exit 0
fi

if ! command -v suricata >/dev/null 2>&1; then
  msg "Installing Suricata..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y suricata
else
  msg "Suricata is already installed."
fi

if [[ -n "$HOME_NET" ]]; then
  sed -i -E "s#^( *HOME_NET: ).*#\1[${HOME_NET}]#" /etc/suricata/suricata.yaml || true
  msg "Set HOME_NET to ${HOME_NET} in /etc/suricata/suricata.yaml."
fi

if grep -q "SURICATA_ARGS" /etc/default/suricata 2>/dev/null; then
  sed -i -E "s#^SURICATA_ARGS=\"-i .+\"#SURICATA_ARGS=\"-i ${IFACE}\"#" /etc/default/suricata || true
elif grep -q "INTERFACE" /etc/default/suricata 2>/dev/null; then
  sed -i -E "s#^INTERFACE=.*#INTERFACE=\"${IFACE}\"#" /etc/default/suricata || true
fi
msg "Configured Suricata to monitor interface: ${IFACE}"

sed -i -E "s#(^|^ *|.*)(detect-profile: ).*#\2medium#" /etc/suricata/suricata.yaml || true
sed -i -E "s#(^|^ *|.*)(runmode: ).*#\2workers#" /etc/suricata/suricata.yaml || true
msg "Set detect-profile=medium, runmode=workers."

suricata-update || true
if [[ ! -f /etc/cron.daily/suricata-update ]]; then
  cat > /etc/cron.daily/suricata-update <<'CRON'
#!/usr/bin/env bash
set -e
suricata-update && systemctl restart suricata
CRON
  chmod +x /etc/cron.daily/suricata-update
  msg "Installed daily Suricata rule update cron."
fi

if [[ "$MODE" == "enterprise" ]]; then
  YAML="/etc/suricata/suricata.yaml"
  if grep -q '^# BEGIN NETGUARD' "$YAML"; then
    awk 'BEGIN{rm=0} /^# BEGIN NETGUARD/{rm=1} rm==0{print} /^# END NETGUARD/{rm=0}' "$YAML" > "${YAML}.tmp" && mv "${YAML}.tmp" "$YAML"
  fi

  cat >> "$YAML" <<'NG'
unix-command:
  enabled: yes

outputs:
  - eve-log:
      enabled: yes
      filetype: regular
      filename: /var/log/suricata/eve.json
      community-id: true
      community-id-seed: 0
      types:
        - alert
        - dns
        - http
        - tls
        - ssh
        - anomaly
        - flow
        - stats
# END NETGUARD
NG

  msg "Enterprise: enabled unix-command and richer eve.json (alerts,dns,http,tls,ssh,anomaly,flow,stats) with community-id."

  if [[ -f /var/ossec/etc/ossec.conf ]]; then
    OSSEC="/var/ossec/etc/ossec.conf"
    if ! grep -q '/var/log/suricata/eve.json' "$OSSEC"; then
      sed -i 's#</ossec_config>#  <localfile>\n    <location>/var/log/suricata/eve.json</location>\n    <log_format>json</log_format>\n  </localfile>\n</ossec_config>#' "$OSSEC" || true
      systemctl restart wazuh-agent 2>/dev/null || true
      msg "Enterprise: added Wazuh <localfile> to ingest /var/log/suricata/eve.json (json)."
    else
      msg "Enterprise: Wazuh already ingesting Suricata eve.json."
    fi
  else
    warn "Wazuh agent not detected; skipping Suricata→Wazuh integration."
  fi
fi

systemctl enable suricata >/dev/null
systemctl restart suricata

msg "Suricata setup complete for '${MODE}' profile. Running in IDS (alert-only) on ${IFACE}."
msg "(For IPS mode, add NFQUEUE rules and tune drop-enabled rules later.)"
