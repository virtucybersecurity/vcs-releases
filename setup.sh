#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# VCS Cloud Code Studio — Fresh Server Bootstrap
# Version: 1.0.0
# Gateway: v1.1.9 | Auth: v1.0.1
# ============================================================================

GATEWAY_VERSION="v1.1.9"
AUTH_VERSION="v1.0.1"
RELEASES_BASE="https://raw.githubusercontent.com/00peter0/vcs-releases/main"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }

step_header() {
    echo ""
    echo -e "${BOLD}[$1] $2${NC}"
}

die() {
    fail "$1"
    exit 1
}

# ============================================================================
# 1. SUDO DETECTION
# ============================================================================

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    SUDO=""
elif sudo -n true 2>/dev/null; then
    SUDO="sudo"
else
    echo -e "${RED}Error: This script requires root privileges.${NC}"
    echo "Run as root or ensure passwordless sudo is available."
    exit 1
fi

# ============================================================================
# 1b. MODE DETECTION (managed vs standalone)
# ============================================================================

SETUP_MODE="standalone"
for arg in "$@"; do
    if [[ "$arg" == "--managed" ]]; then
        SETUP_MODE="managed"
    fi
done
if [[ -n "${VCS_SETUP_TOKEN:-}" ]]; then
    SETUP_MODE="managed"
fi

# ============================================================================
# 2. WELCOME BANNER
# ============================================================================

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║       VCS Cloud Code Studio — Server Setup          ║${NC}"
echo -e "${BOLD}${CYAN}║       Gateway ${GATEWAY_VERSION}  ·  Auth ${AUTH_VERSION}                  ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "This script will install and configure:"
echo ""
echo "  1. vcs-cc-auth        — authentication service (SQLite, Unix socket)"
echo "  2. vcs-cc-gateway     — HTTP gateway (reverse proxy for tools)"
echo "  3. vcs-cloud-code-tunnel — Cloudflare tunnel (HTTPS ingress)"
echo ""
echo "All three run as permanent root systemd services."
echo "Data stays local on this server."
echo ""

# Skip confirmation in non-interactive mode
if [[ -z "${VCS_NONINTERACTIVE:-}" ]]; then
    read -rp "Continue with installation? [y/N] " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ============================================================================
# 3. CONFIGURATION (interactive with env var overrides)
# ============================================================================

ask() {
    local var_name="$1" prompt="$2" default="$3"
    local env_val="${!var_name:-}"

    if [[ -n "$env_val" ]]; then
        printf -v "$var_name" '%s' "$env_val"
        info "$prompt → ${env_val} (from env)"
        return
    fi

    if [[ -z "${VCS_NONINTERACTIVE:-}" ]]; then
        read -rp "  $prompt [$default]: " input
        printf -v "$var_name" '%s' "${input:-$default}"
    else
        printf -v "$var_name" '%s' "$default"
        info "$prompt → ${default} (default)"
    fi
}

echo ""
echo -e "${BOLD}Configuration${NC}"
echo -e "  Mode: ${CYAN}${SETUP_MODE}${NC}"
echo ""

ask VCS_INSTALL_PATH "Install path" "/opt/vcs-cloud-code"
ask VCS_PORT         "Gateway port" "9000"

INSTALL_PATH="$VCS_INSTALL_PATH"
PORT="$VCS_PORT"

