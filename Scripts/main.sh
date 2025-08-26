#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(dirname "$0")"

msg()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[x]\033[0m $*"; }
die()  { err "$*"; exit 1; }

echo "Select a security profile:"
echo "  [1] General (Basic) - Minimal protection for single host"
echo "  [2] Secure (One PC) - Enhanced security with local SIEM"
echo "  [3] Enterprise (Network) - Full stack for multi-host/network"
read -rp "Enter choice (1-3): " choice
case "$choice" in
  1) PROFILE="general" ;;
  2) PROFILE="secure" ;;
  3) PROFILE="enterprise" ;;
  *) echo "Invalid choice. Exiting."; exit 1 ;;
esac

read -rp "SSH port [default 22]: " ssh_port
SSH_PORT="${ssh_port:-22}"

read -rp "Whitelist IPs for Fail2Ban (space-separated, or press Enter for none): " ignore_ips
IGNORE_IPS="$ignore_ips"

IFACE="eth0"
HOME_NET=""
read -rp "Network interface for Suricata to monitor [default: eth0]: " suricata_iface
IFACE="${suricata_iface:-eth0}"
read -rp "HOME_NET for Suricata (e.g. 192.168.1.0/24) [press Enter for default any]: " homenet
HOME_NET="$homenet"

export SSH_PORT IGNORE_IPS IFACE HOME_NET 

echo -e "\n[STEP 1] Configuring UFW firewall..."
"$BASE_DIR/ufw.sh" -"$PROFILE" || { warn " UFW script failed."; exit 1; }

echo -e "\n[STEP 2] Installing and configuring Fail2Ban..."
"$BASE_DIR/f2b.sh" -"$PROFILE" || { warn " Fail2Ban script failed."; exit 1; }

echo -e "\n[STEP 3] Installing ClamAV and scheduling scans..."
"$BASE_DIR/cav.sh" -"$PROFILE" || { warn " ClamAV script failed."; exit 1; }

echo -e "\n[STEP 4] Installing Suricata IDS..."
"$BASE_DIR/suricata.sh" -"$PROFILE" || { warn " Suricata script failed."; exit 1; }

echo -e "\n[STEP 5] Installing ELK Stack..."
"$BASE_DIR/elk.sh" -"$PROFILE" || { warn " Elk script failed."; exit 1; }

echo -e "\n[STEP 6] Configuring log rotation for security logs..."
"$BASE_DIR/logrotate.sh" -"$PROFILE" || { warn " Logrotate config script failed."; exit 1; }

echo -e "\nNetGuard installation for '$PROFILE' profile is complete."