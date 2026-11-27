#!/usr/bin/env bash
# =============================================================================
# 01-setup-grafana-ec2.sh      (run this ON THE GRAFANA EC2 INSTANCE, over SSH)
#
# Installs Grafana OSS and puts an Apache reverse proxy in front of it:
#
#   browser --> http://<server>:80  --> Apache --> Grafana (127.0.0.1:3000)
#
# Also provisions the Prometheus, Loki and Tempo data sources.
# Works on Amazon Linux 2023 / RHEL / Rocky / Fedora (dnf) and Ubuntu / Debian (apt).
#
# Usage:
#   1) Edit the CONFIG block (password is required; the three URLs come from script 02,
#      you may leave them for later)
#   2) chmod +x 01-setup-grafana-ec2.sh && ./01-setup-grafana-ec2.sh
#   3) Later, after running 02-setup-eks-monitoring.sh, paste the three URLs here and run:
#        ./01-setup-grafana-ec2.sh datasources
#
# Safe to re-run.
# Network needed: outbound internet (to install packages), inbound TCP 80 from
# your users (security group). Port 3000 stays closed (Grafana listens on localhost only).
# =============================================================================

# ----------------------------- CONFIG (edit me) ------------------------------
GRAFANA_ADMIN_PASSWORD="<PASTE_STRONG_PASSWORD>"

# From the output of 02-setup-eks-monitoring.sh (full URL with port, e.g. http://k8s-xxx.elb.us-east-1.amazonaws.com:9090)
PROMETHEUS_URL="<PASTE_PROMETHEUS_URL>"
LOKI_URL="<PASTE_LOKI_URL>"
TEMPO_URL="<PASTE_TEMPO_URL>"

# Name or IP people will type in the browser. Leave empty to auto-detect this server's IP.
SERVER_NAME=""
# -----------------------------------------------------------------------------

set -Eeuo pipefail

c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_b=$'\033[36m'; c_0=$'\033[0m'
log()  { echo "${c_b}[$(date +%H:%M:%S)]${c_0} $*"; }
ok()   { echo "${c_g}  OK${c_0}  $*"; }
warn() { echo "${c_y}  WARN${c_0} $*"; }
die()  { echo "${c_r}  FAIL${c_0} $*" >&2; exit 1; }
trap 'echo "${c_r}Failed at line $LINENO. Fix the error above and re-run (safe to re-run).${c_0}" >&2' ERR

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

is_placeholder() { [ -z "$1" ] || [[ "$1" == *"<PASTE"* ]]; }

# --------------------------- detect the OS family ----------------------------
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
  *debian*|*ubuntu*) FAMILY=deb ;;
  *rhel*|*fedora*|*centos*|*amzn*|*rocky*|*almalinux*) FAMILY=rpm ;;
  *) die "Unsupported OS: ${PRETTY_NAME:-unknown}. Use Amazon Linux 2023, RHEL-like, Ubuntu or Debian." ;;
esac
if [ "$FAMILY" = rpm ]; then
  APACHE_SVC=httpd; GF_ENV_FILE=/etc/sysconfig/grafana-server
  APACHE_CONF=/etc/httpd/conf.d/grafana.conf
else
  APACHE_SVC=apache2; GF_ENV_FILE=/etc/default/grafana-server
  APACHE_CONF=/etc/apache2/sites-available/grafana.conf
fi

# --------------------------- detect the server name --------------------------
detect_server_name() {
  [ -n "$SERVER_NAME" ] && { echo "$SERVER_NAME"; return; }
  local tok ip=""
  tok=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
  if [ -n "$tok" ]; then
    ip=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/public-ipv4 || true)
    case "$ip" in *"<"*|*"html"*|"") ip="" ;; esac
    [ -z "$ip" ] && ip=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/local-ipv4 || true)
  fi
  [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -z "$ip" ] && ip="localhost"
  echo "$ip"
}

norm_url() { # add http:// if missing, strip trailing slash
  local u="$1"; case "$u" in http://*|https://*) ;; *) u="http://$u" ;; esac; echo "${u%/}"
}