if [[ "$SETUP_MODE" == "managed" ]]; then
    # --- Managed mode: token + API URL embedded by /api/setup/{token}/script ---
    API_URL="${VCS_API_URL:?VCS_API_URL is required in managed mode}"
    SETUP_TOKEN="${VCS_SETUP_TOKEN:?VCS_SETUP_TOKEN is required in managed mode}"
    SERVER_NAME="${VCS_SERVER_NAME:-$(hostname)}"

    # DOMAIN will be set after register call
    DOMAIN="${SERVER_NAME}.virtucomputing.com"

    # Auto-detect public IP
    info "Detecting public IP..."
    SERVER_IP=$(curl -fsSL https://api.ipify.org 2>/dev/null || curl -fsSL https://ifconfig.me 2>/dev/null || true)
    if [[ -n "$SERVER_IP" ]]; then
        ok "Public IP: ${SERVER_IP}"
    else
        warn "Could not detect public IP — will send empty"
        SERVER_IP=""
    fi
else
    # --- Standalone mode: client provides own CF credentials ---
    ask VCS_DOMAIN       "Server domain (e.g. studio.example.com)" ""
    ask VCS_CF_TOKEN     "Cloudflare API Token (Account:Read + Tunnel:Edit + DNS:Edit)" ""
    ask VCS_CF_ZONE_ID   "Cloudflare Zone ID" ""
    ask VCS_CF_ZONE_NAME "Cloudflare Zone Name (e.g. example.com)" ""
    ask VCS_TUNNEL_NAME  "Tunnel name" "vcs-$(hostname)"

    DOMAIN="$VCS_DOMAIN"
    CF_TOKEN="$VCS_CF_TOKEN"
    CF_ZONE_ID="$VCS_CF_ZONE_ID"
    CF_ZONE_NAME="$VCS_CF_ZONE_NAME"
    TUNNEL_NAME="$VCS_TUNNEL_NAME"

    # Validate required fields
    [[ -z "$DOMAIN" ]]       && die "Server domain is required."
    [[ -z "$CF_TOKEN" ]]     && die "Cloudflare API Token is required."
    [[ -z "$CF_ZONE_ID" ]]   && die "Cloudflare Zone ID is required."
    [[ -z "$CF_ZONE_NAME" ]] && die "Cloudflare Zone Name is required."
fi

# ============================================================================
# [1/8] Checking system requirements
# ============================================================================

step_header "1/8" "Checking system requirements..."

for cmd in curl systemctl; do
    if ! command -v "$cmd" &>/dev/null; then
        die "$cmd is required but not installed."
    fi
    ok "$cmd found"
done

if ! command -v jq &>/dev/null; then
    warn "jq not found — installing..."
    if command -v apt-get &>/dev/null; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq jq
    elif command -v yum &>/dev/null; then
        $SUDO yum install -y -q jq
    elif command -v dnf &>/dev/null; then
        $SUDO dnf install -y -q jq
    else
        die "Cannot install jq — no supported package manager found. Install jq manually."
    fi
    ok "jq installed"
else
    ok "jq found"
fi

# Check port availability
if ss -tlnp 2>/dev/null | grep -q ":${PORT} " || \
   netstat -tlnp 2>/dev/null | grep -q ":${PORT} "; then
    warn "Port ${PORT} appears to be in use — existing service may be running"
else
    ok "Port ${PORT} is available"
fi

# ============================================================================
# [2/8] Creating directory structure
# ============================================================================

step_header "2/8" "Creating directory structure..."

$SUDO mkdir -p "${INSTALL_PATH}"
ok "${INSTALL_PATH}"

$SUDO mkdir -p /run/vcs-cc-auth
ok "/run/vcs-cc-auth"

$SUDO mkdir -p /var/log/vcs
ok "/var/log/vcs"

$SUDO mkdir -p /opt/vcs-cc-auth
ok "/opt/vcs-cc-auth"

$SUDO mkdir -p /opt/vcs-tools
ok "/opt/vcs-tools"

# ============================================================================
# [3/8] Downloading binaries
# ============================================================================

step_header "3/8" "Downloading binaries..."

GATEWAY_URL="${RELEASES_BASE}/gateway/${GATEWAY_VERSION}/gateway-go"
AUTH_URL="${RELEASES_BASE}/vcs-cc-auth/${AUTH_VERSION}/vcs-cc-auth"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Download gateway
info "Downloading gateway-go ${GATEWAY_VERSION}..."
if curl -fSL --progress-bar -o "${TMP_DIR}/gateway-go" "$GATEWAY_URL"; then
    ok "gateway-go downloaded"
else
    die "Failed to download gateway-go from ${GATEWAY_URL}"
fi

# Download auth
info "Downloading vcs-cc-auth ${AUTH_VERSION}..."
if curl -fSL --progress-bar -o "${TMP_DIR}/vcs-cc-auth" "$AUTH_URL"; then
    ok "vcs-cc-auth downloaded"
else
    die "Failed to download vcs-cc-auth from ${AUTH_URL}"
fi

$SUDO chmod +x "${TMP_DIR}/gateway-go" "${TMP_DIR}/vcs-cc-auth"
$SUDO mv "${TMP_DIR}/gateway-go" "${INSTALL_PATH}/gateway-go"
$SUDO mv "${TMP_DIR}/vcs-cc-auth" "/opt/vcs-cc-auth/vcs-cc-auth"
ok "Binaries installed"

# ============================================================================
# [4/8] Generating gateway.conf
# ============================================================================

step_header "4/8" "Generating gateway.conf..."

CONF_FILE="${INSTALL_PATH}/gateway.conf"

if [[ -f "$CONF_FILE" ]]; then
    warn "gateway.conf already exists — backing up to gateway.conf.bak"
    $SUDO cp "$CONF_FILE" "${CONF_FILE}.bak"
fi

$SUDO tee "$CONF_FILE" > /dev/null <<CONF
DOMAIN=${DOMAIN}
PORT=${PORT}
INSTALL_PATH=${INSTALL_PATH}
CONF

ok "gateway.conf written to ${CONF_FILE}"

# Initialize tools.json if missing
if [[ ! -f "${INSTALL_PATH}/tools.json" ]]; then
    $SUDO tee "${INSTALL_PATH}/tools.json" > /dev/null <<< '[]'
    ok "tools.json initialized"
fi

# ============================================================================
# [5/8] Installing Cloudflare tunnel
# ============================================================================

step_header "5/8" "Registering with VCS API / Installing Cloudflare tunnel..."

if [[ "$SETUP_MODE" == "managed" ]]; then
    # ── Managed mode: register with central VCS API ──
    # Read server UUID from server.json if it exists
    SERVER_UUID=""
    if [[ -f "${INSTALL_PATH}/server.json" ]]; then
        SERVER_UUID=$(jq -r '.uuid // empty' "${INSTALL_PATH}/server.json" 2>/dev/null || true)
    fi

    info "Registering with VCS API at ${API_URL}..."
    REGISTER_RESP=$(curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "{\"token\":\"${SETUP_TOKEN}\",\"hostname\":\"$(hostname)\",\"server_name\":\"${SERVER_NAME}\",\"ip\":\"${SERVER_IP}\",\"server_uuid\":\"${SERVER_UUID}\"}" \
        "${API_URL}/api/setup/${SETUP_TOKEN}/register") || \
        die "Failed to contact VCS API at ${API_URL}/api/setup/${SETUP_TOKEN}/register"

    REGISTER_OK=$(echo "$REGISTER_RESP" | jq -r '.ok // false')
    if [[ "$REGISTER_OK" != "true" ]]; then
        REGISTER_ERROR=$(echo "$REGISTER_RESP" | jq -r '.error // "Unknown error"')
        die "Registration failed: ${REGISTER_ERROR}"
    fi

    TUNNEL_TOKEN=$(echo "$REGISTER_RESP" | jq -r '.tunnel_token')
    TUNNEL_ID=$(echo "$REGISTER_RESP" | jq -r '.tunnel_id')
    DOMAIN_URL=$(echo "$REGISTER_RESP" | jq -r '.subdomain_url')
    DOMAIN="${DOMAIN_URL#https://}"

    [[ -z "$TUNNEL_TOKEN" || "$TUNNEL_TOKEN" == "null" ]] && die "No tunnel_token in registration response."
    [[ -z "$TUNNEL_ID" || "$TUNNEL_ID" == "null" ]]       && die "No tunnel_id in registration response."

    ok "Registered: ${DOMAIN}"
    ok "Tunnel ID: ${TUNNEL_ID}"

    # Update gateway.conf with the real domain from API
    $SUDO tee "${INSTALL_PATH}/gateway.conf" > /dev/null <<CONF
DOMAIN=${DOMAIN}
PORT=${PORT}
INSTALL_PATH=${INSTALL_PATH}
CONF
    ok "gateway.conf updated with domain from API"

    # Save tunnel info for reference
    CREDS_FILE="${INSTALL_PATH}/tunnel-credentials.json"
    $SUDO tee "$CREDS_FILE" > /dev/null <<CREDS
{
  "TunnelID": "${TUNNEL_ID}",
  "TunnelToken": "${TUNNEL_TOKEN}",
  "Mode": "managed",
  "ApiUrl": "${API_URL}",
  "ServerName": "${SERVER_NAME}"
}
CREDS
    $SUDO chmod 600 "$CREDS_FILE"
    ok "Tunnel credentials saved to ${CREDS_FILE}"

else
    # ── Standalone mode: direct Cloudflare API ──
    CF_API="https://api.cloudflare.com/client/v4"
    CF_AUTH_HEADER="Authorization: Bearer ${CF_TOKEN}"

    # Get account ID
    info "Fetching Cloudflare account ID..."
    ACCOUNTS_RESP=$(curl -sf -H "$CF_AUTH_HEADER" "${CF_API}/accounts?per_page=1") || \
        die "Failed to fetch Cloudflare accounts. Check your API token."

    ACCOUNT_ID=$(echo "$ACCOUNTS_RESP" | jq -r '.result[0].id // empty')
    [[ -z "$ACCOUNT_ID" ]] && die "No Cloudflare account found for this token."
    ok "Account ID: ${ACCOUNT_ID}"

    # Create tunnel
    info "Creating tunnel '${TUNNEL_NAME}'..."
    TUNNEL_SECRET=$(openssl rand -base64 32)

    TUNNEL_RESP=$(curl -sf -X POST \
        -H "$CF_AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${TUNNEL_NAME}\",\"tunnel_secret\":\"${TUNNEL_SECRET}\"}" \
        "${CF_API}/accounts/${ACCOUNT_ID}/cfd_tunnel") || \
        die "Failed to create Cloudflare tunnel."

    TUNNEL_SUCCESS=$(echo "$TUNNEL_RESP" | jq -r '.success')
    if [[ "$TUNNEL_SUCCESS" != "true" ]]; then
        ERRORS=$(echo "$TUNNEL_RESP" | jq -r '.errors[]?.message // "Unknown error"')
        die "Tunnel creation failed: ${ERRORS}"
    fi

    TUNNEL_ID=$(echo "$TUNNEL_RESP" | jq -r '.result.id')
    TUNNEL_TOKEN=$(echo "$TUNNEL_RESP" | jq -r '.result.token // empty')
    ok "Tunnel created: ${TUNNEL_ID}"

    # Save tunnel credentials
    CREDS_FILE="${INSTALL_PATH}/tunnel-credentials.json"
    if [[ -n "$TUNNEL_TOKEN" ]]; then
        # New-style token-based tunnel
        $SUDO tee "$CREDS_FILE" > /dev/null <<CREDS
{
  "AccountTag": "${ACCOUNT_ID}",
  "TunnelID": "${TUNNEL_ID}",
  "TunnelName": "${TUNNEL_NAME}",
  "TunnelSecret": "${TUNNEL_SECRET}",
  "TunnelToken": "${TUNNEL_TOKEN}"
}
CREDS
    else
        $SUDO tee "$CREDS_FILE" > /dev/null <<CREDS
{
  "AccountTag": "${ACCOUNT_ID}",
  "TunnelID": "${TUNNEL_ID}",
  "TunnelName": "${TUNNEL_NAME}",
  "TunnelSecret": "${TUNNEL_SECRET}"
}
CREDS
    fi
    $SUDO chmod 600 "$CREDS_FILE"
    ok "Tunnel credentials saved to ${CREDS_FILE}"

    # Configure tunnel ingress (route traffic to gateway)
    info "Configuring tunnel ingress..."
    INGRESS_RESP=$(curl -sf -X PUT \
        -H "$CF_AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"config\":{\"ingress\":[{\"hostname\":\"${DOMAIN}\",\"service\":\"http://127.0.0.1:${PORT}\"},{\"service\":\"http_status:404\"}]}}" \
        "${CF_API}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations") || \
        warn "Failed to configure tunnel ingress — you may need to configure it manually."

    INGRESS_OK=$(echo "${INGRESS_RESP:-{}}" | jq -r '.success // false')
    if [[ "$INGRESS_OK" == "true" ]]; then
        ok "Tunnel ingress configured"
    else
        warn "Tunnel ingress configuration may have failed — verify in CF dashboard"
    fi

    # Create DNS CNAME record
    info "Creating DNS record: ${DOMAIN} → ${TUNNEL_ID}.cfargotunnel.com..."
    DNS_RESP=$(curl -sf -X POST \
        -H "$CF_AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"CNAME\",\"name\":\"${DOMAIN}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}" \
        "${CF_API}/zones/${CF_ZONE_ID}/dns_records") || \
        warn "Failed to create DNS record — you may need to create it manually."

    DNS_OK=$(echo "${DNS_RESP:-{}}" | jq -r '.success // false')
    if [[ "$DNS_OK" == "true" ]]; then
        ok "DNS CNAME record created"
    else
        DNS_ERRORS=$(echo "${DNS_RESP:-{}}" | jq -r '.errors[]?.message // "Unknown"' 2>/dev/null)
        if echo "$DNS_ERRORS" | grep -qi "already exists"; then
            warn "DNS record already exists for ${DOMAIN}"
        else
            warn "DNS record creation may have failed: ${DNS_ERRORS}"
        fi
    fi
fi

# Install cloudflared if not present
if ! command -v cloudflared &>/dev/null; then
    info "Installing cloudflared..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) CF_ARCH="amd64" ;;
        aarch64|arm64) CF_ARCH="arm64" ;;
        *) die "Unsupported architecture: $ARCH" ;;
    esac
    CF_DEB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}.deb"
    if command -v dpkg &>/dev/null; then
        curl -fSL -o "${TMP_DIR}/cloudflared.deb" "$CF_DEB_URL" || die "Failed to download cloudflared"
        $SUDO dpkg -i "${TMP_DIR}/cloudflared.deb" || die "Failed to install cloudflared"
    else
        CF_BIN_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
        curl -fSL -o "${TMP_DIR}/cloudflared" "$CF_BIN_URL" || die "Failed to download cloudflared"
        $SUDO chmod +x "${TMP_DIR}/cloudflared"
        $SUDO mv "${TMP_DIR}/cloudflared" /usr/bin/cloudflared
    fi
    ok "cloudflared installed"
