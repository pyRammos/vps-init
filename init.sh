#!/usr/bin/env bash
# init.sh — VPS bootstrap script
# Turns a fresh Debian 13 install into a homelab DR standby node.
#
# Run as root on a fresh Debian 13 VPS:
#   curl -fsSL https://raw.githubusercontent.com/pyRammos/vps-init/main/init.sh | bash
#   OR after cloning:
#   sudo bash init.sh
#
# What this does (in order):
#   1.  Verify Debian 13 + root
#   2.  Create george user (uid 1000, gid 100)
#   3.  Install SSH public key + harden SSH
#   4.  Install base packages + Docker + fail2ban
#   5.  Configure WireGuard as CLIENT to UDM
#       - Accepts pasted config from UDM
#       - Tests for AllowedIPs = 0.0.0.0/0 and injects it if missing
#       - Tests for DNS line and warns if missing
#   6.  Install WireGuard watchdog (safety net if tunnel drops)
#   7.  Start WireGuard (point of no return)
#   8.  Verify tunnel to home LAN
#   9.  Clone george/homelab from Gitea over tunnel
#   10. Print next steps

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo -e "${CYAN}▶ $*${RESET}"; }
ok()     { echo -e "${GREEN}✓ $*${RESET}"; }
warn()   { echo -e "${YELLOW}⚠ $*${RESET}"; }
err()    { echo -e "${RED}✗ $*${RESET}" >&2; }
die()    { err "$*"; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}\n"; }

# ── 1. Pre-flight ─────────────────────────────────────────────────────────────
header "Pre-flight checks"

[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash init.sh"

if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "${ID}" == "debian" ]] || die "This script is for Debian. Found: ${ID}"
    [[ "${VERSION_ID}" == "13" ]] || \
        warn "Expected Debian 13, found ${VERSION_ID}. Continuing anyway."
    ok "Debian ${VERSION_ID} (${VERSION_CODENAME:-unknown})"
else
    die "/etc/os-release not found"
fi

# Store original default gateway BEFORE WireGuard changes routing
ORIGINAL_GW=$(ip route | awk '/^default/ {print $3; exit}')
ORIGINAL_IFACE=$(ip route | awk '/^default/ {print $5; exit}')
[[ -n "${ORIGINAL_GW}" ]] || die "Cannot determine default gateway"
ok "Original gateway: ${ORIGINAL_GW} via ${ORIGINAL_IFACE}"

# ── 2. Create george user ─────────────────────────────────────────────────────
header "User setup"

if ! getent group 100 &>/dev/null; then
    groupadd --gid 100 users
    ok "Created group 'users' (gid 100)"
else
    ok "Group gid 100 exists: $(getent group 100 | cut -d: -f1)"
fi

if id george &>/dev/null; then
    ok "User 'george' already exists"
else
    useradd \
        --uid 1000 \
        --gid 100 \
        --create-home \
        --shell /bin/bash \
        --groups sudo \
        george
    ok "Created user george (uid 1000, gid 100)"
fi

usermod -aG sudo george
ok "george has sudo access"

# ── 3. SSH key + hardening ────────────────────────────────────────────────────
header "SSH configuration"

SSH_DIR="/home/george/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chown george:users "${SSH_DIR}"

if [[ ! -s "${AUTH_KEYS}" ]]; then
    echo ""
    echo -e "${YELLOW}Paste your SSH public key (from 1Password), then press Enter, then Ctrl+D:${RESET}"
    SSH_PUBKEY=$(cat)
    [[ -n "${SSH_PUBKEY}" ]] || die "No SSH key provided"
    echo "${SSH_PUBKEY}" > "${AUTH_KEYS}"
    chmod 600 "${AUTH_KEYS}"
    chown george:users "${AUTH_KEYS}"
    ok "SSH public key installed"
else
    ok "authorized_keys already populated, skipping"
fi

SSHD_CONF="/etc/ssh/sshd_config"
cp "${SSHD_CONF}" "${SSHD_CONF}.bak"

declare -A SSH_SETTINGS=(
    ["PasswordAuthentication"]="no"
    ["PermitRootLogin"]="no"
    ["PubkeyAuthentication"]="yes"
    ["AuthorizedKeysFile"]=".ssh/authorized_keys"
    ["ChallengeResponseAuthentication"]="no"
    ["UsePAM"]="yes"
    ["X11Forwarding"]="no"
    ["PrintMotd"]="no"
)

for key in "${!SSH_SETTINGS[@]}"; do
    val="${SSH_SETTINGS[$key]}"
    if grep -qE "^#?${key}" "${SSHD_CONF}"; then
        sed -i "s|^#\?${key}.*|${key} ${val}|" "${SSHD_CONF}"
    else
        echo "${key} ${val}" >> "${SSHD_CONF}"
    fi
