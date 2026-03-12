# mirror-os lib/cmd-info.bash — list and info commands
# Sourced by mirror-os; do not execute directly.

cmd_list() {
    need_init
    mkdir -p "$APPS_DIR"
    local json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            *) die "Usage: mirror-os list [--json]" ;;
        esac
    done

    if $json; then
        python3 - "$APPS_DIR" "$CATALOG_DB" << 'PYEOF'
import json, sys, os, re, sqlite3

apps_dir   = sys.argv[1]
catalog_db = sys.argv[2]

cat_conn = None
if os.path.exists(catalog_db):
    try:
        cat_conn = sqlite3.connect(catalog_db, timeout=5)
        cat_conn.execute("PRAGMA query_only = ON")
    except Exception:
        cat_conn = None

def get_catalog_info(source, source_id):
    if not cat_conn or not source_id:
        return '', ''
    try:
        if source == 'flatpak':
            r = cat_conn.execute(
                "SELECT name, version FROM flatpak_apps WHERE app_id=?", (source_id,)
            ).fetchone()
        elif source == 'nix':
            r = cat_conn.execute(
                "SELECT pname, version FROM nix_packages WHERE attr=?", (source_id,)
            ).fetchone()
        else:
            return '', ''
        return (r[0] or '', r[1] or '') if r else ('', '')
    except Exception:
        return '', ''

result = []
if os.path.isdir(apps_dir):
    for fname in sorted(os.listdir(apps_dir)):
        if not fname.endswith('.nix'):
            continue
        path = os.path.join(apps_dir, fname)
        app_id = fname[:-4]
        try:
            content = open(path).read()
        except Exception:
            content = ""
        source = "unknown"
        source_id = app_id
        if "services.flatpak" in content:
            m = re.search(r'origin\s*=\s*"([^"]+)"', content)
            source = m.group(1) if m else "flatpak"
            m2 = re.search(r'appId\s*=\s*"([^"]+)"', content)
            if m2: source_id = m2.group(1)
        elif "home.packages" in content:
            source = "nix"
            m = re.search(r'pkgs\.(\S+)\s*[\];}]', content)
            if m: source_id = m.group(1)
        elif "homeManagerModules" in content:
            source = "pro_flake"

        cat_name, version = get_catalog_info(source, source_id)
        display_name = cat_name or app_id

        result.append({
            "id":           app_id,
            "slug":         app_id,
            "source":       source,
            "source_id":    source_id,
            "display_name": display_name,
            "version":      version,
            "module_path":  path,
        })

if cat_conn:
    cat_conn.close()
print(json.dumps(result, indent=2))
PYEOF
        return
    fi

    local files
    files=$(find "$APPS_DIR" -maxdepth 1 -name "*.nix" 2>/dev/null | sort)

    if [ -z "$files" ]; then
        echo "No apps installed via mirror-os."
        echo "Use 'mirror-os install <app>' to install apps."
        return
    fi

    echo "Apps managed by mirror-os:"
    echo ""
    printf "  %-38s  %-10s\n" "ID" "Source"
    printf "  %-38s  %-10s\n" "--------------------------------------" "----------"
    while IFS= read -r f; do
        local id
        id=$(basename "$f" .nix)
        local src="unknown"
        if grep -q "services\.flatpak" "$f" 2>/dev/null; then
            local _origin
            _origin=$(grep -o 'origin\s*=\s*"[^"]*"' "$f" 2>/dev/null \
                      | sed 's/.*"\([^"]*\)".*/\1/' | head -1)
            src="${_origin^}"
            [ -z "$src" ] && src="Flatpak"
        elif grep -q "home\.packages" "$f" 2>/dev/null; then
            src="Nix"
        elif grep -q "homeManagerModules" "$f" 2>/dev/null; then
            src="Pro flake"
        fi
        printf "  %-38s  %-10s\n" "$id" "$src"
    done <<< "$files"
}

