# mirror-os lib/core.bash — core helpers: logging, error handling, HM switch
# Sourced by mirror-os; do not execute directly.

log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    local entry="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$entry" >> "$LOG_FILE"
    $VERBOSE_LOG && echo "$entry" >&2 || true
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        mv "$LOG_FILE" "${LOG_FILE}.1"
    fi
}

die() { log "ERROR: $*"; echo "mirror-os: error: $*" >&2; exit 1; }

need_init() {
    [ -f "$HOME/.local/share/mirror-os/.init-complete" ] || \
        die "Mirror OS first-time setup has not completed yet. Please wait for it to finish."
    command -v nix &>/dev/null || \
        die "Nix is not available. Please wait for first-time setup to finish."
    [ -d "$HM_CONFIG_DIR" ] || \
        die "Home Manager config not found at $HM_CONFIG_DIR."
}

trigger_switch() {
    local msg="${1:-mirror-os: apply changes}"
    log "Triggering Home Manager switch"
    git -C "$HM_CONFIG_DIR" add -A 2>/dev/null || true
    # Commit staged changes so home-manager switch doesn't warn about a dirty tree.
    # Track whether we made a commit so we can undo it if the switch fails.
    local made_commit=false
    if ! git -C "$HM_CONFIG_DIR" diff --cached --quiet 2>/dev/null; then
        git -C "$HM_CONFIG_DIR" commit -m "$msg" 2>/dev/null && made_commit=true || true
    fi
    echo "Applying changes (this may take a minute)..."
    cd "$HM_CONFIG_DIR"
    if [ "${MIRROR_OS_STREAM:-0}" = "1" ]; then
        # Stream mode: tee HM output to both stdout (for caller progress tracking)
        # and the log file.  PIPESTATUS[0] captures home-manager's exit code.
        home-manager switch --flake ".#$USER" --impure 2>&1 | tee -a "$LOG_FILE"
        local hm_status=${PIPESTATUS[0]}
        if [ "$hm_status" -eq 0 ]; then
            echo "Done."
            log "home-manager switch succeeded"
        else
            log "WARNING: home-manager switch failed"
            local last_err
            last_err=$(grep "error:" "$LOG_FILE" | tail -1 2>/dev/null || true)
            [ -n "$last_err" ] && echo "$last_err" >&2
            if $made_commit; then
                git -C "$HM_CONFIG_DIR" reset --hard HEAD~1 2>/dev/null || \
                    log "WARNING: could not undo HM config commit after switch failure"
            fi
            die "home-manager switch failed — check $LOG_FILE"
        fi
    else
        if home-manager switch --flake ".#$USER" --impure >> "$LOG_FILE" 2>&1; then
            echo "Done."
            log "home-manager switch succeeded"
        else
            log "WARNING: home-manager switch failed"
            local last_err
            last_err=$(grep "error:" "$LOG_FILE" | tail -1 2>/dev/null || true)
            [ -n "$last_err" ] && echo "$last_err" >&2
            if $made_commit; then
                git -C "$HM_CONFIG_DIR" reset --hard HEAD~1 2>/dev/null || \
                    log "WARNING: could not undo HM config commit after switch failure"
            fi
            die "home-manager switch failed — check $LOG_FILE"
        fi
    fi
}

# Return the module file path for a given app ID
module_file() {
    echo "$APPS_DIR/${1}.nix"
}

# Print a hint if the catalog DB is missing (once per session via flag file)
_catalog_hint_shown=false
catalog_hint() {
    $_catalog_hint_shown && return
    _catalog_hint_shown=true
    echo "hint: catalog not built yet — run 'mirror-os catalog update' or wait for background service" >&2
}
