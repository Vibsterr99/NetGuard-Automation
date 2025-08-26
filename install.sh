#!/usr/bin/env bash
set -Eeuo pipefail

# require root (works when piped to sudo)
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[netguard] please run with sudo"
  exit 1
fi

# ----- settings you can override on the command line -----
PROFILE="${NETGUARD_PROFILE:-enterprise}"         # enterprise | secure | general
RUN_MENU="${NETGUARD_RUN_MENU:-0}"               # 1 = open main.sh menu after install
REPO_USER="${NETGUARD_USER:-Vibsterr99}"
REPO_NAME="${NETGUARD_REPO:-NetGuard-Automation}"
BRANCH="${NETGUARD_BRANCH:-main}"
# --------------------------------------------------------

echo "[netguard] installing prerequisites…"
apt-get update -y
apt-get install -y curl ca-certificates jq gnupg ufw fail2ban logrotate tar

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "[netguard] fetching ${REPO_USER}/${REPO_NAME}@${BRANCH}…"
curl -fsSL "https://github.com/${REPO_USER}/${REPO_NAME}/archive/refs/heads/${BRANCH}.tar.gz" -o "$TMP/src.tgz"
tar -xzf "$TMP/src.tgz" -C "$TMP"
SRC_DIR="$TMP/${REPO_NAME}-${BRANCH}"

# find script dir (supports scripts/ or Scripts/)
if [[ -d "$SRC_DIR/scripts" ]]; then
  SRC_SCRIPTS="$SRC_DIR/scripts"
elif [[ -d "$SRC_DIR/Scripts" ]]; then
  SRC_SCRIPTS="$SRC_DIR/Scripts"
else
  echo "[netguard] ERROR: couldn't find scripts/ or Scripts/ in repo."
  exit 1
fi

echo "[netguard] installing scripts to /usr/local/netguard…"
install -d /usr/local/netguard
cp -a "$SRC_SCRIPTS/." /usr/local/netguard/ 2>/dev/null || true
# normalize CRLF if any and make executable
sed -i 's/\r$//' /usr/local/netguard/*.sh 2>/dev/null || true
chmod +x /usr/local/netguard/*.sh 2>/dev/null || true

# convenience wrapper for later
cat >/usr/local/bin/netguard <<'EOF'
#!/usr/bin/env bash
exec /usr/local/netguard/main.sh "$@"
EOF
chmod +x /usr/local/bin/netguard

echo "[netguard] running stack (profile: $PROFILE)…"
BASE="/usr/local/netguard"

# UFW
if [[ -x "$BASE/ufu.sh" ]]; then "$BASE/ufu.sh" -"$PROFILE" || echo "[netguard] ufw failed (continuing)"; fi
# Fail2Ban (only if present in repo)
if [[ -x "$BASE/f2b.sh" ]]; then "$BASE/f2b.sh" -"$PROFILE" || echo "[netguard] fail2ban failed (continuing)"; fi
# ClamAV
if [[ -x "$BASE/cav.sh" ]]; then "$BASE/cav.sh" -"$PROFILE" || echo "[netguard] clamav failed (continuing)"; fi
# Suricata
if [[ -x "$BASE/suricata.sh" ]]; then "$BASE/suricata.sh" -"$PROFILE" || echo "[netguard] suricata failed (continuing)"; fi
# ELK (your elk.sh should no-op for non-enterprise when called with -"$PROFILE")
if [[ -x "$BASE/elk.sh" ]]; then "$BASE/elk.sh" -"$PROFILE" || echo "[netguard] elk failed (continuing)"; fi
# Logrotate (your file name is logrptate.sh)
if [[ -x "$BASE/logrptate.sh" ]]; then "$BASE/logrptate.sh" -"$PROFILE" || echo "[netguard] logrotate failed (continuing)"; fi

# optional: open the interactive menu after install
if [[ "$RUN_MENU" = "1" && -x "$BASE/main.sh" ]]; then
  echo "[netguard] opening menu (main.sh)…"
  /usr/local/netguard/main.sh || true
fi

echo "[netguard] done. Reopen menu anytime with: sudo netguard"