# ------------------------------- data sources --------------------------------
write_datasources() {
  $SUDO mkdir -p /etc/grafana/provisioning/datasources
  local tmp; tmp=$(mktemp)
  echo "apiVersion: 1" > "$tmp"
  echo "datasources:" >> "$tmp"
  local n=0
  if ! is_placeholder "$PROMETHEUS_URL"; then
    cat >> "$tmp" <<YAML
  - name: Prometheus
    type: prometheus
    access: proxy
    url: $(norm_url "$PROMETHEUS_URL")
    isDefault: true
YAML
    n=$((n+1))
  fi
  if ! is_placeholder "$LOKI_URL"; then
    cat >> "$tmp" <<YAML
  - name: Loki
    type: loki
    access: proxy
    url: $(norm_url "$LOKI_URL")
YAML
    n=$((n+1))
  fi
  if ! is_placeholder "$TEMPO_URL"; then
    cat >> "$tmp" <<YAML
  - name: Tempo
    type: tempo
    access: proxy
    url: $(norm_url "$TEMPO_URL")
YAML
    n=$((n+1))
  fi
  if [ "$n" -eq 0 ]; then
    warn "No data source URLs set yet. Run script 02, paste the URLs above, then: ./$(basename "$0") datasources"
    rm -f "$tmp"; return 0
  fi
  $SUDO install -m 0644 -o root -g grafana "$tmp" /etc/grafana/provisioning/datasources/observability.yaml
  rm -f "$tmp"
  ok "$n data source(s) written to /etc/grafana/provisioning/datasources/observability.yaml"
}

check_backends() {
  local name url path
  for pair in "Prometheus|$PROMETHEUS_URL|/-/ready" "Loki|$LOKI_URL|/ready" "Tempo|$TEMPO_URL|/ready"; do
    IFS='|' read -r name url path <<<"$pair"
    if is_placeholder "$url"; then continue; fi
    code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$(norm_url "$url")$path" || true)
    if [ "$code" = "200" ]; then ok "$name reachable ($url)"
    else warn "$name returned '$code' from this server ($url). Check: NLB targets healthy, EKS cluster security group allows this server's IP on that port."; fi
  done
}

wait_grafana() {
  local i
  for i in $(seq 1 30); do
    curl -s -m 3 http://127.0.0.1:3000/api/health 2>/dev/null | grep -q '"database"' && return 0
    sleep 2
  done
  return 1
}

# --------------------------- quick mode: datasources -------------------------
if [ "${1:-}" = "datasources" ]; then
  log "Updating data sources only"
  write_datasources
  $SUDO systemctl restart grafana-server
  wait_grafana || die "Grafana did not come back. See: sudo journalctl -u grafana-server -n 50"
  ok "Grafana restarted"
  check_backends
  exit 0
fi

# -------------------------------- checks -------------------------------------
is_placeholder "$GRAFANA_ADMIN_PASSWORD" && die "Set GRAFANA_ADMIN_PASSWORD in the CONFIG block."
[ "${#GRAFANA_ADMIN_PASSWORD}" -ge 8 ] || die "Use a password of at least 8 characters."
SERVER="$(detect_server_name)"
log "OS family: $FAMILY | server name: $SERVER"

# -------------------------------- install ------------------------------------
log "Installing Grafana OSS and Apache"
if [ "$FAMILY" = rpm ]; then
  $SUDO tee /etc/yum.repos.d/grafana.repo >/dev/null <<'REPO'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
REPO
  $SUDO dnf install -y grafana httpd mod_ssl curl >/dev/null
else
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -y >/dev/null
  $SUDO apt-get install -y apt-transport-https wget gpg curl apache2 >/dev/null
  $SUDO mkdir -p /etc/apt/keyrings
  wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | $SUDO tee /etc/apt/keyrings/grafana.gpg >/dev/null
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    | $SUDO tee /etc/apt/sources.list.d/grafana.list >/dev/null
  $SUDO apt-get update -y >/dev/null
  $SUDO apt-get install -y grafana >/dev/null
fi
ok "packages installed"

