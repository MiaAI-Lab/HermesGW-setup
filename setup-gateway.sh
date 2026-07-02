#!/usr/bin/env bash
#
# Hermes Gateway Desktop Setup Wizard
# Configures a remote backend for the Hermes Desktop app.
#
# Usage:
#   Non-interactive (recommended): bash setup-gateway.sh
#   With custom values:            bash setup-gateway.sh admin MyPass123! 9119
#   Interactive mode:              INTERACTIVE=1 bash setup-gateway.sh
#   curl:                          curl -fsSL https://raw.githubusercontent.com/MiaAI-Lab/HermesGW-Desktop-setup/main/setup-gateway.sh | bash
#
# Requirements:
#   - Hermes Agent installed (hermes command on PATH)
#   - Linux with systemd (user services)
#   - Network access on the chosen port

set -eo pipefail

# ── Colors & symbols ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

INFO()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
OK()    { echo -e "${GREEN}[  OK  ]${NC}  $*"; }
WARN()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ERROR() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
HEADING() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}\n"; }

# ── Detect IPs ────────────────────────────────────────────────────
detect_ips() {
    LAN_IP=$(ip -4 addr show 2>/dev/null | grep -E 'inet ' | grep -v '127.0.0.1' | grep -vE 'docker|virbr|veth|lo' | head -1 | awk '{print $2}' | cut -d/ -f1) || true
    [[ -z "$LAN_IP" ]] && LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true

    TAILSCALE_IP=$(ip -4 addr show tailscale0 2>/dev/null | grep 'inet ' | head -1 | awk '{print $2}' | cut -d/ -f1) || true

    HOSTNAME=$(hostname 2>/dev/null) || true
    HOSTNAME="${HOSTNAME:-localhost}"

    PORT=9119
}

# ── Check prerequisites ──────────────────────────────────────────
check_prereqs() {
    local has_error=0

    if ! command -v hermes &>/dev/null; then
        ERROR "Hermes CLI not found. Install it first:"
        ERROR "  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
        has_error=1
    else
        OK "Hermes CLI found: $(which hermes)"
    fi

    # Verify 'hermes serve' subcommand exists (v0.18.0+)
    if ! hermes serve --help &>/dev/null 2>&1; then
        ERROR "'hermes serve' subcommand not available."
        ERROR "This script requires Hermes v0.18.0 or newer."
        ERROR "Update Hermes: hermes update"
        has_error=1
    else
        OK "'hermes serve' subcommand available"
    fi

    if systemctl --user status &>/dev/null 2>&1; then
        OK "systemd user services available"
    else
        WARN "systemd user services may not be available."
        WARN "The wizard will still configure credentials and start the server."
        WARN "Systemd setup will be skipped."
    fi

    if ! command -v openssl &>/dev/null; then
        ERROR "openssl not found. Install it to generate a secure secret."
        has_error=1
    else
        OK "openssl available"
    fi

    if [[ $has_error -eq 1 ]]; then
        ERROR "Fix the issues above and run the wizard again."
        exit 1
    fi
}

# ── Parse flags ───────────────────────────────────────────────────
CLEAN=0
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
set -- "${POSITIONAL[@]}"

# ── Check if already configured ──────────────────────────────────
check_existing_config() {
    local env_file="$HOME/.hermes/.env"

    if [[ -f "$env_file" ]]; then
        if grep -q "HERMES_DASHBOARD_BASIC_AUTH_USERNAME" "$env_file" 2>/dev/null; then
            if [[ $CLEAN -eq 1 ]]; then
                INFO "Running in --clean mode — overwriting existing credentials."
            else
                WARN "Remote backend credentials already exist in $env_file"
                if [[ "${INTERACTIVE:-0}" == "1" ]]; then
                    echo ""
                    echo -n "  Reconfigure? [y/N] "
                    read -r -t 10 ANSWER 2>/dev/null || true
                    ANSWER="${ANSWER:-N}"
                    if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
                        INFO "Keeping existing configuration."
                        return 1
                    fi
                else
                    INFO "Existing config detected. Skipping (run with --clean to overwrite)."
                    return 1
                fi
            fi
        fi
    fi
    return 0
}