else
    ok "cloudflared already installed"
fi

# ============================================================================
# [6/8] Generating systemd units
# ============================================================================

step_header "6/8" "Generating systemd units..."

# --- vcs-cc-auth.service ---
$SUDO tee /etc/systemd/system/vcs-cc-auth.service > /dev/null <<UNIT
[Unit]
Description=VCS Cloud Code Auth Service
After=network.target
Before=vcs-cc-gateway.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/vcs-cc-auth
ExecStart=/opt/vcs-cc-auth/vcs-cc-auth
Restart=always
RestartSec=3
RuntimeDirectory=vcs-cc-auth
RuntimeDirectoryMode=0750

[Install]
WantedBy=multi-user.target
UNIT
ok "vcs-cc-auth.service"

# --- vcs-cc-gateway.service ---
$SUDO tee /etc/systemd/system/vcs-cc-gateway.service > /dev/null <<UNIT
[Unit]
Description=VCS Cloud Code Auth Gateway
After=network.target

[Service]
ExecStart=${INSTALL_PATH}/gateway-go ${PORT}
Restart=always
RestartSec=3
Environment=VCS_API_URL=https://vcs.virtucomputing.com
WorkingDirectory=${INSTALL_PATH}

[Install]
WantedBy=multi-user.target
UNIT
ok "vcs-cc-gateway.service"

