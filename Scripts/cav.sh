#!/usr/bin/env bash
set -Eeuo pipefail

blue="\e[1;34m"; yellow="\e[1;33m"; red="\e[1;31m"; green="\e[1;32m"; reset="\e[0m"
msg()  { echo -e "${green}[+]${reset} $*"; }
warn() { echo -e "${yellow}[!]${reset} $*"; }
err()  { echo -e "${red}[x]${reset} $*" >&2; }
die()  { err "$*"; exit 1; }

PROFILE=""
INSTALL_PKGS=1                 
SHARE_PATHS=(/srv/samba /export /data)  
QUAR_DIR="/var/quarantine"     
LOG_DIR="/var/log/clamav"      
ENABLE_WEEKLY_GENERAL=1        
SYSTEMD_DIR="/etc/systemd/system"
HELPER_FULL="/usr/local/sbin/clamav-scan-full"
HELPER_CHANGED="/usr/local/sbin/clamav-scan-changed"
CONF_FILE="/etc/clamav/profile.conf"

usage() {
  cat <<EOF
ClamAV profile installer (enterprise/secure/general)

USAGE:
  sudo ./clamav.sh -enterprise [--paths "<p1 p2 ...>"] [--quar-dir /path] [--no-install]
  sudo ./clamav.sh -secure     [--paths "<p1 p2 ...>"] [--quar-dir /path] [--no-install]
  sudo ./clamav.sh -general    [--paths "<p1 p2 ...>"] [--quar-dir /path] [--no-install]

OPTIONS:
  -enterprise               File-server mode: freshclam + weekly full scan + quarantine.
  -secure                   Sensitive host mode: daily quick scans + weekly full + quarantine.
  -general                  Standard endpoint: weekly full scan (enabled by default).

  --paths "<paths...>"      Space-separated list of root directories to scan (default: ${SHARE_PATHS[*]})
  --quar-dir /path          Quarantine directory (default: ${QUAR_DIR})
  --no-install              Skip apt package installation (assume ClamAV is already installed)
  -h, --help                Show this help message.

NOTES:
  - Requires systemd. (Tested on Ubuntu/Debian; includes best-effort RHEL support.)
  - Scans use 'clamdscan' if clamd is running, otherwise fall back to 'clamscan'.
  - Logs go under ${LOG_DIR}. Infected files are moved to ${QUAR_DIR}.
EOF
}

require_root()   { [[ $EUID -eq 0 ]] || die "Please run as root (sudo)."; }
have()           { command -v "$1" &>/dev/null; }
pm_install() {
  local pkgs=("$@")
  if have apt-get; then
    msg "Installing packages with apt-get: ${pkgs[*]}"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif have dnf; then
    msg "Installing packages with dnf: ${pkgs[*]}"
    dnf install -y "${pkgs[@]}" || warn "Some packages may have different names on this distro."
  elif have yum; then
    msg "Installing packages with yum: ${pkgs[*]}"
    yum install -y "${pkgs[@]}" || warn "Some packages may have different names on this distro."
  else
    warn "No known package manager found. Please install ClamAV manually."
  fi
}

parse_args() {
  while (( $# )); do
    case "$1" in
      -enterprise) PROFILE="enterprise" ;;
      -secure)     PROFILE="secure" ;;
      -general)    PROFILE="general" ;;
      --paths)     shift; IFS=' ' read -r -a SHARE_PATHS <<< "${1:-}"; [[ -n "${SHARE_PATHS[*]:-}" ]] || die "--paths requires a value" ;;
      --quar-dir)  shift; QUAR_DIR="${1:-}"; [[ -n "$QUAR_DIR" ]] || die "--quar-dir requires a path" ;;
      --no-install) INSTALL_PKGS=0 ;;
      -h|--help|--h) usage; exit 0 ;;
      *) die "Unknown option: $1 (use -h for help)" ;;
    esac
    shift
  done
  [[ -n "$PROFILE" ]] || die "Choose one profile: -enterprise, -secure, or -general"
}

ensure_dirs() {
  mkdir -p "$LOG_DIR" "$(dirname "$HELPER_FULL")" "$SYSTEMD_DIR" "$(dirname "$CONF_FILE")" "$QUAR_DIR"
  chown root:root "$QUAR_DIR"
  chmod 700 "$QUAR_DIR"
  msg "Quarantine dir set to $QUAR_DIR (permissions 700)."
}

install_clamav() {
  (( INSTALL_PKGS )) || { warn "Skipping ClamAV package installation (--no-install)."; return; }
  local deb_pkgs=(clamav clamav-daemon)
  local rpm_pkgs=(clamav clamav-update clamav-server clamav-scanner-systemd)
  if have apt-get; then
    pm_install "${deb_pkgs[@]}"
  else
    pm_install "${rpm_pkgs[@]}"
  fi
}

enable_freshclam() {
  if systemctl list-unit-files | grep -qE '^(clamav-)?freshclam\.service'; then
    local svc="$(systemctl list-unit-files | awk '/freshclam\.service/ {print $1; exit}')"
    msg "Enabling $svc for virus signature updates"
    systemctl enable --now "$svc"
  else
    warn "No freshclam.service found; creating custom freshclam timer"
    cat > /etc/systemd/system/freshclam-run.service <<'UNIT'
[Unit]
Description=Run freshclam (update ClamAV signatures)

[Service]
Type=oneshot
ExecStart=/usr/bin/freshclam --quiet
UNIT
    cat > /etc/systemd/system/freshclam-run.timer <<'UNIT'
[Unit]
Description=Hourly ClamAV signature update (freshclam)

[Timer]
OnCalendar=hourly
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
    systemctl enable --now freshclam-run.timer
  fi
}

