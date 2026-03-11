# mirror-os lib/cmd-info.bash — list, info, rename, instances commands
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

    # Auto-migrate existing installs into instances.db if needed
    migrate_existing_installs

    if $json; then
        python3 - "$APPS_DIR" "$CATALOG_DB" "$INSTANCES_DB" << 'PYEOF'
import json, sys, os, re, sqlite3

apps_dir     = sys.argv[1]
catalog_db   = sys.argv[2]
instances_db = sys.argv[3]

# Load instances DB for labels/slugs
inst_map = {}  # instance_id -> row
if os.path.exists(instances_db):
    try:
        inst_conn = sqlite3.connect(instances_db, timeout=5)
        inst_conn.execute("PRAGMA query_only = ON")
        for row in inst_conn.execute(
            "SELECT instance_id, slug, source, source_id, display_label FROM app_instances"
        ):
            inst_map[row[0]] = {'slug': row[1], 'source': row[2],
                                'source_id': row[3], 'display_label': row[4]}
        inst_conn.close()
    except Exception:
        pass

# Load catalog for version + name
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

        inst = inst_map.get(app_id, {})
        slug         = inst.get('slug')
        display_label = inst.get('display_label')
        cat_name, version = get_catalog_info(source, source_id)
        display_name = display_label or cat_name or app_id

        result.append({
            "id":           app_id,
            "instance_id":  app_id,
            "slug":         slug,
            "source":       source,
            "source_id":    source_id,
            "display_name": display_name,
            "display_label": display_label,
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
    printf "  %-38s  %-10s  %s\n" "ID" "Source" "Name / Label"
    printf "  %-38s  %-10s  %s\n" "--------------------------------------" "----------" "------------"
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
        # Look up display label from instances DB
        local label=""
        if [ -f "$INSTANCES_DB" ]; then
            label=$(python3 -c "
import sqlite3, sys
try:
    c=sqlite3.connect(sys.argv[1],timeout=3)
    r=c.execute('SELECT display_label FROM app_instances WHERE instance_id=?',(sys.argv[2],)).fetchone()
    print(r[0] if r and r[0] else '')
except: print('')
" "$INSTANCES_DB" "$id" 2>/dev/null || true)
        fi
        local display="${label:-$id}"
        printf "  %-38s  %-10s  %s\n" "$id" "$src" "$display"
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
        python3 - "$CATALOG_DB" "$id" "$src" "$out_file" "$INSTANCES_DB" << 'PYEOF'
import sys, json, sqlite3, os

db_path      = sys.argv[1]
app_id       = sys.argv[2]
src          = sys.argv[3]
mod_path     = sys.argv[4]
instances_db = sys.argv[5]

try:
    module_content = open(mod_path).read()
except Exception:
    module_content = ''

result = {
    'id':             app_id,
    'source':         src.lower().replace(' ', '_'),
    'module_path':    mod_path,
    'module_content': module_content,
    'display_label':  None,
    'slug':           None,
}

# Enrich with instances DB
if os.path.exists(instances_db):
    try:
        ic = sqlite3.connect(instances_db, timeout=3)
        ic.execute("PRAGMA query_only = ON")
        ir = ic.execute(
            "SELECT slug, display_label FROM app_instances WHERE instance_id=?", (app_id,)
        ).fetchone()
        if ir:
            result['slug']          = ir[0]
            result['display_label'] = ir[1]
        ic.close()
    except Exception:
        pass

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
    # Show label if set
    if [ -f "$INSTANCES_DB" ]; then
        local _label
        _label=$(python3 -c "
import sqlite3, sys
try:
    c=sqlite3.connect(sys.argv[1],timeout=3)
    r=c.execute('SELECT display_label FROM app_instances WHERE instance_id=?',(sys.argv[2],)).fetchone()
    print(r[0] if r and r[0] else '')
except: print('')
" "$INSTANCES_DB" "$id" 2>/dev/null || true)
        [ -n "$_label" ] && echo "Label:   $_label"
    fi
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

cmd_rename() {
    need_init
    local instance_id="${1:-}" new_label="${2:-}"
    [ -z "$instance_id" ] || [ -z "$new_label" ] && \
        die "Usage: mirror-os rename <id> <new-label>"

    local out_file
    out_file=$(module_file "$instance_id")
    [ -f "$out_file" ] || die "App '${instance_id}' not found. Use 'mirror-os list' to see installed apps."

    ensure_instances_schema
    python3 - "$INSTANCES_DB" "$instance_id" "$new_label" << 'PYEOF'
import sys, sqlite3, os
from datetime import datetime, timezone

instances_db = sys.argv[1]
instance_id  = sys.argv[2]
new_label    = sys.argv[3]

conn = sqlite3.connect(instances_db, timeout=10)
now  = datetime.now(tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
cur  = conn.execute(
    "UPDATE app_instances SET display_label=?, updated_at=? WHERE instance_id=?",
    (new_label, now, instance_id)
)
conn.commit()
conn.close()

if cur.rowcount == 0:
    # App not yet in instances DB — insert a minimal record
    conn2 = sqlite3.connect(instances_db, timeout=10)
    with conn2:
        conn2.execute("""
            INSERT OR IGNORE INTO app_instances
                (instance_id, source, source_id, display_label, module_file)
            VALUES (?,?,?,?,?)
        """, (instance_id, 'unknown', instance_id, new_label,
              os.path.expanduser(f"~/.config/home-manager/apps/{instance_id}.nix")))
    conn2.close()

print(f"Renamed: {instance_id} \u2192 {new_label}")
PYEOF
}

cmd_instances() {
    need_init
    local slug_query="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            *)
                if [ -n "$slug_query" ]; then
                    die "Unexpected argument '${1}'."
                fi
                slug_query="$1"; shift ;;
        esac
    done
    [ -z "$slug_query" ] && die "Usage: mirror-os instances <slug> [--json]"

    ensure_instances_schema
    python3 - "$INSTANCES_DB" "$CATALOG_DB" "$slug_query" "$json" << 'PYEOF'
import sys, sqlite3, os, json as _json

instances_db = sys.argv[1]
catalog_db   = sys.argv[2]
slug_query   = sys.argv[3]
as_json      = sys.argv[4] == 'true'

inst = sqlite3.connect(instances_db, timeout=5)
inst.execute("PRAGMA query_only = ON")
inst.row_factory = sqlite3.Row

rows = inst.execute("""
    SELECT instance_id, slug, source, source_id, display_label, module_file,
           installed_at, updated_at
    FROM app_instances
    WHERE slug = ? OR instance_id LIKE ?
    ORDER BY installed_at
""", (slug_query, f'%{slug_query}%')).fetchall()

inst.close()

if not rows:
    print(f"No instances found for '{slug_query}'.")
    sys.exit(0)

# Enrich with version from catalog
versions = {}
if os.path.exists(catalog_db):
    try:
        cat = sqlite3.connect(catalog_db, timeout=5)
        cat.execute("PRAGMA query_only = ON")
        for r in rows:
            if r['source'] == 'flatpak':
                v = cat.execute("SELECT version FROM flatpak_apps WHERE app_id=?",
                                (r['source_id'],)).fetchone()
            elif r['source'] == 'nix':
                v = cat.execute("SELECT version FROM nix_packages WHERE attr=?",
                                (r['source_id'],)).fetchone()
            else:
                v = None
            versions[r['instance_id']] = v[0] if v else ''
        cat.close()
    except Exception:
        pass

result = []
for r in rows:
    result.append({
        'instance_id':   r['instance_id'],
        'slug':          r['slug'],
        'source':        r['source'],
        'source_id':     r['source_id'],
        'display_label': r['display_label'],
        'module_file':   r['module_file'],
        'version':       versions.get(r['instance_id'], ''),
        'installed_at':  r['installed_at'],
    })

if as_json:
    print(_json.dumps(result, indent=2))
else:
    print(f"Instances for '{slug_query}':\n")
    for r in result:
        label  = r['display_label'] or r['instance_id']
        src    = r['source'].capitalize()
        ver    = f"  v{r['version']}" if r['version'] else ''
        print(f"  {r['instance_id']:<40}  {src:<10}  {label}{ver}")
PYEOF
}