# --- vcs-cloud-code-tunnel.service ---
# Determine tunnel run command
if [[ -n "${TUNNEL_TOKEN:-}" ]]; then
    TUNNEL_EXEC="/usr/bin/cloudflared tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}"
else
    TUNNEL_EXEC="/usr/bin/cloudflared tunnel --no-autoupdate --credentials-file ${CREDS_FILE} run ${TUNNEL_NAME}"
fi

$SUDO tee /etc/systemd/system/vcs-cloud-code-tunnel.service > /dev/null <<UNIT
[Unit]
Description=VCS Cloud Code Cloudflare Tunnel
After=network-online.target vcs-cc-gateway.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${TUNNEL_EXEC}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vcs-cc-tunnel

[Install]
WantedBy=multi-user.target
UNIT
ok "vcs-cloud-code-tunnel.service"

$SUDO systemctl daemon-reload
ok "systemctl daemon-reload"

# ============================================================================
# [7/8] Starting services
# ============================================================================

step_header "7/8" "Starting services..."

start_service() {
    local name="$1"
    $SUDO systemctl enable "$name" --now 2>/dev/null
    sleep 1
    if $SUDO systemctl is-active --quiet "$name"; then
        ok "$name is running"
        return 0
    else
        fail "$name failed to start"
        $SUDO journalctl -u "$name" -n 5 --no-pager 2>/dev/null || true
        return 1
    fi
}

