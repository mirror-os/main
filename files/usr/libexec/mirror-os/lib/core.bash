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

die() {
    log "ERROR: $*"
    echo "mirror-os: error: $*" >&2
    # When running in stream mode (called from the software center), also emit to
    # stdout so the error reaches the GUI dialog — stderr is discarded there.
    [ "${MIRROR_OS_STREAM:-0}" = "1" ] && echo "nix-error: $*"
    exit 1
}

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
    # Capture HM output in a temp file for error extraction in both modes.
    local hm_out
    hm_out=$(mktemp)
    if [ "${MIRROR_OS_STREAM:-0}" = "1" ]; then
        # Stream mode: tee to stdout (progress tracking), log file, and temp file.
        home-manager switch --flake ".#$USER" --impure 2>&1 | tee -a "$LOG_FILE" "$hm_out"
    else
        # Normal mode: tee to log file; redirect stdout to temp file (no terminal clutter).
        home-manager switch --flake ".#$USER" --impure 2>&1 | tee -a "$LOG_FILE" > "$hm_out"
    fi
    local hm_status=${PIPESTATUS[0]}

    if [ "$hm_status" -eq 0 ]; then
        rm -f "$hm_out"
        echo "Done."
        log "home-manager switch succeeded"
    else
        log "WARNING: home-manager switch failed"
        # Extract Nix/HM error: find the first "error:" line and capture the full chain
        # from there (root cause → context → derivationStrict at the bottom).
        # Showing from the first error line ensures the root cause is always visible.
        local hm_errors first_error_line
        first_error_line=$(grep -n "^error:" "$hm_out" 2>/dev/null | head -1 | cut -d: -f1 || true)
        if [ -n "$first_error_line" ]; then
            hm_errors=$(tail -n "+${first_error_line}" "$hm_out" 2>/dev/null | head -50 || true)
        else
            hm_errors=$(tail -20 "$hm_out" 2>/dev/null || true)
        fi
        # Classify the error to give the user a human-readable diagnosis ahead of
        # the raw Nix trace.  Emit a nix-error-type: line (software center displays
        # it as a highlighted prefix) or print it first on the terminal.
        local error_class=""
        if grep -q "does not exist" <<< "$hm_errors" 2>/dev/null; then
            error_class="Unknown option: this option is not available in your current configuration."
        elif grep -q "is not of type" <<< "$hm_errors" 2>/dev/null; then
            error_class="Invalid value: the value entered does not match the expected type for this option."
        elif grep -q "home\.file\." <<< "$hm_errors" 2>/dev/null \
          && grep -q "modules/programs/" <<< "$hm_errors" 2>/dev/null; then
            error_class="Incompatibility: enabling this option conflicts with another module in your configuration."
        fi
        # Auto-retry: when HM refuses to clobber a pre-existing unmanaged config file,
        # retry with -b backup which renames the conflicting file to <name>.backup.
        if grep -q "would be clobbered" "$hm_out" 2>/dev/null; then
            local retry_out
            retry_out=$(mktemp)
            echo "Backing up conflicting files and retrying..."
            if [ "${MIRROR_OS_STREAM:-0}" = "1" ]; then
                home-manager switch --flake ".#$USER" --impure -b backup 2>&1 \
                    | tee -a "$LOG_FILE" "$retry_out"
            else
                home-manager switch --flake ".#$USER" --impure -b backup 2>&1 \
                    | tee -a "$LOG_FILE" > "$retry_out"
            fi
            local retry_status=${PIPESTATUS[0]}
            rm -f "$retry_out" "$hm_out"
            if [ "$retry_status" -eq 0 ]; then
                echo "Done. (conflicting files backed up with .backup extension)"
                log "home-manager switch succeeded after -b backup retry"
                return 0
            fi
            # Retry also failed; re-point hm_out to an empty temp file so the
            # downstream rm -f still has a valid target.
            hm_out=$(mktemp)
            hm_errors=""
        fi

        rm -f "$hm_out"
        if [ -n "$hm_errors" ]; then
            if [ "${MIRROR_OS_STREAM:-0}" = "1" ]; then
                # Emit error class first so the software center can prepend it.
                [ -n "$error_class" ] && echo "nix-error-type: ${error_class}"
                # Emit with a prefix so the software center can collect and display them.
                while IFS= read -r line; do echo "nix-error: ${line}"; done <<< "$hm_errors"
            else
                [ -n "$error_class" ] && echo "⚠ ${error_class}" >&2
                echo "$hm_errors" >&2
            fi
        fi
        if $made_commit; then
            if git -C "$HM_CONFIG_DIR" reset --hard HEAD~1 2>/dev/null; then
                log "reverted HM config commit after switch failure"
                if [ "${MIRROR_OS_STREAM:-0}" = "1" ]; then
                    echo "nix-error: (Your previous configuration has been restored)"
                else
                    echo "Your previous configuration has been restored." >&2
                fi
            else
                log "WARNING: could not undo HM config commit after switch failure"
            fi
        fi
        die "home-manager switch failed — check $LOG_FILE"
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
