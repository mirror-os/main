# mirror-os lib/cmd-hm.bash — Home Manager and state snapshot commands
# Sourced by mirror-os; do not execute directly.

STATE_DIR="$HOME/.local/share/mirror-os/state"

cmd_update() {
    need_init
    log "update: running nix flake update"
    echo "Updating flake inputs..."
    (cd "$HM_CONFIG_DIR" && nix flake update) || die "nix flake update failed"
    log "update: flake update complete"
    trigger_switch "mirror-os: flake update"
}

cmd_catalog() {
    local action="${1:-}"
    case "$action" in
        update)
            echo "Updating app catalog..."
            /usr/libexec/mirror-os/mirror-catalog-update "${@:2}" || \
                die "catalog update failed"
            ;;
        status)
            [ -f "$CATALOG_DB" ] || { echo "Catalog not built yet. Run: mirror-os catalog update"; return; }
            python3 - "$CATALOG_DB" << 'PYEOF'
import sys, sqlite3
db_path = sys.argv[1]
conn = sqlite3.connect(db_path, timeout=5)
conn.execute("PRAGMA query_only = ON")
rows = conn.execute("SELECT source, row_count, updated_at FROM catalog_meta").fetchall()
conn.close()
if not rows:
    print("Catalog exists but has no metadata yet.")
else:
    for source, count, ts in rows:
        print(f"  {source:<8}  {count:>6} entries   last updated: {ts}")
PYEOF
            ;;
        *)
            die "Usage: mirror-os catalog update [--source flatpak|nix|nix-meta|hm-options|all] | mirror-os catalog status"
            ;;
    esac
}

# ── Resolve a snapshot reference to a full git SHA ──────────────────────────
resolve_snapshot_sha() {
    local ref="$1" type="${2:-cosmic}"
    local path_filter
    case "$type" in
        cosmic) path_filter="cosmic-config/" ;;
        apps)   path_filter="home-manager/apps/" ;;
        *)      path_filter="" ;;
    esac

    if [[ "$ref" =~ ^[0-9]+$ ]]; then
        local sha
        sha=$(git -C "$STATE_DIR" log --format="%H" -- $path_filter \
            | sed -n "${ref}p")
        [ -z "$sha" ] && die "Snapshot index $ref not found."
        echo "$sha"
    else
        local sha
        sha=$(git -C "$STATE_DIR" rev-parse --verify "${ref}^{commit}" 2>/dev/null) || \
            die "Snapshot '${ref}' not found in state history."
        echo "$sha"
    fi
}

cmd_snapshots() {
    need_init
    local type="cosmic" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) type="$2"; shift 2 ;;
            --json) json=true; shift ;;
            *) die "Usage: mirror-os snapshots [--type cosmic|apps|all] [--json]" ;;
        esac
    done

    [ -d "$STATE_DIR/.git" ] || die "State git repo not found at $STATE_DIR."

    local path_filter
    case "$type" in
        cosmic) path_filter="cosmic-config/" ;;
        apps)   path_filter="home-manager/apps/" ;;
        all)    path_filter="" ;;
        *)      die "Unknown type '$type'. Use: cosmic, apps, all" ;;
    esac

    local index=0
    local entries=""
    while IFS='|' read -r date sha msg; do
        (( index++ ))
        local changed=""
        if [ "$type" = "cosmic" ] || [ "$type" = "all" ]; then
            changed=$(git -C "$STATE_DIR" show "${sha}:cosmic-changes.log" 2>/dev/null \
                | tr '\n' ' ' || true)
        fi
        entries="${entries}${index}|${date:0:19}|${sha}|${msg}|${changed}\n"
    done < <(git -C "$STATE_DIR" log --format="%ai|%H|%s" -- $path_filter 2>/dev/null)

    [ -z "$entries" ] && { $json && echo "[]" || echo "No snapshots found for type: $type"; return; }

    if $json; then
        printf "%b" "$entries" | python3 << 'PYEOF'
import json, sys
result = []
for line in sys.stdin:
    parts = line.rstrip('\n').split('|', 4)
    if len(parts) < 4:
        continue
    idx, date, sha, msg = parts[0], parts[1], parts[2], parts[3]
    changed_raw = parts[4] if len(parts) > 4 else ""
    changed = [c for c in changed_raw.strip().split() if c]
    result.append({"index": int(idx), "sha": sha, "short_sha": sha[:7],
                   "date": date, "message": msg, "changed": changed})