start_service "vcs-cc-auth" || die "Auth service failed — cannot continue."
sleep 3

start_service "vcs-cc-gateway" || die "Gateway service failed — cannot continue."
sleep 2

start_service "vcs-cloud-code-tunnel" || warn "Tunnel service failed — check logs with: journalctl -u vcs-cloud-code-tunnel"

# ============================================================================
# [8/8] Capturing initial credentials
# ============================================================================

step_header "8/8" "Capturing initial credentials..."

CRED_FILE="${INSTALL_PATH}/initial-credentials.txt"

# Don't overwrite existing credentials
if [[ -f "$CRED_FILE" ]]; then
    warn "Credentials file already exists — not overwriting: ${CRED_FILE}"
else
    sleep 2
    CRED_OUTPUT=$($SUDO journalctl -u vcs-cc-auth -n 50 --no-pager 2>/dev/null | grep -A3 "INITIAL CREDENTIALS" || true)

    if [[ -n "$CRED_OUTPUT" ]]; then
        echo "$CRED_OUTPUT" | $SUDO tee "$CRED_FILE" > /dev/null
        $SUDO chmod 600 "$CRED_FILE"
        ok "Credentials captured to ${CRED_FILE}"
    else
        warn "Initial credentials not found in auth service logs."
        warn "Check manually: journalctl -u vcs-cc-auth | grep -A3 'INITIAL CREDENTIALS'"
    fi
