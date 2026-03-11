# mirror-os lib/catalog.bash — catalog search, FTS queries, auto-selection, interactive picker
# Sourced by mirror-os; do not execute directly.

# Query catalog_fts; returns "id\tname\tdescription" lines or empty
# $1 = source ('flatpak' or 'nix'), $2 = query string, $3 = limit (default 20)
catalog_fts_query() {
    local source="$1" query="$2" limit="${3:-20}"
    [ -f "$CATALOG_DB" ] || return 1

    python3 - "$CATALOG_DB" "$source" "$query" "$limit" << 'PYEOF'
import sys, sqlite3

db_path = sys.argv[1]
source  = sys.argv[2]
query   = sys.argv[3].strip()
limit   = int(sys.argv[4])

if not query:
    sys.exit(0)

# Sanitise FTS query: wrap each token in double-quotes to avoid syntax errors
tokens = query.split()
fts_q  = ' '.join(f'"{t}"' for t in tokens) if tokens else '""'

try:
    conn = sqlite3.connect(db_path, timeout=5)
    conn.execute("PRAGMA query_only = ON")

    if source == 'flatpak':
        rows = conn.execute("""
            SELECT f.app_id, f.name, f.summary
            FROM catalog_fts c
            JOIN flatpak_apps f ON c.id = f.app_id
            WHERE c.source = 'flatpak' AND catalog_fts MATCH ?
            ORDER BY bm25(catalog_fts, 0, 10, 10, 1, 1, 1)
            LIMIT ?
        """, (fts_q, limit)).fetchall()
    else:
        rows = conn.execute("""
            SELECT n.attr, n.pname, n.description
            FROM catalog_fts c
            JOIN nix_packages n ON c.id = n.attr
            WHERE c.source = 'nix' AND catalog_fts MATCH ?
            ORDER BY bm25(catalog_fts, 0, 10, 10, 1, 1, 1)
            LIMIT ?
        """, (fts_q, limit)).fetchall()

    conn.close()
    for r in rows:
        desc = (r[2] or '').replace('\n', ' ')[:80]
        print(f"{r[0]}\t{r[1]}\t{desc}")
except Exception:
    pass
PYEOF
}

# ── Flatpak search ───────────────────────────────────────────────────────────
# Returns lines of "AppID\tName\tDescription"
flatpak_search() {
    local query="$1"

    # DB path: fast, offline
    if [ -f "$CATALOG_DB" ]; then
        local result
        result=$(catalog_fts_query flatpak "$query")
        if [ -n "$result" ]; then
            echo "$result"
            return
        fi
    fi

    # Fallback: live Flatpak query
    catalog_hint
    flatpak search --columns=application,name,description "$query" 2>/dev/null \
        | grep -v '^Application' \
        | head -20
}

# ── Nix search ───────────────────────────────────────────────────────────────
# Returns lines of "attr\tname\tdescription"
nix_search() {
    local query="$1"

    # DB path: fast, offline
    if [ -f "$CATALOG_DB" ]; then
        local result
        result=$(catalog_fts_query nix "$query")
        if [ -n "$result" ]; then
            echo "$result"
            return
        fi
    fi

    # Fallback: live nix search
    catalog_hint
    nix search nixpkgs "$query" --json 2>/dev/null \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
for key, val in list(data.items())[:20]:
    attr = key.split('.')[-1] if '.' in key else key
    name = val.get('pname', attr)
    desc = val.get('description', '').replace('\n', ' ')[:80]
    print(f'{attr}\t{name}\t{desc}')
" 2>/dev/null || true
}

