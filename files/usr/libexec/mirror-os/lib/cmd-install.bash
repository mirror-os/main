# mirror-os lib/cmd-install.bash — install and uninstall commands
# Sourced by mirror-os; do not execute directly.

# ── Canonical ID helpers ─────────────────────────────────────────────────────

# Resolve the canonical (slug-based) filename ID for an app from catalog.db app_map.
# Returns slug if found, else source_id unchanged. Used to name the .nix module file.
# Usage: _resolve_canonical_id <source> <source_id>
_resolve_canonical_id() {
    local source="$1" source_id="$2"
    [ -f "$CATALOG_DB" ] || { echo "$source_id"; return; }
    python3 - "$CATALOG_DB" "$source" "$source_id" << 'PYEOF'
import sys, sqlite3, os
db, source, source_id = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.exists(db):
    print(source_id); sys.exit(0)
try:
    conn = sqlite3.connect(db, timeout=5)
    conn.execute("PRAGMA query_only = ON")
    col = 'flatpak_id' if source == 'flatpak' else 'nix_attr'
    row = conn.execute(f"SELECT slug FROM app_map WHERE {col}=?", (source_id,)).fetchone()
    conn.close()
    print(row[0] if row else source_id)
except Exception:
    print(source_id)
PYEOF
}

# Return the source type of an existing module file: flatpak, nix, pro_flake, or unknown.
_detect_module_source() {
    local file="$1"
    if grep -q "services\.flatpak" "$file" 2>/dev/null; then
        echo "flatpak"
    elif grep -q "home\.packages" "$file" 2>/dev/null; then
        echo "nix"
    elif grep -q "homeManagerModules" "$file" 2>/dev/null; then
        echo "pro_flake"
    else
        echo "unknown"
    fi
}

# Handle "already installed" state for a given canonical_id + desired source.
# If the same source is installed → re-apply and return 1 (caller should return).
# If a different source is installed → prompt to switch; if declined return 1.
# If switch confirmed → removes old file and returns 0 (caller proceeds).
# Usage: _check_or_switch_existing <canonical_id> <source> <name> <new_out_file>
_check_or_switch_existing() {
    local canonical_id="$1" source="$2" name="$3" new_out_file="$4"

    [ -f "$new_out_file" ] || return 0   # not installed — caller proceeds

    local existing_src
    existing_src=$(_detect_module_source "$new_out_file")

    if [ "$existing_src" = "$source" ]; then
        local src_label
        [ "$source" = "flatpak" ] && src_label="Flatpak" || src_label="Nix"
        echo "Already installed via ${src_label}. Re-applying..."
        trigger_switch "mirror-os: re-apply ${canonical_id}"
        return 1
    fi

    # Different source — prompt to switch (skip if --yes)
    local old_label new_label
    [ "$existing_src" = "flatpak" ] && old_label="Flatpak" || old_label="Nix"
    [ "$source"       = "flatpak" ] && new_label="Flatpak" || new_label="Nix"
    if ! ${yes:-false}; then
        printf "'%s' is currently installed via %s. Switch to %s? [y/N] " \
            "$name" "$old_label" "$new_label"
        local confirm
        read -r confirm
        if ! [[ "$confirm" == [yY] ]]; then
            echo "Cancelled."
            return 1
        fi
    fi

    rm "$new_out_file" 2>/dev/null || true
    return 0
}

# Write the right module format for a Nix attr: programs module if mapped, else home.packages.
# $1 = attr, $2 = display_name, $3 = out_file
_write_nix_module_smart() {
    local attr="$1" display_name="$2" out_file="$3"
    local programs_name
    programs_name=$(_lookup_programs_name "$attr")
    if [ -n "$programs_name" ]; then
        write_programs_module "$attr" "$programs_name" "" "$out_file"
        log "install: using programs.${programs_name} module for '${attr}'"
    else
        write_nix_module "$attr" "$display_name" "$out_file"
    fi
}

# ── cmd_install ──────────────────────────────────────────────────────────────