cmd_info() {
    need_init
    local id="${1:-}" json=false
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            *) die "Usage: mirror-os info <app-id> [--json]" ;;
        esac
    done
    [ -z "$id" ] && die "Usage: mirror-os info <app-id> [--json]"
    # Strip nixpkgs. prefix (e.g. from nix search output)
    [[ "$id" == nixpkgs.* ]] && id="${id#nixpkgs.}"

    local out_file
    out_file=$(module_file "$id")

    if [ ! -f "$out_file" ]; then
        local matches
        matches=$(find "$APPS_DIR" -name "*${id}*" -name "*.nix" 2>/dev/null | sort)

        # Fallback: resolve source ID → slug via catalog.db app_map
        # (e.g. info com.spotify.Client → finds spotify.nix)
        if [ -z "$matches" ] && [ -f "$CATALOG_DB" ]; then
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
" "$CATALOG_DB" "$id" 2>/dev/null || true)
            if [ -n "$slug_from_catalog" ]; then
                local slug_file; slug_file=$(module_file "$slug_from_catalog")
                [ -f "$slug_file" ] && matches="$slug_file"
            fi
        fi

        [ -z "$matches" ] && die "App '${id}' not found. Use 'mirror-os list' to see installed apps."
        local count; count=$(echo "$matches" | wc -l)
        if [ "$count" -gt 1 ]; then
            echo "Multiple matches:"; echo "$matches" | while read -r f; do echo "  $(basename "$f" .nix)"; done
            die "Please specify the exact app ID."
        fi
        out_file="$matches"
        id=$(basename "$out_file" .nix)
    fi

    local src="unknown"
    if grep -q "services\.flatpak" "$out_file" 2>/dev/null; then
        local _origin
        _origin=$(grep -o 'origin\s*=\s*"[^"]*"' "$out_file" 2>/dev/null \
                  | sed 's/.*"\([^"]*\)".*/\1/' | head -1)
        src="${_origin^}"
        [ -z "$src" ] && src="Flatpak"
    elif grep -q "home\.packages" "$out_file" 2>/dev/null; then
        src="Nix"
    elif grep -q "homeManagerModules" "$out_file" 2>/dev/null; then
        src="Pro flake"
    fi

    if $json; then
        python3 - "$CATALOG_DB" "$id" "$src" "$out_file" << 'PYEOF'
import sys, json, sqlite3, os

db_path  = sys.argv[1]
app_id   = sys.argv[2]
src      = sys.argv[3]
mod_path = sys.argv[4]

try:
    module_content = open(mod_path).read()
except Exception:
    module_content = ''

result = {
    'id':             app_id,
    'slug':           app_id,
    'source':         src.lower().replace(' ', '_'),
    'module_path':    mod_path,
    'module_content': module_content,
}

if os.path.exists(db_path):
    try:
        conn = sqlite3.connect(db_path, timeout=5)
        conn.execute("PRAGMA query_only = ON")
        conn.row_factory = sqlite3.Row

        if src not in ('Nix', 'Pro flake', 'unknown'):
            row = conn.execute(
                """SELECT name, summary, description, version, release_date, developer,
                          license, homepage, bugtracker_url, donation_url,
                          categories, keywords, icon_name, screenshots,
                          content_rating, flatpak_ref, releases_json,
                          verified, monthly_downloads
                   FROM flatpak_apps WHERE app_id = ?""",
                (app_id,)
            ).fetchone()
            if row:
                result.update({
                    'name':              row['name'],
                    'summary':           row['summary'],
                    'full_description':  row['description'],
                    'version':           row['version'],
                    'release_date':      row['release_date'],
                    'developer':         row['developer'],
                    'license':           row['license'],
                    'homepage':          row['homepage'],
                    'bugtracker_url':    row['bugtracker_url'],
                    'donation_url':      row['donation_url'],
                    'categories':        json.loads(row['categories'] or '[]'),
                    'keywords':          json.loads(row['keywords']   or '[]'),
                    'icon_name':         row['icon_name'],
                    'screenshots':       json.loads(row['screenshots'] or '[]'),
                    'content_rating':    row['content_rating'],
                    'flatpak_ref':       row['flatpak_ref'],
                    'releases':          json.loads(row['releases_json'] or '[]'),
                    'verified':          bool(row['verified']),
                    'monthly_downloads': row['monthly_downloads'],
                })
        elif src == 'Nix':
            row = conn.execute(
                """SELECT pname, version, description, long_description,
                          homepage, license, maintainers
                   FROM nix_packages WHERE attr = ?""",
                (app_id,)
            ).fetchone()
            if row:
                result.update({
                    'name':             row['pname'],
                    'description':      row['description'],
                    'long_description': row['long_description'],
                    'version':          row['version'],
                    'homepage':         row['homepage'],
                    'license':          row['license'],
                    'maintainers':      json.loads(row['maintainers'] or '[]'),
                })
        conn.close()
    except Exception:
        pass

print(json.dumps(result, indent=2))
PYEOF
        return
    fi

    echo "App:     $id"
    echo "Source:  $src"
    echo "Module:  $out_file"
    echo ""
    echo "--- Module ---"
    cat "$out_file"

    if [ "$src" != "Nix" ] && [ "$src" != "Pro flake" ] && [ "$src" != "unknown" ]; then
        echo ""
        echo "--- Flatpak info ---"
        flatpak info --user "$id" 2>/dev/null || flatpak info "$id" 2>/dev/null || \
            echo "(not yet installed — pending next sync)"
        echo ""
        echo "--- User overrides ---"
        flatpak override --user --show "$id" 2>/dev/null || echo "(none)"
    fi
}