write_conf() {
  printf 'QUAR_DIR="%s"\n' "$QUAR_DIR" > "$CONF_FILE"
  printf 'LOG_DIR="%s"\n' "$LOG_DIR" >> "$CONF_FILE"
  printf 'PATHS=(' >> "$CONF_FILE"
  for p in "${SHARE_PATHS[@]}"; do printf '%q ' "$p" >> "$CONF_FILE"; done
  printf ')\n' >> "$CONF_FILE"
  msg "Wrote $CONF_FILE (scan paths, quarantine, log directory)."
}

write_helpers() {
  cat > "$HELPER_FULL" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/clamav/profile.conf

SCANNER="clamscan"
if command -v clamdscan &>/dev/null && systemctl is-active --quiet clamav-daemon; then
  SCANNER="clamdscan"
fi

mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/weekly-full.log"

# Common directory excludes (regex patterns)
EXC=( --exclude-dir="^/proc" --exclude-dir="^/sys" --exclude-dir="^/run" --exclude-dir="^/dev" \
      --exclude-dir="/\.snapshots/" --exclude-dir="^/var/tmp" --exclude-dir="^/var/cache" )

if [[ "$SCANNER" == "clamdscan" ]]; then
  "$SCANNER" --fdpass --recursive=yes --move="$QUAR_DIR" --log="$LOGFILE" "${EXC[@]}" "${PATHS[@]}"
else
  "$SCANNER" -r --move="$QUAR_DIR" --log="$LOGFILE" "${EXC[@]}" "${PATHS[@]}"
fi
SH
  chmod 755 "$HELPER_FULL"

  cat > "$HELPER_CHANGED" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/clamav/profile.conf

SCANNER="clamscan"
if command -v clamdscan &>/dev/null && systemctl is-active --quiet clamav-daemon; then
  SCANNER="clamdscan"
fi

mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/daily-quick.log"

# Find files changed in last 1 day (excluding system dirs)
FIND_ARGS=()
for P in "${PATHS[@]}"; do
  FIND_ARGS+=("$P")
done

# Use xargs to batch process files with ClamAV scanner
find "${FIND_ARGS[@]}" -type f -mtime -1 \
     -not -path "/proc/*" -not -path "/sys/*" -not -path "/run/*" -not -path "/dev/*" \
     -not -path "*/.snapshots/*" -print0 \
| xargs -0 -r -n 64 bash -c '
  SCANNER="$0"; shift
  if [[ "$SCANNER" == "clamdscan" ]]; then
    clamdscan --fdpass --move="'"$QUAR_DIR"'" --log="'"$LOGFILE"'" "$@"
  else
    clamscan --move="'"$QUAR_DIR"'" --log="'"$LOGFILE"'" "$@"
  fi
' "$SCANNER"
SH
  chmod 755 "$HELPER_CHANGED"
  msg "Installed helper scanners: $HELPER_FULL and $HELPER_CHANGED"
}

make_unit() {
  local name="$1" desc="$2" when="$3" exec="$4"
  local svc="${SYSTEMD_DIR}/${name}.service"
  local tim="${SYSTEMD_DIR}/${name}.timer"
  cat > "$svc" <<UNIT
[Unit]
Description=$desc
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$exec
SuccessExitStatus=0 1 2
UNIT

  cat > "$tim" <<UNIT
[Unit]
Description=Timer for: $desc

[Timer]
OnCalendar=$when
Persistent=true

[Install]
WantedBy=timers.target
UNIT
}

enable_units_enterprise() {
  make_unit "clamav-enterprise-weekly-full" \
            "ClamAV weekly full scan (enterprise)" \
            "Sun *-*-* 02:00:00" \
            "$HELPER_FULL"
  systemctl daemon-reload
  systemctl enable --now clamav-enterprise-weekly-full.timer
  msg "Enterprise: enabled weekly full scan (Sun 02:00)."
}

enable_units_secure() {
  make_unit "clamav-secure-weekly-full" \
            "ClamAV weekly full scan (secure)" \
            "Sun *-*-* 02:00:00" \
            "$HELPER_FULL"
  make_unit "clamav-secure-daily-quick" \
            "ClamAV daily quick scan of changed files (secure)" \
            "*-*-* 01:30:00" \
            "$HELPER_CHANGED"
  systemctl daemon-reload
  systemctl enable --now clamav-secure-weekly-full.timer
  systemctl enable --now clamav-secure-daily-quick.timer
  msg "Secure: enabled daily quick (01:30) and weekly full (Sun 02:00)."
}

enable_units_general() {
  make_unit "clamav-general-weekly-full" \
            "ClamAV weekly full scan (general)" \
            "Sun *-*-* 03:00:00" \
            "$HELPER_FULL"
  systemctl daemon-reload
  if (( ENABLE_WEEKLY_GENERAL )); then
    systemctl enable --now clamav-general-weekly-full.timer
    msg "General: enabled weekly full (Sun 03:00)."
  else
    warn "General: weekly timer created but not enabled."
  fi
  msg "On-demand scans available via: $HELPER_FULL (full) and $HELPER_CHANGED (quick)"
}

main() {
  require_root
  parse_args "$@"
  install_clamav
  ensure_dirs
  enable_freshclam
  write_conf
  write_helpers

  case "$PROFILE" in
    enterprise) enable_units_enterprise ;;
    secure)     enable_units_secure ;;
    general)    enable_units_general ;;
    *) die "Unknown profile: $PROFILE" ;;
  esac

  msg "Done. Logs in ${LOG_DIR}; quarantine in ${QUAR_DIR}."
}
main "$@"