cmd_install() {
    need_init
    mkdir -p "$APPS_DIR"

    local force_flatpak=false force_nix=false use_flake=false pick=false yes=false
    local query="" flake_url="" flake_name="" override_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --flatpak)     force_flatpak=true; shift ;;
            --nix)         force_nix=true; shift ;;
            --flake)       use_flake=true; flake_url="$2"; flake_name="$3"; shift 3 ;;
            --pick|--interactive) pick=true; shift ;;
            --name)        override_name="$2"; shift 2 ;;
            --yes|-y)      yes=true; shift ;;
            *)
                if [ -n "$query" ]; then
                    die "Unexpected argument '${1}'. If the name has spaces, quote it: mirror-os install \"${query} ${1}\""
                fi
                query="$1"; shift ;;
        esac
    done

    # Pro flake install (unchanged — no slug lookup for flakes)
    if $use_flake; then
        [ -z "$flake_url" ] || [ -z "$flake_name" ] && \
            die "Usage: mirror-os install --flake <url> <name>"
        local safe_name="${flake_name//[^a-zA-Z0-9_-]/-}"
        local input_name="mirror-${safe_name}"
        local out_file
        out_file=$(module_file "$safe_name")
        [ -f "$out_file" ] && die "App '${safe_name}' is already installed (${out_file})."

        inject_flake_input "$input_name" "$flake_url"
        echo "Locking flake inputs..."
        (cd "$HM_CONFIG_DIR" && nix flake lock >> "$LOG_FILE" 2>&1) || die "nix flake lock failed"
        write_pro_flake_module "$input_name" "$safe_name" "$out_file"
        log "install: pro flake '${safe_name}' from ${flake_url}"
        echo "Installed pro flake: ${safe_name}"
        trigger_switch "mirror-os: install flake ${safe_name}"
        return
    fi

    [ -z "$query" ] && die "Usage: mirror-os install <app name or ID> [--flatpak | --nix] [--pick]"
    # Strip nixpkgs. prefix (e.g. from nix search output)
    [[ "$query" == nixpkgs.* ]] && query="${query#nixpkgs.}"

    # ── Helper: resolve display name from catalog DB ──────────────────────────
    # Prints name from DB for exact id+source, or empty string if not found.
    _lookup_name() {
        local lookup_id="$1" lookup_source="$2"
        [ -f "$CATALOG_DB" ] || { echo ""; return; }
        python3 - "$CATALOG_DB" "$lookup_id" "$lookup_source" << 'PYEOF'
import sys, sqlite3
db, app_id, source = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    conn = sqlite3.connect(db, timeout=5)
    conn.execute("PRAGMA query_only = ON")
    if source == 'flatpak':
        row = conn.execute("SELECT name FROM flatpak_apps WHERE app_id = ?", (app_id,)).fetchone()
    else:
        row = conn.execute("SELECT pname FROM nix_packages WHERE attr = ?", (app_id,)).fetchone()
    conn.close()
    print(row[0] if row else '')
except Exception:
    print('')
PYEOF
    }

    # Force-flatpak: exact ID lookup first, then FTS search
    if $force_flatpak; then
        # Try treating query as an exact Flatpak app ID
        local exact_name
        exact_name=$(_lookup_name "$query" "flatpak")
        if [ -n "$exact_name" ]; then
            local name="${override_name:-$exact_name}"
            local canonical_id out_file
            canonical_id=$(_resolve_canonical_id "flatpak" "$query")
            out_file=$(module_file "$canonical_id")
            _check_or_switch_existing "$canonical_id" "flatpak" "$name" "$out_file" || return
            _confirm_install "$query" "Flathub" "$query" || return
            write_flatpak_module "$query" "$name" "$out_file"
            log "install: Flatpak '${name}' (${query}) [direct]"
            echo "Installed Flatpak: ${name} (${query})"
            trigger_switch "mirror-os: install ${name} (${query}) [Flatpak]"
            return
        fi
        # Fallback: FTS search
        local flat_raw
        flat_raw=$(flatpak_search "$query")
        [ -z "$flat_raw" ] && die "No Flatpak found for: $query"
        local selection
        echo "Flatpak results for '$query':"
        if $pick; then
            selection=$(pick_result "$flat_raw" "") || { echo "Cancelled."; exit 0; }
        else
            local auto_out
            auto_out=$(auto_select_best "$flat_raw" "" "$query") || die "Could not determine best match for: $query"
            selection=$(head -1 <<< "$auto_out")
            local meta_json
            meta_json=$(tail -1 <<< "$auto_out")
            _print_auto_selection "$selection" "$meta_json"
        fi
        local src id name
        IFS=: read -r src id name <<< "$selection"
        [ -n "$override_name" ] && name="$override_name"
        local canonical_id out_file
        canonical_id=$(_resolve_canonical_id "flatpak" "$id")
        out_file=$(module_file "$canonical_id")
        _check_or_switch_existing "$canonical_id" "flatpak" "$name" "$out_file" || return
        _confirm_install "$id" "Flathub" "$query" || return
        write_flatpak_module "$id" "$name" "$out_file"
        log "install: Flatpak '${name}' (${id})"
        echo "Installed Flatpak: ${name} (${id})"
        trigger_switch "mirror-os: install ${name} (${id}) [Flatpak]"
        return
    fi

    # Force-nix: exact attr lookup first, then FTS search
    if $force_nix; then
        # Try treating query as an exact Nix attr
        local exact_name
        exact_name=$(_lookup_name "$query" "nix")
        if [ -n "$exact_name" ]; then
            local name="${override_name:-$exact_name}"
            local canonical_id out_file
            canonical_id=$(_resolve_canonical_id "nix" "$query")
            out_file=$(module_file "$canonical_id")
            _check_or_switch_existing "$canonical_id" "nix" "$name" "$out_file" || return
            _confirm_install "$query" "Nix" "$query" || return
            _write_nix_module_smart "$query" "$name" "$out_file"
            log "install: Nix '${name}' (nixpkgs.${query}) [direct]"
            echo "Installed Nix package: ${name} (${query})"
            trigger_switch "mirror-os: install ${name} (nixpkgs.${query}) [Nix]"
            return
        fi
        # Fallback: FTS search
        local nix_raw
        nix_raw=$(nix_search "$query")
        [ -z "$nix_raw" ] && die "No Nix package found for: $query"
        local selection
        echo "Nix results for '$query':"
        if $pick; then
            selection=$(pick_result "" "$nix_raw") || { echo "Cancelled."; exit 0; }
        else
            local auto_out
            auto_out=$(auto_select_best "" "$nix_raw" "$query") || die "Could not determine best match for: $query"
            selection=$(head -1 <<< "$auto_out")
            local meta_json
            meta_json=$(tail -1 <<< "$auto_out")
            _print_auto_selection "$selection" "$meta_json"
        fi
        local src id name
        IFS=: read -r src id name <<< "$selection"
        [ -n "$override_name" ] && name="$override_name"
        local canonical_id out_file
        canonical_id=$(_resolve_canonical_id "nix" "$id")
        out_file=$(module_file "$canonical_id")
        _check_or_switch_existing "$canonical_id" "nix" "$name" "$out_file" || return
        _confirm_install "$id" "Nix" "$query" || return
        _write_nix_module_smart "$id" "$name" "$out_file"
        log "install: Nix '${name}' (nixpkgs.${id})"
        echo "Installed Nix package: ${name} (${id})"
        trigger_switch "mirror-os: install ${name} (nixpkgs.${id}) [Nix]"
        return
    fi

    # Smart detection: search both sources
    echo "Searching for '$query'..."
    local flat_raw nix_raw
    flat_raw=$(flatpak_search "$query")
    nix_raw=$(nix_search "$query")

    [ -z "$flat_raw" ] && [ -z "$nix_raw" ] && die "No results found for: $query"

    local selection
    if $pick; then
        echo "Results for '$query':"
        selection=$(pick_result "$flat_raw" "$nix_raw") || { echo "Cancelled."; exit 0; }
    else
        local auto_out
        auto_out=$(auto_select_best "$flat_raw" "$nix_raw" "$query") || die "Could not determine best match for: $query"
        selection=$(head -1 <<< "$auto_out")
        local meta_json
        meta_json=$(tail -1 <<< "$auto_out")
        _print_auto_selection "$selection" "$meta_json"
    fi

    local src id name
    IFS=: read -r src id name <<< "$selection"
    local canonical_id out_file
    canonical_id=$(_resolve_canonical_id "$src" "$id")
    out_file=$(module_file "$canonical_id")

    local src_display="Nix"
    [ "$src" = "flatpak" ] && src_display="Flathub"

    _check_or_switch_existing "$canonical_id" "$src" "$name" "$out_file" || return
    _confirm_install "$id" "$src_display" "$query" || return

    if [ "$src" = "flatpak" ]; then
        write_flatpak_module "$id" "$name" "$out_file"
        log "install: Flatpak '${name}' (${id})"
        echo "Installed Flatpak: ${name} (${id})"
        trigger_switch "mirror-os: install ${name} (${id}) [Flatpak]"
    else
        _write_nix_module_smart "$id" "$name" "$out_file"
        log "install: Nix '${name}' (nixpkgs.${id})"
        echo "Installed Nix package: ${name} (${id})"
        trigger_switch "mirror-os: install ${name} (nixpkgs.${id}) [Nix]"
    fi
}