# ── Setup credentials ────────────────────────────────────────────
setup_credentials() {
    HEADING "Remote Backend Credentials"

    USERNAME="${1:-admin}"
    local password="${2:-}"

    if [[ -z "$password" ]]; then
        password=$(openssl rand -base64 12)
        WARN "No password provided. Generated one:"
        WARN "  Password: $password"
        # Print to stderr so it shows even when piped to bash
        echo "" >&2
        echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}" >&2
        echo -e "${BOLD}${GREEN}║  SAVE THIS PASSWORD:  $password${NC}" >&2
        echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}" >&2
        echo "" >&2
    fi
    PASSWORD="$password"

    if [[ ${#PASSWORD} -lt 8 ]]; then
        WARN "Password is less than 8 characters — consider a stronger one."
        if [[ "${INTERACTIVE:-0}" == "1" ]]; then
            echo -n "  Continue anyway? [y/N] "
            read -r -t 10 ANSWER 2>/dev/null || true
            if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
                ERROR "Aborted."
                exit 1
            fi
        fi
    fi

    SECRET=$(openssl rand -base64 32)
    OK "Generated stable auth secret (survives restarts)"

    echo ""
    INFO "Credentials summary:"
    INFO "  Username: $USERNAME"
    INFO "  Password: (hidden)"
    INFO "  Secret:   $SECRET"

    # Write to .env
    local env_file="$HOME/.hermes/.env"
    local tmp_file
    tmp_file=$(mktemp)

    if [[ -f "$env_file" ]]; then
        grep -v "HERMES_DASHBOARD_BASIC_AUTH" "$env_file" > "$tmp_file" 2>/dev/null || true
        cp "$tmp_file" "$env_file"
    fi

    cat >> "$env_file" <<EOF

# ═══════════════════════════════════════════════════════════════════
# Hermes Gateway Desktop — Remote Backend Auth
# Generated by setup-gateway.sh on $(date)
# ═══════════════════════════════════════════════════════════════════
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=$USERNAME
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$PASSWORD
HERMES_DASHBOARD_BASIC_AUTH_SECRET=$SECRET
EOF

    chmod 600 "$env_file"
    rm -f "$tmp_file"

    OK "Credentials written to $env_file"
}

# ── Configure port ────────────────────────────────────────────────
setup_port() {
    HEADING "Port Configuration"

    echo "  Available IPs:"
    if [[ -n "$LAN_IP" ]]; then
        echo "    LAN:      $LAN_IP"
    else
        echo "    LAN:      (not detected — you'll enter it manually)"
    fi
    if [[ -n "$TAILSCALE_IP" ]]; then
        echo "    Tailscale: $TAILSCALE_IP"
    else
        echo "    Tailscale: (not detected — not connected?)"
    fi
    echo ""

    PORT="${3:-9119}"

    local port_in_use=0
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":$PORT " 2>/dev/null && port_in_use=1 || true
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -q ":$PORT " 2>/dev/null && port_in_use=1 || true
    fi

    if [[ $port_in_use -eq 1 ]]; then
        WARN "Port $PORT is already in use."
        if [[ "${INTERACTIVE:-0}" == "1" ]]; then
            echo -n "  Use it anyway? [y/N] "
            read -r -t 10 ANSWER 2>/dev/null || true
            if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
                ERROR "Aborted."
                exit 1
            fi
        else
            INFO "Port $PORT is already in use. Skipping port check."
        fi
    else
        OK "Port $PORT is available"
    fi
}

# ── Start the backend server ─────────────────────────────────────
start_backend() {
    HEADING "Starting Backend Server"

    # Check if systemd is managing this service
    if systemctl --user is-active hermes-serve.service &>/dev/null 2>&1; then
        OK "Server already running via systemd (PID: $(systemctl --user show -p MainPID --value hermes-serve.service 2>/dev/null || echo 'unknown'))"
        return 0
    fi

    # Check if port is in use by any process
    local port_in_use=0
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":$PORT " 2>/dev/null && port_in_use=1 || true
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -q ":$PORT " 2>/dev/null && port_in_use=1 || true
    fi

    if [[ $port_in_use -eq 1 ]]; then
        INFO "A process is already listening on port $PORT"
        if [[ "${INTERACTIVE:-0}" == "1" ]]; then
            echo -n "  Stop it and start fresh? [y/N] "
            read -r -t 10 ANSWER 2>/dev/null || true
            if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
                pkill -f "hermes serve.*--port $PORT" 2>/dev/null || true
                sleep 2
            else
                INFO "Keeping existing process. Skipping server start."
                return 0
            fi
        else
            INFO "Port $PORT is already in use. Skipping server start."
            return 0
        fi
    fi

    INFO "Starting hermes serve on 0.0.0.0:$PORT ..."

    # Start in background using nohup with proper redirection
    nohup hermes serve --host 0.0.0.0 --port "$PORT" >> /tmp/hermes-serve.log 2>&1 &
    local pid=$!

    # Give the process a moment to initialize
    sleep 2

    # Check if the process is still alive
    if ! kill -0 $pid 2>/dev/null; then
        ERROR "Server failed to start. Process exited immediately."
        if [[ -f /tmp/hermes-serve.log ]]; then
            WARN "Logs:"
            cat /tmp/hermes-serve.log | head -20
        fi
        return 1
    fi

    # Wait for port to be listening
    local max_wait=30 waited=0
    while [[ $waited -lt $max_wait ]]; do
        local running=0
        if command -v ss &>/dev/null; then
            ss -tlnp 2>/dev/null | grep -q ":$PORT " 2>/dev/null && running=1 || true
        elif command -v netstat &>/dev/null; then
            netstat -tlnp 2>/dev/null | grep -q ":$PORT " 2>/dev/null && running=1 || true
        fi
        if [[ $running -eq 1 ]]; then
            OK "Server started (PID: $pid)"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    WARN "Server may not have started. Check logs:"
    if [[ -f /tmp/hermes-serve.log ]]; then
        WARN "  cat /tmp/hermes-serve.log"
    else
        WARN "  (log file not created)"
    fi
    return 1
}

# ── Set up systemd service ───────────────────────────────────────
setup_systemd() {
    HEADING "Systemd Service Setup"

    if ! systemctl --user status &>/dev/null 2>&1; then
        WARN "systemd user services not available. Skipping service setup."
        WARN "To keep the server running, use:"
        WARN "  tmux new-session -d -s hermes-serve 'hermes serve --host 0.0.0.0 --port $PORT'"
        return 0
    fi

    local service_file="$HOME/.config/systemd/user/hermes-serve.service"
    mkdir -p "$HOME/.config/systemd/user"

    cat > "$service_file" <<EOF
[Unit]
Description=Hermes Backend Server (powers the Desktop app)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=$(which hermes) serve --host 0.0.0.0 --port $PORT
Restart=always
RestartSec=5
Environment=HOME=$HOME
Environment=HERMES_HOME=$HOME/.hermes
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hermes-serve

[Install]
WantedBy=default.target
EOF

    OK "Service file created: $service_file"

    systemctl --user daemon-reload
    OK "systemd reloaded"

    systemctl --user enable --now hermes-serve.service
    OK "Service enabled and started"

    if systemctl --user is-active hermes-serve.service &>/dev/null 2>&1; then
        OK "Service is active (running)"
    else
        WARN "Service may not have started. Check status:"
        WARN "  systemctl --user status hermes-serve.service"
    fi
}

# ── Enable linger ─────────────────────────────────────────────────
setup_linger() {
    HEADING "Login Linger"

    if ! command -v loginctl &>/dev/null; then
        WARN "loginctl not found. Skipping linger setup."
        return 0
    fi

    if loginctl show-user "$(whoami)" 2>/dev/null | grep -q "Linger=yes"; then
        OK "Linger already enabled for $(whoami)"
        return 0
    fi

    if [[ "${INTERACTIVE:-0}" == "1" ]]; then
        echo -n "  Enable linger so the server starts on boot? [Y/n] "
        read -r -t 10 ANSWER 2>/dev/null || true
        ANSWER="${ANSWER:-Y}"
        if [[ "$ANSWER" =~ ^[Nn]$ ]]; then
            WARN "Server won't auto-start on boot without linger."
            return 0
        fi
    fi

    loginctl enable-linger "$(whoami)"
    OK "Linger enabled — server will start on boot"
}

# ── Print final instructions ─────────────────────────────────────
print_final_instructions() {
    HEADING "🎉 Setup Complete!"

    echo -e "${GREEN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  Your next step: Connect the Hermes Desktop app              ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"

    echo -e "${BOLD}1️⃣  Open the Hermes Desktop app → Settings → Gateway${NC}\n"

    echo -e "${BOLD}2️⃣  Enter these connection details:${NC}"
    echo ""
    echo -e "  ${BOLD}Remote gateway URL:${NC}"
    if [[ -n "$LAN_IP" ]]; then
        echo -e "    http://$LAN_IP:$PORT  (LAN — fastest)"
    else
        echo -e "    (LAN IP not detected — run: hostname -I)"
    fi
    if [[ -n "$TAILSCALE_IP" ]]; then
        echo -e "    http://$TAILSCALE_IP:$PORT  (Tailscale — from anywhere)"
    fi
    echo ""
    echo -e "  ${BOLD}Username:${NC}    $USERNAME"
    echo -e "  ${BOLD}Password:${NC}    $PASSWORD"
    echo ""

    echo -e "${BOLD}3️⃣  Click 'Sign in', then 'Save and reconnect'${NC}\n"

    echo -e "${DIM}That's it. Your Desktop app is now connected to your local Hermes backend.${NC}\n"

    echo -e "${BOLD}🔧 Manage the backend:${NC}"
    echo "  systemctl --user status hermes-serve.service   # status"
    echo "  systemctl --user restart hermes-serve.service  # restart"
    echo "  journalctl --user -u hermes-serve.service -f   # live logs"
    echo ""

    echo -e "${DIM}Setup completed on $(date).${NC}"
    echo ""
    echo -e "Follow me on X: ${BOLD}https://x.com/MiaAI_lab${NC}"
}

# ── Main ──────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║   Mia's Hermes Gateway Desktop Setup Wizard              ║"
    echo "║   Configure a remote backend for the Desktop app         ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    detect_ips
    check_prereqs
    check_existing_config || exit 0
    setup_credentials "${1:-}" "${2:-}"
    setup_port "${3:-}"
    start_backend
    setup_systemd
    setup_linger
    print_final_instructions
}

main "$@"