# ── Auto-select best result ───────────────────────────────────────────────────
# Picks the best app from combined flatpak + nix results using:
#   1. Most recent version (primary, descending)
#   2. Oldest release date (secondary, ascending) = most established
#
# Outputs two lines:
#   Line 1: "source:id:name"
#   Line 2: JSON metadata {"version":"...","release_date":"...","source":"..."}
auto_select_best() {
    local flat_raw="$1"
    local nix_raw="$2"
    local query="${3:-}"

    python3 - "$CATALOG_DB" "$flat_raw" "$nix_raw" "$query" << 'PYEOF'
import sys, sqlite3, json, re, functools

db_path  = sys.argv[1]
flat_raw = sys.argv[2].strip()
nix_raw  = sys.argv[3].strip()
query    = sys.argv[4].lower().strip() if len(sys.argv) > 4 else ''

def parse_tsv(raw, source):
    result = []
    for line in raw.splitlines():
        parts = line.split('\t')
        if len(parts) >= 2 and parts[0]:
            result.append({'source': source, 'id': parts[0], 'name': parts[1]})
    return result

candidates = parse_tsv(flat_raw, 'flatpak') + parse_tsv(nix_raw, 'nix')
if not candidates:
    sys.exit(1)

def version_key(v):
    """
    Split version string into a comparable tuple.
    Numeric segments sort as integers; string segments sort lexically but
    rank after all purely-numeric segments.
    Examples: 1.2.10 > 1.2.9, 2.0 > 1.99, 1.0-beta < 1.0
    """
    if not v:
        return ()
    parts = re.split(r'[.\-_+]', v)
    result = []
    for p in parts:
        if p.isdigit():
            result.append((0, int(p)))
        elif p:
            result.append((1, p))
    return tuple(result)

def date_key(d):
    """
    Parse 'YYYY-MM-DD' → comparable tuple.
    Unknown/empty dates → (9999,12,31) (least established, sorts last in asc order).
    """
    try:
        parts = d.split('-')
        return (int(parts[0]), int(parts[1]), int(parts[2]))
    except Exception:
        return (9999, 12, 31)

# Enrich candidates from DB
db_available = False
if db_path and __import__('os').path.exists(db_path):
    try:
        conn = sqlite3.connect(db_path, timeout=5)
        conn.execute("PRAGMA query_only = ON")
        db_available = True
    except Exception:
        pass

enriched = []
for c in candidates:
    version = ''
    release_date = ''
    verified = False
    if db_available:
        try:
            if c['source'] == 'flatpak':
                row = conn.execute(
                    "SELECT version, release_date, verified FROM flatpak_apps WHERE app_id = ?",
                    (c['id'],)
                ).fetchone()
                if row:
                    version      = row[0] or ''
                    release_date = row[1] or ''
                    verified     = bool(row[2])
            else:
                row = conn.execute(
                    "SELECT version, '' FROM nix_packages WHERE attr = ?",
                    (c['id'],)
                ).fetchone()
                if row:
                    version      = row[0] or ''
                    release_date = row[1] or ''
        except Exception:
            pass
    enriched.append({**c, 'version': version, 'release_date': release_date, 'verified': verified})

if db_available:
    conn.close()

def name_match(e):
    """
    Score how well the query matches this candidate's name/id. Lower = better.

    -3  exact name match  — name == query (e.g. "Spotify" for query "spotify")
    -2  full title match  — all query tokens appear in name (e.g. "Visual Studio Code"
                            for query "visual studio code"); also catches single-token
                            queries where the token is in the name
    -1  id or partial     — query token found only in the technical app ID, or name
                            contains a token only as a substring inside a longer word
     0  no match
    """
    if not query:
        return 0
    name_lower = e['name'].lower()
    id_lower   = e['id'].lower()
    tokens     = query.split()

    # Exact name match: name equals query after normalisation
    if name_lower == query:
        return -3

    # Full title match: every query token appears somewhere in the name
    if all(t in name_lower for t in tokens):
        return -2

    # Partial or id-only match
    if any(t in name_lower or t in id_lower for t in tokens):
        return -1

    return 0

def compare(a, b):
    """
    Compare two candidates. Returns negative if a should sort before b (i.e. a is preferred).

    Priority order:
      1. Title match quality (-3 exact > -2 full > -1 partial/id > 0 none)
      2. Flathub verified badge — verified Flatpak wins over unverified regardless of version
      3. Version comparison — only when BOTH have version data (higher version wins)
      4. Source preference — Flatpak over Nix (handles missing-version cases gracefully)
      5. Release date — older = more established (ascending)
    """
    # 1. Name/title match quality
    nm_a = name_match(a)
    nm_b = name_match(b)
    if nm_a != nm_b:
        return nm_a - nm_b

    # 2. Flathub verified badge: verified Flatpak beats everything else
    if a['verified'] != b['verified']:
        return -1 if a['verified'] else 1  # verified sorts first

    # 3. Version comparison (only when both sides have version data)
    vk_a = version_key(a['version'])
    vk_b = version_key(b['version'])
    if vk_a and vk_b and vk_a != vk_b:
        return -1 if vk_a > vk_b else 1  # higher version sorts first

    # 4. Source preference: Flatpak > Nix
    #    This handles the common case where Flatpak lacks AppStream release info
    #    (empty version) but is still the better/more up-to-date choice for GUI apps.
    src_a = 0 if a['source'] == 'flatpak' else 1
    src_b = 0 if b['source'] == 'flatpak' else 1
    if src_a != src_b:
        return src_a - src_b

    # 5. Release date: older = more established (ascending)
    dk_a = date_key(a['release_date'])
    dk_b = date_key(b['release_date'])
    if dk_a < dk_b:
        return -1
    if dk_a > dk_b:
        return 1
    return 0

enriched.sort(key=functools.cmp_to_key(compare))
best = enriched[0]

print(f"{best['source']}:{best['id']}:{best['name']}")
print(json.dumps({
    'version':      best['version'],
    'release_date': best['release_date'],
    'source':       best['source'],
}))
PYEOF
}