# Print auto-selection summary line: "Auto-selected: Name (id) [Source, vX.Y, date]"
_print_auto_selection() {
    local selection="$1" meta_json="$2"
    local src id name ver date src_label

    IFS=: read -r src id name <<< "$selection"
    ver=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('version',''))" "$meta_json" 2>/dev/null || true)
    date=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('release_date',''))" "$meta_json" 2>/dev/null || true)

    [ "$src" = "flatpak" ] && src_label="Flatpak" || src_label="Nix"

    local meta_parts="$src_label"
    [ -n "$ver" ]  && meta_parts="${meta_parts}, v${ver}"
    [ -n "$date" ] && meta_parts="${meta_parts}, ${date}"

    echo "Auto-selected: ${name} (${id}) [${meta_parts}]"
}

cmd_uninstall() {
    need_init
    local yes=false
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --yes|-y) yes=true ;;
            *) args+=("$arg") ;;
        esac
    done
    set -- "${args[@]+"${args[@]}"}"

    local query="${1:-}"
    [ -z "$query" ] && die "Usage: mirror-os uninstall <query>"
    # Strip nixpkgs. prefix (e.g. from nix search output)
    [[ "$query" == nixpkgs.* ]] && query="${query#nixpkgs.}"

    local out_file
    out_file=$(module_file "$query")

    if [ ! -f "$out_file" ]; then
        # Search by case-insensitive filename substring and by app title in module comment
        local file_matches title_matches all_matches
        file_matches=$(find "$APPS_DIR" -maxdepth 1 -iname "*${query}*" -name "*.nix" 2>/dev/null)
        title_matches=$(grep -ril "^# .*${query}.*— installed via mirror-os" "$APPS_DIR" 2>/dev/null || true)
        all_matches=$(printf '%s\n%s\n' "$file_matches" "$title_matches" \
            | grep '\.nix$' | sort -u)

        # Fallback: resolve source ID → slug via catalog.db app_map
        # (e.g. uninstall com.spotify.Client → finds spotify.nix)
        if [ -z "$all_matches" ] && [ -f "$CATALOG_DB" ]; then
            local slug_from_catalog
            slug_from_catalog=$(python3 -c "
import sqlite3, sys, os
try:
    c=sqlite3.connect(sys.argv[1],timeout=3)
    c.execute('PRAGMA query_only = ON')
    q=sys.argv[2]
    r=c.execute('SELECT slug FROM app_map WHERE flatpak_id=? OR nix_attr=?',(q,q)).fetchone()
    print(r[0] if r else '')
except: print('')
" "$CATALOG_DB" "$query" 2>/dev/null || true)
            if [ -n "$slug_from_catalog" ]; then
                local slug_file; slug_file=$(module_file "$slug_from_catalog")
                [ -f "$slug_file" ] && all_matches="$slug_file"
            fi
        fi

        if [ -z "$all_matches" ]; then
            # No module file — check for an orphaned user-scope Flatpak installation
            # (e.g. app still in launcher after an interrupted uninstall).
            local orphan_id=""
            # Exact app ID match
            if flatpak info --user "$query" &>/dev/null 2>&1; then
                orphan_id="$query"
            fi
            # Name/ID substring match in user flatpak list
            if [ -z "$orphan_id" ]; then
                orphan_id=$(flatpak list --user --columns=application,name 2>/dev/null \
                    | grep -i "$query" | cut -f1 | head -1)
            fi
            if [ -n "$orphan_id" ]; then
                if ! $yes; then
                    printf "No mirror-os module found, but '%s' is installed as a user Flatpak.\nRemove it? [y/N] " "$orphan_id"
                    read -r confirm
                    [[ "$confirm" == [yY] ]] || { echo "Cancelled."; exit 0; }
                fi
                flatpak --user uninstall --noninteractive "$orphan_id" >> "$LOG_FILE" 2>&1 && \
                    log "uninstall: orphaned Flatpak '${orphan_id}'" || \
                    echo "Warning: flatpak uninstall failed — try: flatpak --user uninstall ${orphan_id}"
                return
            fi
            die "No installed app matching '${query}'. Use 'mirror-os list' to see managed apps."
        fi
        local count
        count=$(echo "$all_matches" | wc -l)
        if [ "$count" -gt 1 ]; then
            echo "Multiple matches for '${query}':"
            echo "$all_matches" | while read -r f; do echo "  $(basename "$f" .nix)"; done
            die "Please be more specific."
        fi
        out_file="$all_matches"
    fi

    local id
    id=$(basename "$out_file" .nix)

    if ! $yes; then
        printf "Remove '%s'? [y/N] " "$id"
        read -r confirm
        [[ "$confirm" == [yY] ]] || { echo "Cancelled."; exit 0; }
    fi

    # Also remove pro flake input from flake.nix if present
    local input_name="mirror-${id}"
    if grep -q "${input_name}.url" "$FLAKE_NIX" 2>/dev/null; then
        sed -i "/${input_name}.url/d" "$FLAKE_NIX"
        echo "Removed flake input: ${input_name}"
    fi

    # Detect type and app ID before deleting the module file.
    local is_flatpak=false flatpak_app_id=""
    if grep -q "services\.flatpak" "$out_file" 2>/dev/null; then
        is_flatpak=true
        flatpak_app_id=$(grep 'appId\s*=' "$out_file" \
            | sed 's/.*appId\s*=\s*"\([^"]*\)".*/\1/' | head -1)
    fi

    rm "$out_file"
    # Remove options sidecar if present
    local sidecar_file="${APPS_DIR}/${id}.options.json"
    [ -f "$sidecar_file" ] && rm "$sidecar_file"
    log "uninstall: '${id}'"
    echo "Uninstalled: ${id}"
    trigger_switch "mirror-os: uninstall ${id}"

    # Post-switch cleanup: ensure the app is actually gone.
    if $is_flatpak && [ -n "$flatpak_app_id" ]; then
        # nix-flatpak's activation runs a background service; call flatpak directly
        # so the app disappears from the launcher before this command returns.
        echo "Removing Flatpak installation..."
        flatpak --user uninstall --noninteractive "$flatpak_app_id" 2>/dev/null || true
    else
        # Expire old Home Manager generations and collect freed Nix store paths.
        echo "Running Nix garbage collection (this may take a moment)..."
        nix-collect-garbage -d >> "$LOG_FILE" 2>&1 || true
    fi
}