print(json.dumps(result, indent=2))
PYEOF
        return
    fi

    printf "%b" "$entries" | while IFS='|' read -r idx date sha msg changed; do
        printf "[%2s]  %s  %s  %s\n" "$idx" "$date" "${sha:0:7}" "$msg"
        [ -n "$changed" ] && printf "       Changed: %.80s\n" "$changed"
        echo ""
    done
}

cmd_rollback() {
    need_init
    local type="${1:-}" ref="${2:-}"
    [ -z "$type" ] || [ -z "$ref" ] && \
        die "Usage: mirror-os rollback cosmic <sha|index>"

    case "$type" in
        cosmic)
            local sha
            sha=$(resolve_snapshot_sha "$ref" "cosmic")

            echo "Rolling back COSMIC config to snapshot ${sha:0:7}..."
            printf "Changed files in that snapshot:\n"
            git -C "$STATE_DIR" show "${sha}:cosmic-changes.log" 2>/dev/null \
                | sed 's/^/  /' || echo "  (no change log available)"
            echo ""
            printf "Apply this rollback? [y/N] "
            read -r confirm
            [[ "$confirm" == [yY] ]] || { echo "Cancelled."; exit 0; }

            local tmpdir
            tmpdir=$(mktemp -d)
            git -C "$STATE_DIR" archive "$sha" cosmic-config/ | tar -xC "$tmpdir" 2>/dev/null || \
                die "Failed to extract snapshot $sha from state git."

            rsync -a --delete "$tmpdir/cosmic-config/" "$HOME/.config/cosmic/" || \
                die "Failed to restore COSMIC config files."
            rm -rf "$tmpdir"

            log "rollback: COSMIC config restored to snapshot ${sha:0:7}"
            echo "COSMIC config restored to snapshot ${sha:0:7}."
            echo "Reopen COSMIC Settings or log out/in to see all changes."
            ;;
        *)
            die "Unknown rollback type '$type'. Currently supported: cosmic"
            ;;
    esac
}

cmd_add_option() {
    need_init
    local app_id="${1:-}" key="${2:-}" value="${3:-}"
    [ -z "$app_id" ] || [ -z "$key" ] || [ -z "$value" ] && \
        die "Usage: mirror-os --app <id> --add-option <key> <value>"

    local out_file
    out_file=$(module_file "$app_id")
    [ -f "$out_file" ] || die "App '${app_id}' not found. Use 'mirror-os list' to see installed apps."

    local option_line="  ${key} = ${value};"
    if grep -qF "$option_line" "$out_file"; then
        echo "Option '${key}' already set to '${value}' in ${out_file}."
        return
    fi

    sed -i "$(grep -n '^}' "$out_file" | tail -1 | cut -d: -f1)i\\  ${key} = ${value};" "$out_file"
    log "add-option: '${app_id}' ${key} = ${value}"
    echo "Added option '${key} = ${value}' to ${app_id}."
    trigger_switch "mirror-os: configure ${app_id} (add ${key})"
}

cmd_remove_option() {
    need_init
    local app_id="${1:-}" key="${2:-}"
    [ -z "$app_id" ] || [ -z "$key" ] && \
        die "Usage: mirror-os --app <id> --remove-option <key>"

    local out_file
    out_file=$(module_file "$app_id")
    [ -f "$out_file" ] || die "App '${app_id}' not found. Use 'mirror-os list' to see installed apps."

    if ! grep -qF "  ${key} = " "$out_file"; then
        die "Option '${key}' not found in ${app_id}'s module."
    fi

    sed -i "/^  ${key} = /d" "$out_file"
    log "remove-option: '${app_id}' ${key}"
    echo "Removed option '${key}' from ${app_id}."
    trigger_switch "mirror-os: configure ${app_id} (remove ${key})"
}

# ── mirror-os config — HM option management CLI ───────────────────────────────
#
# Usage:
#   mirror-os config <attr>                        list current options
#   mirror-os config <attr> get <key>             print one value
#   mirror-os config <attr> set <key> <value>     set scalar option
#   mirror-os config <attr> add <key> <item>      append item to list option
#   mirror-os config <attr> remove <key> <item>   remove item from list
#   mirror-os config <attr> unset <key>           remove a key entirely
#
# Reads/writes the sidecar JSON at ~/.config/home-manager/apps/<attr>.options.json
# (the same file used by the Mirror OS Software Center).  After each write,
# regenerates the .nix module and triggers a home-manager switch.
cmd_config() {
    need_init
    local attr="${1:-}"
    local action="${2:-list}"
    [ -z "$attr" ] && die "Usage: mirror-os config <attr> [list|get|set|add|remove|unset] [args…]"

    local module_f sidecar_f
    module_f=$(module_file "$attr")
    sidecar_f="${APPS_DIR}/${attr}.options.json"

    # Require the app to be installed for any write operation
    case "$action" in
        set|add|remove|unset)
            [ -f "$module_f" ] || die "App '${attr}' not found. Use 'mirror-os list' to see installed apps."
            ;;
    esac

    python3 - "$sidecar_f" "$action" "${@:3}" << 'PYEOF'