# ------------------- Grafana: localhost only, behind Apache ------------------
log "Configuring Grafana (listens on 127.0.0.1:3000)"
$SUDO touch "$GF_ENV_FILE"
$SUDO sed -i '/^GF_SERVER_HTTP_ADDR=/d;/^GF_SERVER_HTTP_PORT=/d;/^GF_SERVER_ROOT_URL=/d;/^GF_SERVER_DOMAIN=/d;/^GF_USERS_ALLOW_SIGN_UP=/d;/^GF_AUTH_ANONYMOUS_ENABLED=/d' "$GF_ENV_FILE"
$SUDO tee -a "$GF_ENV_FILE" >/dev/null <<ENV
GF_SERVER_HTTP_ADDR=127.0.0.1
GF_SERVER_HTTP_PORT=3000
GF_SERVER_DOMAIN=${SERVER}
GF_SERVER_ROOT_URL=http://${SERVER}/
GF_USERS_ALLOW_SIGN_UP=false
GF_AUTH_ANONYMOUS_ENABLED=false
ENV

write_datasources

$SUDO systemctl daemon-reload
$SUDO systemctl enable grafana-server >/dev/null 2>&1
$SUDO systemctl restart grafana-server
wait_grafana || die "Grafana did not start. See: sudo journalctl -u grafana-server -n 50"
ok "Grafana is running"

# Set the admin password (Grafana is still localhost-only here, Apache is not configured yet)
if $SUDO -u grafana grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
     admin reset-admin-password "$GRAFANA_ADMIN_PASSWORD" >/dev/null 2>&1 \
   || $SUDO -u grafana grafana-cli --homepath /usr/share/grafana admin reset-admin-password "$GRAFANA_ADMIN_PASSWORD" >/dev/null 2>&1; then
  ok "admin password set"
else
  warn "Could not set the admin password with the CLI. Default login is admin / admin: change it at first login."
fi

# ----------------------------- Apache reverse proxy --------------------------
log "Configuring Apache reverse proxy on port 80"
if [ "$FAMILY" = deb ]; then
  $SUDO a2enmod proxy proxy_http proxy_wstunnel rewrite headers >/dev/null
  $SUDO a2dissite 000-default >/dev/null 2>&1 || true
fi

$SUDO tee "$APACHE_CONF" >/dev/null <<CONF
<VirtualHost *:80>
    ServerName ${SERVER}

    ProxyPreserveHost On
    ProxyRequests Off

    # WebSocket (Grafana Live)
    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} =websocket [NC]
    RewriteRule /(.*) ws://127.0.0.1:3000/\$1 [P,L]

    ProxyPass        / http://127.0.0.1:3000/
    ProxyPassReverse / http://127.0.0.1:3000/

    RequestHeader set X-Forwarded-Proto "http"
    ErrorLog  /var/log/${APACHE_SVC}/grafana-error.log
    CustomLog /var/log/${APACHE_SVC}/grafana-access.log combined
</VirtualHost>
CONF

if [ "$FAMILY" = rpm ]; then
  # the default welcome page would otherwise answer on port 80
  $SUDO sed -i 's/^\(.*\)$/#\1/' /etc/httpd/conf.d/welcome.conf 2>/dev/null || true
  if command -v getenforce >/dev/null && [ "$(getenforce)" = "Enforcing" ]; then
    $SUDO setsebool -P httpd_can_network_connect 1
    ok "SELinux: allowed Apache to connect to Grafana"
  fi
  $SUDO mkdir -p /var/log/httpd
  $SUDO httpd -t
else
  $SUDO a2ensite grafana >/dev/null
  $SUDO apache2ctl configtest
fi

$SUDO systemctl enable "$APACHE_SVC" >/dev/null 2>&1
$SUDO systemctl restart "$APACHE_SVC"
sleep 2
ok "Apache is running"

# --------------------------------- verify ------------------------------------
log "Verifying"
code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' http://127.0.0.1/login || true)
[ "$code" = "200" ] && ok "http://127.0.0.1/login answers 200 through Apache" \
  || die "Apache -> Grafana check returned '$code'. See: sudo tail -30 /var/log/${APACHE_SVC}/grafana-error.log"
check_backends

cat <<MSG

  Grafana is ready.

    URL      : http://${SERVER}/        (port 80, Apache reverse proxy)
    Login    : admin / the password you set in this script
    Services : sudo systemctl status grafana-server ${APACHE_SVC}

  Make sure the EC2 security group allows inbound TCP 80 from the people who need access.
  If you have not pasted the Prometheus/Loki/Tempo URLs yet, do that after script 02 and run:
      ./$(basename "$0") datasources
MSG