fi

# Extract password for summary display
INIT_PASSWORD=""
if [[ -f "$CRED_FILE" ]]; then
    INIT_PASSWORD=$(grep -i 'password' "$CRED_FILE" 2>/dev/null | head -1 | sed 's/.*: *//' || true)
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   ✓ Cloud Code Studio installed successfully!       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  URL:      ${BOLD}https://${DOMAIN}${NC}"
echo -e "  Username: ${BOLD}admin${NC}"
if [[ -n "$INIT_PASSWORD" ]]; then
    echo -e "  Password: ${BOLD}${INIT_PASSWORD}${NC}"
else
    echo -e "  Password: ${YELLOW}check ${CRED_FILE}${NC}"
fi
echo ""
echo -e "  Credentials saved to: ${CRED_FILE}"
echo ""
echo -e "  ${YELLOW}IMPORTANT: Back up these files:${NC}"
echo "    - ${CRED_FILE}"
echo "    - ${INSTALL_PATH}/tunnel-credentials.json"
echo "    - /opt/vcs-cc-auth/seed (if exists)"
echo ""
echo -e "  Services:"
echo "    systemctl status vcs-cc-auth"
echo "    systemctl status vcs-cc-gateway"
echo "    systemctl status vcs-cloud-code-tunnel"
echo ""
