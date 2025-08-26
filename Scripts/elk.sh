#!/usr/bin/env bash
set -Eeuo pipefail

green="\e[1;32m"; yellow="\e[1;33m"; red="\e[1;31m"; blue="\e[1;34m"; reset="\e[0m"
msg()  { echo -e "${green}[+]${reset} $*"; }
info() { echo -e "${blue}[*]${reset} $*"; }
warn() { echo -e "${yellow}[!]${reset} $*"; }
err()  { echo -e "${red}[x]${reset} $*" >&2; }
die()  { err "$*"; exit 1; }

MODE=""
SYSLOG_PATH="${SYSLOG_PATH:-/var/log/syslog}"
REPLICAS_SINGLE=0

usage() {
  cat <<'EOF'
Usage:
  Install & configure Elasticsearch, Kibana, Logstash (Enterprise only)
  sudo ./elk.sh -enterprise [--syslog-path /var/log/syslog]
Notes:
  - Stage 1 prints:
      * elastic superuser password -> /root/elastic-password.txt
      * Kibana enrollment token   -> /root/kibana-enrollment-token.txt
      * Kibana verification code  -> on demand
  - Open Kibana in your browser, paste the token, complete the screen.
  - Then run Stage 2 to auto-setup Fleet, Fleet Server, and enroll an Elastic Agent.

Environment overrides:
  SYSLOG_PATH  default: /var/log/syslog  (Logstash tail input)

This script is modeled to match your NetGuard style & flow.
EOF
}

if [[ $# -eq 0 ]]; then usage; exit 1; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -enterprise) MODE="enterprise"; shift ;;
    --post-enroll) MODE="post"; shift ;;
    --syslog-path) SYSLOG_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown flag: $1 (see -h)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Please run as root (sudo)."
command -v curl >/dev/null || die "curl required."
command -v awk  >/dev/null || die "awk required."

wait_http_200() {
  local url="$1" tries="${2:-60}"
  for i in $(seq 1 "$tries"); do
    if curl -s -o /dev/null -w "%{http_code}" "$url" | grep -q '^200$'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

if [[ "$MODE" == "enterprise" ]]; then
  export DEBIAN_FRONTEND=noninteractive

  msg "Adding Elastic 8.x APT repo & installing Elasticsearch, Kibana, Logstash…"
  apt-get update -y
  apt-get install -y apt-transport-https ca-certificates gnupg curl
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
    | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
    >/etc/apt/sources.list.d/elastic-8.x.list
  apt-get update -y
  apt-get install -y elasticsearch kibana logstash

  msg "Configuring Elasticsearch (single node, replicas=${REPLICAS_SINGLE})…"
  ES_YML="/etc/elasticsearch/elasticsearch.yml"
  cp -n "$ES_YML" "${ES_YML}.bak.$(date +%s)" || true
  sed -i -E \
    -e 's/^\s*(network\.host|discovery\.type|cluster\.name|node\.name|discovery\.seed_hosts|cluster\.initial_master_nodes)\s*:.*$//g' \
    "$ES_YML"

  cat >>"$ES_YML" <<'EOF'

cluster.name: netguard-es
node.name: es-enterprise-1
network.host: 0.0.0.0
discovery.type: single-node
EOF

  echo "vm.max_map_count=262144" >/etc/sysctl.d/99-elasticsearch.conf
  sysctl --system >/dev/null

  systemctl enable --now elasticsearch
  sleep 3
  systemctl --no-pager --full status elasticsearch || true

  msg "Resetting 'elastic' superuser password…"
  PW_OUT="$(printf 'y\n' | /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic 2>&1 || true)"
  ELASTIC_PASS="$(echo "$PW_OUT" | awk -F': ' '/New value/ {print $2}')"
  [[ -n "${ELASTIC_PASS:-}" ]] || { echo "$PW_OUT"; die "Could not capture 'elastic' password automatically."; }
  echo "$ELASTIC_PASS" >/root/elastic-password.txt
  chmod 600 /root/elastic-password.txt
  info "elastic password saved -> /root/elastic-password.txt"

  msg "Configuring Kibana (bind to localhost; change to 0.0.0.0 if needed)…"
  KBN_YML="/etc/kibana/kibana.yml"
  cp -n "$KBN_YML" "${KBN_YML}.bak.$(date +%s)" || true
  sed -i -E 's/^\s*server\.host\s*:.*$//g' "$KBN_YML"
  echo 'server.host: "127.0.0.1"' >>"$KBN_YML"
  systemctl enable --now kibana
  sleep 3
  systemctl --no-pager --full status kibana || true

  msg "Preparing Logstash pipeline for ${SYSLOG_PATH}…"
  install -d -o logstash -g logstash /var/lib/logstash /var/log/logstash /etc/logstash/certs
  if [[ -f /etc/elasticsearch/certs/http_ca.crt ]]; then
    cp /etc/elasticsearch/certs/http_ca.crt /etc/logstash/certs/http_ca.crt
    chown root:logstash /etc/logstash/certs/http_ca.crt
    chmod 640 /etc/logstash/certs/http_ca.crt
  else
    die "http_ca.crt not found at /etc/elasticsearch/certs/http_ca.crt"
  fi

  usermod -aG adm logstash || true
  if [[ ! -f /etc/logstash/logstash.keystore ]]; then
    printf 'y\n' | /usr/share/logstash/bin/logstash-keystore --path.settings /etc/logstash create
  fi
  printf 'elastic' | /usr/share/logstash/bin/logstash-keystore --path.settings /etc/logstash add es_user --stdin --force
  printf '%s' "$ELASTIC_PASS" | /usr/share/logstash/bin/logstash-keystore --path.settings /etc/logstash add es_pass --stdin --force

  PIPE_CONF="/etc/logstash/conf.d/10-file-to-es.conf"
  cat >"$PIPE_CONF" <<EOF
input {
  file {
    path => ["${SYSLOG_PATH}"]
    start_position => "beginning"
    sincedb_path => "/var/lib/logstash/sincedb-syslog"
  }
}
filter { }
output {
  elasticsearch {
    hosts  => ["https://localhost:9200"]
    index  => "syslog-%{+YYYY.MM.dd}"
    user   => "\${es_user}"
    password => "\${es_pass}"
    ssl_certificate_authorities => ["/etc/logstash/certs/http_ca.crt"]
    ssl_certificate_verification => true
  }
  stdout { codec => rubydebug }
}
EOF

  msg "Creating index template (single node replicas=${REPLICAS_SINGLE})…"
  curl -sk -u "elastic:${ELASTIC_PASS}" \
    -H 'Content-Type: application/json' \
    -X PUT "https://localhost:9200/_index_template/syslog-template" -d "{
      \"index_patterns\": [\"syslog-*-*\", \"syslog-*\"] ,
      \"template\": { \"settings\": { \"number_of_replicas\": ${REPLICAS_SINGLE} } }
    }" >/dev/null || warn "Template PUT failed (non-fatal)."

  systemctl enable --now logstash
  sleep 3
  systemctl --no-pager --full status logstash || true

  msg "Kibana enrollment + verification"
  KBN_TOKEN="$(/usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana)"
  echo "$KBN_TOKEN" >/root/kibana-enrollment-token.txt
  chmod 600 /root/kibana-enrollment-token.txt
  info "Enrollment token saved -> /root/kibana-enrollment-token.txt"
  info "To show verification code: sudo /usr/share/kibana/bin/kibana-verification-code"

  echo
  info "Open Kibana:"
  echo "  Local  ->  http://localhost:5601"
  echo
  exit 0
fi