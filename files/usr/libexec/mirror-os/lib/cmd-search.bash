# mirror-os lib/cmd-search.bash — search and browse commands
# Sourced by mirror-os; do not execute directly.

cmd_search() {
    local query="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true; shift ;;
            *)
                if [ -n "$query" ]; then
                    die "Unexpected argument '${1}'. If the query has spaces, quote it: mirror-os search \"${query} ${1}\""
                fi
                query="$1"; shift ;;
        esac
    done
    [ -z "$query" ] && die "Usage: mirror-os search <query> [--json]"

    $json || echo "Searching for '$query'..."

    local flat_raw nix_raw
    flat_raw=$(flatpak_search "$query")
    nix_raw=$(nix_search "$query")

    if $json; then
        _search_json "$flat_raw" "$nix_raw"
        return
    fi

    local found=false

    if [ -n "$flat_raw" ]; then
        echo ""
        echo "  Flatpak (flathub):"
        while IFS=$'\t' read -r id name desc; do
            [ -z "$id" ] && continue
            printf "    %-40s  %s\n" "${name} (${id})" "${desc:0:55}"
        done <<< "$flat_raw"
        found=true
    fi

    if [ -n "$nix_raw" ]; then
        echo ""
        echo "  Nix packages (nixpkgs):"
        while IFS=$'\t' read -r id name desc; do
            [ -z "$id" ] && continue
            printf "    %-40s  %s\n" "${name} (nixpkgs.${id})" "${desc:0:55}"
        done <<< "$nix_raw"
        found=true
    fi

    if ! $found; then
        echo "No results found for: $query"
        return
    fi

    echo ""
    printf "Enter an app ID to install, or press Enter to exit: "
    local pick
    read -r pick
    [ -z "$pick" ] && return
    cmd_install "$pick"
}

# Build rich JSON output for search/browse commands
_search_json() {
    local flat_raw="$1"
    local nix_raw="$2"

    python3 - "$CATALOG_DB" "$flat_raw" "$nix_raw" << 'PYEOF'
import json, sys, os, sqlite3

db_path  = sys.argv[1]
flat_raw = sys.argv[2].strip()
nix_raw  = sys.argv[3].strip()

flat_lines = flat_raw.split('\n') if flat_raw else []
nix_lines  = nix_raw.split('\n')  if nix_raw  else []

def parse_tsv(lines):
    result = []
    for line in lines:
        parts = line.split('\t')
        if len(parts) >= 2 and parts[0]:
            result.append({'id': parts[0], 'name': parts[1],
                           'description': parts[2] if len(parts) > 2 else ''})
    return result

flat_items = parse_tsv(flat_lines)
nix_items  = parse_tsv(nix_lines)

# Enrich from DB if available
if os.path.exists(db_path):
    try:
        conn = sqlite3.connect(db_path, timeout=5)
        conn.execute("PRAGMA query_only = ON")
        conn.row_factory = sqlite3.Row

        for item in flat_items:
            row = conn.execute(
                """SELECT name, summary, description, version, release_date, developer,
                          license, homepage, bugtracker_url, donation_url,
                          categories, keywords, icon_name, screenshots,
                          content_rating, flatpak_ref, releases_json,
                          verified, monthly_downloads
                   FROM flatpak_apps WHERE app_id = ?""",
                (item['id'],)
            ).fetchone()
            if row:
                item['name']             = row['name']
                item['description']      = row['summary'] or row['description']
                item['summary']          = row['summary']
                item['full_description'] = row['description']
                item['version']          = row['version']
                item['release_date']     = row['release_date']
                item['developer']        = row['developer']
                item['license']          = row['license']
                item['homepage']         = row['homepage']
                item['bugtracker_url']   = row['bugtracker_url']
                item['donation_url']     = row['donation_url']
                item['categories']       = json.loads(row['categories'] or '[]')
                item['keywords']         = json.loads(row['keywords']   or '[]')
                item['icon_name']        = row['icon_name']
                item['screenshots']      = json.loads(row['screenshots'] or '[]')
                item['content_rating']   = row['content_rating']
                item['flatpak_ref']      = row['flatpak_ref']
                item['releases']         = json.loads(row['releases_json'] or '[]')
                item['verified']         = bool(row['verified'])
                item['monthly_downloads']= row['monthly_downloads']

        for item in nix_items:
            row = conn.execute(
                """SELECT pname, version, description, long_description,
                          homepage, license, maintainers
                   FROM nix_packages WHERE attr = ?""",
                (item['id'],)
            ).fetchone()
            if row:
                item['name']             = row['pname']
                item['description']      = row['description']
                item['version']          = row['version']
                item['long_description'] = row['long_description']
                item['homepage']         = row['homepage']
                item['license']          = row['license']
                item['maintainers']      = json.loads(row['maintainers'] or '[]')

        conn.close()
    except Exception:
        pass

print(json.dumps({'flatpak': flat_items, 'nix': nix_items}, indent=2))
PYEOF
}

