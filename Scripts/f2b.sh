#!/usr/bin/env bash
set -Eeuo pipefail

green="\e[1;32m"; yellow="\e[1;33m"; red="\e[1;31m"; reset="\e[0m"
msg()  { echo -e "${green}[+]${reset} $*"; }
warn() { echo -e "${yellow}[!]${reset} $*"; }
err()  { echo -e "${red}[x]${reset} $*" >&2; }
die()  { err "$*"; exit 1; }

MODE=""
SSH_PORT="${SSH_PORT:-22}"
IGNORE_IPS="${IGNORE_IPS:-}"

usage() {
  cat <<EOF
Usage: sudo ./f2b.sh -general | -secure | -enterprise
       -h | --help

Env:
  SSH_PORT   SSH port to protect (default: 22)
  IGNORE_IPS Space-separated allowlist (e.g. "192.168.1.0/24 1.2.3.4")
EOF
}

if [[ $# -eq 0 ]]; then usage; exit 1; fi
case "$1" in
  -general) MODE="general" ;;
  -secure) MODE="secure" ;;
  -enterprise) MODE="enterprise" ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown option: $1"; usage; exit 1 ;;
esac

[[ $EUID -eq 0 ]] || die "Please run as root (sudo)."

if ! command -v fail2ban-client >/dev/null 2>&1; then
  msg "Installing Fail2Ban..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
else
  msg "Fail2Ban is already installed."
fi

install -d /etc/fail2ban/jail.d
cat >/etc/fail2ban/jail.d/00-global.local <<CONF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
destemail = root@localhost
sender = fail2ban@localhost
ignoreip = 127.0.0.1/8 ::1 ${IGNORE_IPS}
backend = systemd
[sshd]
enabled = true
port = ${SSH_PORT}
mode = aggressive
logpath = %(sshd_log)s
CONF
msg "Writing global defaults -> /etc/fail2ban/jail.d/00-global.local"

rm -f /etc/fail2ban/jail.d/secure-*.local /etc/fail2ban/jail.d/enterprise-*.local /etc/fail2ban/jail.d/general-*.local || true
msg "Removing prior mode-specific jails (if any)..."

if [[ "$MODE" == "secure" || "$MODE" == "enterprise" ]]; then
  cat >/etc/fail2ban/jail.d/${MODE}-recidive.local <<'CONF'
[recidive]
enabled  = true
logpath  = /var/log/fail2ban.log
bantime  = 24h
findtime = 24h
maxretry = 5
action   = iptables-allports[name=recidive]
CONF
fi

systemctl daemon-reload
systemctl enable --now fail2ban

for i in {1..10}; do
  if fail2ban-client ping >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! fail2ban-client ping >/dev/null 2>&1; then
  systemctl restart fail2ban || true
  sleep 2
fi

if fail2ban-client ping >/dev/null 2>&1; then
  msg "Fail2Ban is running."
  fail2ban-client status
  fail2ban-client status sshd || true
  [[ "$MODE" != "general" ]] && fail2ban-client status recidive || true
else
  warn "Fail2Ban didn't come up yet. Recent logs:"
  journalctl -u fail2ban --no-pager -n 80 || true
fi