import sys, json, os

sidecar_f = sys.argv[1]
action    = sys.argv[2]
rest      = sys.argv[3:]

def load():
    if os.path.isfile(sidecar_f):
        with open(sidecar_f) as f:
            try:
                return json.load(f)
            except Exception:
                return {}
    return {}

def save(data):
    os.makedirs(os.path.dirname(sidecar_f), exist_ok=True)
    with open(sidecar_f, 'w') as f:
        json.dump(data, f, indent=2)

def coerce(s):
    """Try to parse as JSON; fall back to raw string."""
    try:
        return json.loads(s)
    except Exception:
        return s

if action == 'list':
    data = load()
    if not data:
        print("(no options configured)")
    else:
        w = max(len(k) for k in data) if data else 0
        for k, v in sorted(data.items()):
            print(f"  {k:<{w}}  =  {json.dumps(v)}")

elif action == 'get':
    if not rest:
        print("Usage: mirror-os config <attr> get <key>", file=sys.stderr); sys.exit(1)
    key = rest[0]
    data = load()
    if key not in data:
        print(f"(not set)", file=sys.stderr); sys.exit(1)
    print(json.dumps(data[key]))

elif action == 'set':
    if len(rest) < 2:
        print("Usage: mirror-os config <attr> set <key> <value>", file=sys.stderr); sys.exit(1)
    key, value = rest[0], coerce(rest[1])
    data = load()
    data[key] = value
    save(data)
    print(f"Set {key} = {json.dumps(value)}")

elif action == 'add':
    if len(rest) < 2:
        print("Usage: mirror-os config <attr> add <key> <item>", file=sys.stderr); sys.exit(1)
    key, item = rest[0], coerce(rest[1])
    data = load()
    lst = data.get(key, [])
    if not isinstance(lst, list):
        print(f"Error: '{key}' is not a list option (current type: {type(lst).__name__})", file=sys.stderr); sys.exit(1)
    if item not in lst:
        lst.append(item)
        data[key] = lst
        save(data)
        print(f"Added {json.dumps(item)} to {key}")
    else:
        print(f"{json.dumps(item)} already in {key}")

elif action == 'remove':
    if len(rest) < 2:
        print("Usage: mirror-os config <attr> remove <key> <item>", file=sys.stderr); sys.exit(1)
    key, item = rest[0], coerce(rest[1])
    data = load()
    lst = data.get(key, [])
    if not isinstance(lst, list):
        print(f"Error: '{key}' is not a list option", file=sys.stderr); sys.exit(1)
    if item in lst:
        lst.remove(item)
        data[key] = lst
        save(data)
        print(f"Removed {json.dumps(item)} from {key}")
    else:
        print(f"{json.dumps(item)} not found in {key}")

elif action == 'unset':
    if not rest:
        print("Usage: mirror-os config <attr> unset <key>", file=sys.stderr); sys.exit(1)
    key = rest[0]
    data = load()
    if key in data:
        del data[key]
        save(data)
        print(f"Unset {key}")
    else:
        print(f"(key '{key}' was not set)")

else:
    print(f"Unknown action '{action}'. Use: list, get, set, add, remove, unset", file=sys.stderr)
    sys.exit(1)
PYEOF
    local rc=$?
    [ $rc -ne 0 ] && return $rc

    # For write actions: regenerate .nix module and switch
    case "$action" in
        set|add|remove|unset)
            regenerate_module_from_sidecar "$attr"
            log "config: '${attr}' $action"
            trigger_switch "mirror-os config: ${attr} ${action} ${3:-}"
            ;;
    esac
}

# Apply options from the sidecar JSON to a programs module, then run HM switch.
# Called by: mirror-os --app <id> --apply-options
cmd_apply_options() {
    need_init
    local app_id="${1:-}"
    [ -z "$app_id" ] && die "Usage: mirror-os --app <id> --apply-options"

    local out_file
    out_file=$(module_file "$app_id")
    [ -f "$out_file" ] || die "App '${app_id}' not found. Use 'mirror-os list' to see installed apps."

    regenerate_module_from_sidecar "$app_id"
    log "apply-options: '${app_id}'"
    echo "Configuration applied for ${app_id}."
    trigger_switch "mirror-os: configure ${app_id}"
}