# ── Interactive picker ───────────────────────────────────────────────────────
# Given results lines, let user pick one. Returns "source:id:name" or empty.
pick_result() {
    local -a flat_ids flat_names flat_descs
    local -a nix_ids nix_names nix_descs
    local flatpak_raw="$1"
    local nix_raw="$2"

    while IFS=$'\t' read -r id name desc; do
        [ -z "$id" ] && continue
        flat_ids+=("$id"); flat_names+=("$name"); flat_descs+=("$desc")
    done <<< "$flatpak_raw"

    while IFS=$'\t' read -r id name desc; do
        [ -z "$id" ] && continue
        nix_ids+=("$id"); nix_names+=("$name"); nix_descs+=("$desc")
    done <<< "$nix_raw"

    local total=$(( ${#flat_ids[@]} + ${#nix_ids[@]} ))
    [ "$total" -eq 0 ] && return 1

    local i=1
    if [ ${#flat_ids[@]} -gt 0 ]; then
        echo ""
        echo "  Flatpak:"
        for j in "${!flat_ids[@]}"; do
            printf "  [%2d] %-40s  %s\n" "$i" "${flat_names[$j]} (${flat_ids[$j]})" "${flat_descs[$j]:0:50}"
            (( i++ ))
        done
    fi
    if [ ${#nix_ids[@]} -gt 0 ]; then
        echo ""
        echo "  Nix packages:"
        for j in "${!nix_ids[@]}"; do
            printf "  [%2d] %-40s  %s\n" "$i" "${nix_names[$j]} (nixpkgs.${nix_ids[$j]})" "${nix_descs[$j]:0:50}"
            (( i++ ))
        done
    fi

    echo ""
    printf "Select number (1-%d) or q to quit: " "$total"
    read -r choice
    [[ "$choice" == "q" || -z "$choice" ]] && return 1

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$total" ]; then
        echo "Invalid selection." >&2; return 1
    fi

    local idx=$(( choice - 1 ))
    if [ "$idx" -lt "${#flat_ids[@]}" ]; then
        echo "flatpak:${flat_ids[$idx]}:${flat_names[$idx]}"
    else
        local nix_idx=$(( idx - ${#flat_ids[@]} ))
        echo "nix:${nix_ids[$nix_idx]}:${nix_names[$nix_idx]}"
    fi
}
