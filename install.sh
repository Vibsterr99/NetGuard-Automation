ure#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[netguard] please run with sudo"
  exit 1
fi

PROFILE="${NETGUARD_PROFILE:-enterprise}"
REPO_USER="${NETGUARD_USER:-Vibsterr99}"
REPO_NAME="${NETGUARD_REPO:-NetGuard-Automation}"
BRANCH="${NETGUARD_BRANCH:-main}"

echo "[netguard] installing prerequisites…"
apt-get update -y
apt-get install -y curl ca-certificates jq gnupg ufw fail2ban logrotate tar

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "[netguard] fetching ${REPO_USER}/${REPO_NAME}@${BRANCH}…"
curl -fsSL "https://github.com/${REPO_USER}/${REPO_NAME}/archive/refs/heads/${BRANCH}.tar.gz" -o "$TMP/src.tgz"
tar -xzf "$TMP/src.tgz" -C "$TMP"
SRC_DIR="$TMP/${REPO_NAME}-${BRANCH}"

echo "[netguard] installing scripts to /usr/local/netguard…"
install -d /usr/local/netguard
cp -a "$SRC_DIR/scripts/." /usr/local/netguard/ 2>/dev/null || true
sed -i 's/\r$//' /usr/local/netguard/*.sh 2>/dev/null || true
chmod +x /usr/local/netguard/*.sh 2>/dev/null || true

cat >/usr/local/bin/netguard <<'EOF'
#!/usr/bin/env bash
exec /usr/local/netguard/main.sh "$@"
EOF
chmod +x /usr/local/bin/netguard

echo "[netguard] running stack (profile: $PROFILE)…"
BASE="/usr/local/netguard"

# UFW
if [[ -x "$BASE/ufu.sh" ]]; then "$BASE/ufu.sh" -"$PROFILE" || echo "[netguard] ufw failed"; fi
# Fail2Ban
if [[ -x "$BASE/f2b.sh" ]]; then "$BASE/f2b.sh" -"$PROFILE" || echo "[netguard] fail2ban failed"; fi
# ClamAV
if [[ -x "$BASE/cav.sh" ]]; then "$BASE/cav.sh" -"$PROFILE" || echo "[netguard] clamav failed"; fi
# Suricata
if [[ -x "$BASE/suricata.sh" ]]; then "$BASE/suricata.sh" -"$PROFILE" || echo "[netguard] suricata failed"; fi
# ELK (elk.sh should no-op if profile != enterprise)
if [[ -x "$BASE/elk.sh" ]]; then "$BASE/elk.sh" -"$PROFILE" || echo "[netguard] elk failed"; fi
# Logrotate
if [[ -x "$BASE/logrptate.sh" ]]; then "$BASE/logrptate.sh" -"$PROFILE" || echo "[netguard] logrotate failed"; fi

echo "[netguard] done. Use 'sudo netguard' anytime to open the menu."