cmd_browse() {
    local source="all" category="" limit=50 json=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)   source="$2";   shift 2 ;;
            --category) category="$2"; shift 2 ;;
            --limit)    limit="$2";    shift 2 ;;
            --json)     json=true;     shift ;;
            *) die "Usage: mirror-os browse [--source flatpak|nix|all] [--category <cat>] [--limit N] [--json]" ;;
        esac
    done

    [ -f "$CATALOG_DB" ] || die "Catalog not built yet. Run: mirror-os catalog update"

    python3 - "$CATALOG_DB" "$source" "$category" "$limit" "$json" << 'PYEOF'
import sys, json, sqlite3

db_path  = sys.argv[1]
source   = sys.argv[2]   # 'flatpak', 'nix', or 'all'
category = sys.argv[3]   # '' means all categories
limit    = int(sys.argv[4])
as_json  = sys.argv[5] == 'true'

conn = sqlite3.connect(db_path, timeout=5)
conn.execute("PRAGMA query_only = ON")
conn.row_factory = sqlite3.Row

flat_items = []
nix_items  = []

if source in ('flatpak', 'all'):
    if category:
        rows = conn.execute("""
            SELECT app_id, name, summary, version, release_date, developer,
                   license, homepage, categories, icon_name, screenshots,
                   content_rating, flatpak_ref, releases_json, verified, monthly_downloads
            FROM flatpak_apps
            WHERE categories LIKE ?
            ORDER BY name COLLATE NOCASE
            LIMIT ?
        """, (f'%"{category}"%', limit)).fetchall()
    else:
        rows = conn.execute("""
            SELECT app_id, name, summary, version, release_date, developer,
                   license, homepage, categories, icon_name, screenshots,
                   content_rating, flatpak_ref, releases_json, verified, monthly_downloads
            FROM flatpak_apps
            ORDER BY name COLLATE NOCASE
            LIMIT ?
        """, (limit,)).fetchall()

    for r in rows:
        flat_items.append({
            'id':               r['app_id'],
            'name':             r['name'],
            'description':      r['summary'],
            'version':          r['version'],
            'release_date':     r['release_date'],
            'developer':        r['developer'],
            'license':          r['license'],
            'homepage':         r['homepage'],
            'categories':       json.loads(r['categories'] or '[]'),
            'icon_name':        r['icon_name'],
            'screenshots':      json.loads(r['screenshots'] or '[]'),
            'content_rating':   r['content_rating'],
            'flatpak_ref':      r['flatpak_ref'],
            'releases':         json.loads(r['releases_json'] or '[]'),
            'verified':         bool(r['verified']),
            'monthly_downloads': r['monthly_downloads'],
        })

if source in ('nix', 'all') and not category:
    rows = conn.execute("""
        SELECT attr, pname, version, description, homepage, license, maintainers
        FROM nix_packages
        ORDER BY pname COLLATE NOCASE
        LIMIT ?
    """, (limit,)).fetchall()
    for r in rows:
        nix_items.append({
            'id':          r['attr'],
            'name':        r['pname'],
            'description': r['description'],
            'version':     r['version'],
            'homepage':    r['homepage'],
            'license':     r['license'],
            'maintainers': json.loads(r['maintainers'] or '[]'),
        })

conn.close()

if as_json:
    print(json.dumps({'flatpak': flat_items, 'nix': nix_items}, indent=2))
else:
    if flat_items:
        print("\n  Flatpak (flathub):")
        for a in flat_items:
            print(f"    {a['name']:<40s}  {a['description'][:55]}")
    if nix_items:
        print("\n  Nix packages (nixpkgs):")
        for p in nix_items:
            print(f"    {p['name']:<40s}  {p['description'][:55]}")
    if not flat_items and not nix_items:
        print("No apps found." + (f" (category: {category})" if category else ""))
PYEOF
}