done

systemctl restart sshd
ok "SSH hardened — password auth disabled, root login disabled"

echo ""
warn "SSH is now key-only. Verify you can login as george before continuing."
read -r -p "  Have you verified SSH access as george in a separate terminal? (yes/no): " ssh_check
[[ "${ssh_check}" == "yes" ]] || {
    warn "Run in another terminal: ssh george@<VPS-IP>"
    read -r -p "  Verified now? (yes/no): " ssh_check2
    [[ "${ssh_check2}" == "yes" ]] || die "Aborted. Fix SSH access before proceeding."
}

# ── 4. Base packages + Docker + fail2ban ──────────────────────────────────────
header "Installing packages"

apt-get update -qq

apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    rsync \
    apache2-utils \
    wireguard \
    wireguard-tools \
    resolvconf \
    iptables \
    fail2ban \
    ufw \
    htop \
    jq \
    gnupg \
    ca-certificates \
    lsb-release \
    dnsutils

ok "Base packages installed"

if ! command -v docker &>/dev/null; then
    log "Installing Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian \
$(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    systemctl enable docker
    usermod -aG docker george
    ok "Docker installed"
else
    ok "Docker already installed: $(docker --version)"
fi

systemctl enable fail2ban
systemctl start fail2ban
ok "fail2ban enabled"

# ── 5. WireGuard configuration ────────────────────────────────────────────────
header "WireGuard setup"

WG_CONF="/etc/wireguard/wg0.conf"

if [[ -f "${WG_CONF}" ]]; then
    ok "WireGuard config already exists at ${WG_CONF}, skipping paste"
else
    echo ""
    echo -e "${YELLOW}Paste your WireGuard CLIENT config from the UDM Pro.${RESET}"
    echo -e "${CYAN}It should look like:${RESET}"
    cat <<'EXAMPLE'
  [Interface]
  PrivateKey = <key>
  Address = 10.100.0.x/24
  DNS = 10.0.0.3, 10.0.0.2, 1.1.1.1

  [Peer]
  PublicKey = <key>
  Endpoint = home.rammos.family:<port>
  AllowedIPs = 0.0.0.0/0
  PersistentKeepalive = 25
EXAMPLE
    echo ""
    echo -e "${YELLOW}Paste now, then press Enter and Ctrl+D:${RESET}"

    WG_CONFIG=$(cat)
    [[ -n "${WG_CONFIG}" ]] || die "No WireGuard config provided"

    # ── Validate structure ────────────────────────────────────────────────
    echo "${WG_CONFIG}" | grep -q "^\[Interface\]" || \
        die "Config missing [Interface] section — check the paste"
    echo "${WG_CONFIG}" | grep -q "PrivateKey" || \
        die "Config missing PrivateKey — check the paste"
    echo "${WG_CONFIG}" | grep -q "\[Peer\]" || \
        die "Config missing [Peer] section — check the paste"

    # ── Inject AllowedIPs = 0.0.0.0/0 if missing or incomplete ──────────
    if echo "${WG_CONFIG}" | grep -q "AllowedIPs"; then
        EXISTING_ALLOWED=$(echo "${WG_CONFIG}" | grep "AllowedIPs" | head -1)
        if echo "${EXISTING_ALLOWED}" | grep -q "0\.0\.0\.0/0"; then
            ok "AllowedIPs already includes 0.0.0.0/0 — full tunnel confirmed"
        else
            warn "AllowedIPs found but does not include 0.0.0.0/0"
            warn "Found: ${EXISTING_ALLOWED}"
            warn "Replacing with AllowedIPs = 0.0.0.0/0 for full tunnel routing"
            WG_CONFIG=$(echo "${WG_CONFIG}" | sed 's|^AllowedIPs.*|AllowedIPs = 0.0.0.0/0|')
            ok "AllowedIPs replaced with 0.0.0.0/0"
        fi
    else
        warn "No AllowedIPs line found — injecting 0.0.0.0/0 after [Peer]"
        WG_CONFIG=$(echo "${WG_CONFIG}" | sed 's|^\[Peer\]|[Peer]\nAllowedIPs = 0.0.0.0/0|')
        ok "AllowedIPs = 0.0.0.0/0 injected"
    fi

    # ── Warn if DNS is missing ────────────────────────────────────────────
    if ! echo "${WG_CONFIG}" | grep -q "^DNS"; then
        warn "No DNS line found in config."
        warn "Internal domains (*.rammos.me) won't resolve without it."
        warn "After setup, add this to [Interface] in ${WG_CONF}:"
        warn "  DNS = 10.0.0.3, 10.0.0.2, 1.1.1.1"
        warn "Then run: systemctl restart wg-quick@wg0"
    else
        ok "DNS line present in config"
    fi

    # ── Write config ──────────────────────────────────────────────────────
    echo "${WG_CONFIG}" > "${WG_CONF}"
    chmod 600 "${WG_CONF}"
    ok "WireGuard config written to ${WG_CONF}"

    log "Final config (PrivateKey redacted):"
    grep -v "PrivateKey" "${WG_CONF}" | sed 's/^/  /'
