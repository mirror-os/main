# mirror-os lib/cmd-system.bash — OS system management commands
# Sourced by mirror-os; do not execute directly.
#
# Subcommands:
#   mirror-os system update          — stage latest image update (requires root)
#   mirror-os system status          — (future) show current/staged image info
#   mirror-os system rollback        — (future) rollback to previous image
#   mirror-os system rebase <ref>    — (future) rebase to a different image

cmd_system() {
    local subcmd="${1:-}"
    shift || true
    case "$subcmd" in
        update)   cmd_system_update "$@" ;;
        "") die "Usage: mirror-os system <subcommand>. Available: update" ;;
        *)  die "Unknown system subcommand: '${subcmd}'. Available: update" ;;
    esac
}

cmd_system_update() {
    # Re-exec as root if needed
    if [ "$(id -u)" -ne 0 ]; then
        exec sudo /usr/bin/mirror-os system update "$@"
    fi

    local LOG="/var/log/mirror-os-update.log"

    _syslog() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
        if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
            mv "$LOG" "${LOG}.1"
            touch "$LOG"
        fi
    }

    _syslog "=== mirror-os system update: checking for updates ==="

    echo "Checking for Mirror OS updates..."
    echo "(Image signature will be verified automatically.)"
    echo ""

    if bootc upgrade; then
        _syslog "bootc upgrade completed successfully"
    else
        _syslog "ERROR: bootc upgrade failed (exit code $?)"
    fi

    echo ""
    echo "Run 'bootc status' to check if an update was staged."
    echo "Reboot when ready to apply:  systemctl reboot"
}
