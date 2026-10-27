#!/usr/bin/env bash
#
# splashtop-keepalive.sh
# Keeps Splashtop Streamer (SRStreamer.service) online on Fedora.
#
# Usage:
#   sudo ./splashtop-keepalive.sh install            # set everything up
#   sudo ./splashtop-keepalive.sh install --no-sleep # also block suspend/hibernate
#   sudo ./splashtop-keepalive.sh check              # one-off health check (what the timer runs)
#   sudo ./splashtop-keepalive.sh restart            # force restart the streamer now
#   sudo ./splashtop-keepalive.sh status             # show service, timers, recent log
#   sudo ./splashtop-keepalive.sh uninstall          # remove everything this script added
#
# What "install" does:
#   1. Drop-in override so systemd auto-restarts SRStreamer if it dies,
#      and waits for the network before starting it.
#   2. A watchdog timer that checks the service every 5 minutes and restarts it if needed.
#   3. A daily restart timer (05:30) to clear stale cloud connections.
#   4. Optional (--no-sleep): masks sleep/suspend/hibernate targets.
#
# Logs go to the journal:  journalctl -t splashtop-keepalive

set -euo pipefail

SERVICE="SRStreamer.service"
TAG="splashtop-keepalive"
INSTALL_PATH="/usr/local/sbin/splashtop-keepalive"
UNIT_DIR="/etc/systemd/system"
DROPIN_DIR="${UNIT_DIR}/${SERVICE}.d"
DAILY_RESTART_TIME="05:30"
CHECK_INTERVAL="5min"

log() {
    echo "[$TAG] $*"
    logger -t "$TAG" -- "$*" 2>/dev/null || true
}

need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Run this as root (sudo $0 $*)" >&2
        exit 1
    fi
}

service_exists() {
    systemctl list-unit-files --no-legend "$SERVICE" 2>/dev/null | grep -q "^${SERVICE}"
}

wait_for_network() {
    # Up to 60s for a default route and working DNS/connectivity
    local i
    for i in $(seq 1 30); do
        if ip route show default 2>/dev/null | grep -q default; then
            if getent hosts my.splashtop.com >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 2
    done
    return 1
}

do_restart() {
    log "Restarting $SERVICE"
    wait_for_network || log "Network still not fully up, restarting anyway"
    systemctl restart "$SERVICE"
    sleep 5
    if systemctl is-active --quiet "$SERVICE"; then
        log "$SERVICE is running"
    else
        log "ERROR: $SERVICE failed to start. See: journalctl -u $SERVICE -n 50"
        return 1
    fi
}

do_check() {
    if ! service_exists; then
        log "ERROR: $SERVICE not found. Is splashtop-streamer installed?"
        exit 1
    fi

    if ! systemctl is-enabled --quiet "$SERVICE"; then
        log "$SERVICE was disabled, enabling it"
        systemctl enable "$SERVICE"
    fi

    local state
    state="$(systemctl is-active "$SERVICE" || true)"
    if [[ "$state" != "active" ]]; then
        log "$SERVICE state is '$state', recovering"
        systemctl reset-failed "$SERVICE" 2>/dev/null || true
        do_restart
    fi
}

do_install() {
    local no_sleep="${1:-}"

    if ! service_exists; then
        echo "ERROR: $SERVICE not found. Install splashtop-streamer first." >&2
        exit 1
    fi

    log "Installing keepalive to $INSTALL_PATH"
    install -m 0755 "$(readlink -f "$0")" "$INSTALL_PATH"
    # SELinux: make sure the copied script has the right label for systemd to run it
    command -v restorecon >/dev/null && restorecon -F "$INSTALL_PATH" || true

    # 1. Auto-restart + wait for network
    mkdir -p "$DROPIN_DIR"
    cat > "${DROPIN_DIR}/keepalive.conf" <<EOF
[Unit]
Wants=network-online.target
After=network-online.target

[Service]
Restart=always
RestartSec=15
EOF

    # 2. Watchdog check every 5 minutes
    cat > "${UNIT_DIR}/splashtop-keepalive.service" <<EOF
[Unit]
Description=Splashtop Streamer health check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} check
EOF

    cat > "${UNIT_DIR}/splashtop-keepalive.timer" <<EOF
[Unit]
Description=Check Splashtop Streamer every ${CHECK_INTERVAL}

[Timer]
OnBootSec=2min
OnUnitActiveSec=${CHECK_INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # 3. Daily restart
    cat > "${UNIT_DIR}/splashtop-daily-restart.service" <<EOF
[Unit]
Description=Daily restart of Splashtop Streamer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} restart
EOF

    cat > "${UNIT_DIR}/splashtop-daily-restart.timer" <<EOF
[Unit]
Description=Restart Splashtop Streamer daily at ${DAILY_RESTART_TIME}

[Timer]
OnCalendar=*-*-* ${DAILY_RESTART_TIME}:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # 4. Optional: stop the machine from sleeping
    if [[ "$no_sleep" == "--no-sleep" ]]; then
        log "Masking sleep/suspend/hibernate targets"
        systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    fi

    systemctl daemon-reload
    systemctl enable "$SERVICE"
    systemctl enable --now splashtop-keepalive.timer splashtop-daily-restart.timer
    do_restart

    echo
    log "Install complete."
    do_status
}

do_uninstall() {
    log "Removing keepalive"
    systemctl disable --now splashtop-keepalive.timer splashtop-daily-restart.timer 2>/dev/null || true
    rm -f "${UNIT_DIR}/splashtop-keepalive."{service,timer}
    rm -f "${UNIT_DIR}/splashtop-daily-restart."{service,timer}
    rm -f "${DROPIN_DIR}/keepalive.conf"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    rm -f "$INSTALL_PATH"
    systemctl daemon-reload
    echo "Removed. If you used --no-sleep, re-enable sleep with:"
    echo "  sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target"
}

do_status() {
    echo "== $SERVICE =="
    systemctl --no-pager status "$SERVICE" | head -n 8 || true
    echo
    echo "== Timers =="
    systemctl --no-pager list-timers 'splashtop-*' || true
    echo
    echo "== Sleep targets =="
    for t in sleep suspend hibernate; do
        printf '  %-10s %s\n' "$t" "$(systemctl is-enabled ${t}.target 2>/dev/null || echo unknown)"
    done
    echo
    echo "== Recent keepalive log =="
    journalctl -t "$TAG" -n 10 --no-pager 2>/dev/null || true
}

case "${1:-}" in
    install)   need_root "$@"; do_install "${2:-}" ;;
    check)     need_root "$@"; do_check ;;
    restart)   need_root "$@"; do_restart ;;
    status)    do_status ;;
    uninstall) need_root "$@"; do_uninstall ;;
    *)
        sed -n '3,20p' "$0"
        exit 1
        ;;
esac