fi

# Save original gateway for watchdog recovery
mkdir -p /etc/wireguard
cat > /etc/wireguard/original-gw.conf <<EOF
ORIGINAL_GW=${ORIGINAL_GW}
ORIGINAL_IFACE=${ORIGINAL_IFACE}
EOF
ok "Original gateway saved for watchdog"

# ── 6. WireGuard watchdog ─────────────────────────────────────────────────────
header "Installing WireGuard watchdog"

cat > /usr/local/bin/wg-watchdog.sh <<'WATCHDOG'
#!/usr/bin/env bash
# wg-watchdog.sh — WireGuard tunnel health monitor
# Pings OMV every run. On 3 consecutive failures:
#   - Brings WireGuard down
#   - Restores direct internet access
#   - Sends Pushover alert
#   - After 30 minutes, restarts WireGuard automatically

set -euo pipefail

CONF="/etc/wireguard/original-gw.conf"
STATE_FILE="/var/run/wg-watchdog-failures"
MAX_FAILURES=3
RECOVERY_WINDOW=1800
CHECK_HOST="10.0.0.99"

PUSHOVER_APP_TOKEN=""
PUSHOVER_USER_KEY=""
DR_CONF="/opt/homelab-seed/dr.conf"
[[ -f "${DR_CONF}" ]] && source "${DR_CONF}" 2>/dev/null || true

pushover() {
    [[ -z "${PUSHOVER_APP_TOKEN}" ]] && return
    curl -s \
        --form-string "token=${PUSHOVER_APP_TOKEN}" \
        --form-string "user=${PUSHOVER_USER_KEY}" \
        --form-string "title=VPS WireGuard Alert" \
        --form-string "message=$1" \
        --form-string "priority=1" \
        https://api.pushover.net/1/messages.json > /dev/null 2>&1 || true
}

[[ -f "${CONF}" ]] || exit 0
source "${CONF}"

failures=0
[[ -f "${STATE_FILE}" ]] && failures=$(cat "${STATE_FILE}" 2>/dev/null || echo 0)

if ping -c 2 -W 3 -I wg0 "${CHECK_HOST}" &>/dev/null 2>&1; then
    if [[ ${failures} -gt 0 ]]; then
        echo "0" > "${STATE_FILE}"
        pushover "WireGuard tunnel recovered — OMV reachable again"
    fi
    exit 0
fi

failures=$((failures + 1))
echo "${failures}" > "${STATE_FILE}"

if [[ ${failures} -lt ${MAX_FAILURES} ]]; then
    logger -t wg-watchdog "Tunnel check failed (${failures}/${MAX_FAILURES})"
    exit 0
fi

if ! systemctl is-active --quiet wg-quick@wg0; then
    DOWN_SINCE_FILE="/var/run/wg-watchdog-down-since"
    if [[ ! -f "${DOWN_SINCE_FILE}" ]]; then
        date +%s > "${DOWN_SINCE_FILE}"
        exit 0
    fi
    down_since=$(cat "${DOWN_SINCE_FILE}")
    now=$(date +%s)
    elapsed=$((now - down_since))
    if [[ ${elapsed} -ge ${RECOVERY_WINDOW} ]]; then
        logger -t wg-watchdog "Recovery window passed — restarting WireGuard"
        rm -f "${DOWN_SINCE_FILE}"
        echo "0" > "${STATE_FILE}"
        systemctl restart wg-quick@wg0
        pushover "WireGuard restarted after ${RECOVERY_WINDOW}s recovery window"
    fi
    exit 0
fi

logger -t wg-watchdog "Tunnel failed ${failures} times — restoring direct internet"
systemctl stop wg-quick@wg0
ip route del default 2>/dev/null || true
ip route add default via "${ORIGINAL_GW}" dev "${ORIGINAL_IFACE}" 2>/dev/null || true
date +%s > /var/run/wg-watchdog-down-since
echo "0" > "${STATE_FILE}"
pushover "WireGuard tunnel failed — direct internet restored for ${RECOVERY_WINDOW}s. SSH to VPS public IP to fix."
WATCHDOG

chmod +x /usr/local/bin/wg-watchdog.sh

cat > /etc/systemd/system/wg-watchdog.service <<'EOF'
[Unit]
Description=WireGuard tunnel watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wg-watchdog.sh
EOF

cat > /etc/systemd/system/wg-watchdog.timer <<'EOF'
[Unit]
Description=Run WireGuard watchdog every 2 minutes
Requires=wg-watchdog.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable wg-watchdog.timer
ok "Watchdog installed (checks every 2 min, 30-min recovery window)"

# ── 7. Start WireGuard ────────────────────────────────────────────────────────
header "Starting WireGuard"

echo ""
warn "═══════════════════════════════════════════════════════════"
warn "  POINT OF NO RETURN"
warn ""
warn "  WireGuard will start with AllowedIPs = 0.0.0.0/0"
warn "  ALL traffic will route through your UDM Pro."
warn "  If the tunnel fails, the watchdog restores direct"
warn "  internet access within ~6 minutes."
warn ""
warn "  Checklist:"
warn "  ✓ SSH key installed for george"
warn "  ✓ Password auth disabled"
warn "  ✓ UDM WireGuard server is running"
warn "  ✓ home.rammos.family resolves to your home IP"
warn "  ✓ VPS is added as a peer on UDM with AllowedIPs = 10.100.0.x/32"
warn "═══════════════════════════════════════════════════════════"
echo ""
read -r -p "  Start WireGuard now? (yes/no): " start_wg
[[ "${start_wg}" == "yes" ]] || die "Aborted. Run 'systemctl start wg-quick@wg0' when ready."

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
sleep 5

# ── 8. Verify tunnel ──────────────────────────────────────────────────────────
header "Verifying tunnel"

log "Testing connectivity to OMV (10.0.0.99)..."
if ping -c 3 -W 5 10.0.0.99 &>/dev/null; then
    ok "OMV reachable via WireGuard ✓"
else
    err "Cannot reach OMV at 10.0.0.99"
    err "Watchdog will restore direct internet in ~6 min if this persists"
    warn "Check: UDM WireGuard server has VPS peer with AllowedIPs = 10.100.0.x/32"
    read -r -p "  Continue anyway? (yes/no): " cont
    [[ "${cont}" == "yes" ]] || die "Aborted."
fi

log "Testing DNS resolution of internal domains..."
if host gitea.rammos.me &>/dev/null 2>&1; then
    ok "Internal DNS (*.rammos.me) resolves ✓"
else
    warn "Cannot resolve gitea.rammos.me"
    warn "Add to [Interface] in ${WG_CONF}: DNS = 10.0.0.3, 10.0.0.2, 1.1.1.1"
    warn "Then: systemctl restart wg-quick@wg0"
fi

systemctl start wg-watchdog.timer
ok "Watchdog timer started"

# ── 9. Clone homelab repo ─────────────────────────────────────────────────────
header "Cloning homelab repo"

HOMELAB_DIR="/home/george/homelab"

if [[ -d "${HOMELAB_DIR}" ]]; then
    ok "Homelab repo already cloned"
else
    if host gitea.rammos.me &>/dev/null 2>&1; then
        log "Cloning george/homelab from Gitea..."
        sudo -u george git clone \
            https://gitea.rammos.me/george/homelab.git \
            "${HOMELAB_DIR}"
        sudo -u george git -C "${HOMELAB_DIR}" checkout dr
        ok "Homelab repo cloned at ${HOMELAB_DIR} (dr branch)"
    else
        warn "DNS not resolving — skipping homelab clone"
        warn "Once DNS is fixed, run manually:"
        warn "  sudo -u george git clone https://gitea.rammos.me/george/homelab.git ~/homelab"
        warn "  git -C ~/homelab checkout dr"
    fi
fi

# ── 10. Summary ───────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}  ✅  VPS initialisation complete${RESET}"
echo ""
echo "  System:"
echo "    User:     george (uid 1000, gid 100, sudo, docker)"
echo "    SSH:      key-only, password auth disabled, fail2ban active"
echo "    Docker:   $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')"
echo "    WG:       $(systemctl is-active wg-quick@wg0) — all traffic via UDM"
echo "    Watchdog: $(systemctl is-active wg-watchdog.timer)"
echo ""
echo "  Next step — run DR setup as george:"
echo "    su - george"
echo "    sudo bash ~/homelab/dr/setup-vps.sh"
echo ""
echo "  Watchdog behaviour:"
echo "    • Checks tunnel every 2 minutes"
echo "    • 3 failures → WG down, direct internet restored, Pushover alert"
echo "    • 30-minute window to SSH in and fix"
echo "    • After 30 minutes → WireGuard automatically restarts"
echo -e "${GREEN}════════════════════════════════════════════════════════════${RESET}"
