# mirror-os lib/instances.bash — instances.db schema, migration, register/deregister
# Sourced by mirror-os; do not execute directly.

# Ensure instances.db schema exists (idempotent).
ensure_instances_schema() {
    python3 - "$INSTANCES_DB" << 'PYEOF'
import sys, sqlite3, os
db_path = sys.argv[1]
os.makedirs(os.path.dirname(db_path), exist_ok=True)
conn = sqlite3.connect(db_path, timeout=10)
conn.executescript("""
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS app_instances (
    instance_id   TEXT PRIMARY KEY,
    slug          TEXT,
    source        TEXT NOT NULL,
    source_id     TEXT NOT NULL,
    display_label TEXT,
    module_file   TEXT NOT NULL,
    installed_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_inst_slug   ON app_instances(slug);
CREATE INDEX IF NOT EXISTS idx_inst_source ON app_instances(source, source_id);
""")
conn.close()
PYEOF
}

# Auto-migrate existing module files into instances.db if the table is empty.
migrate_existing_installs() {
    ensure_instances_schema
    python3 - "$APPS_DIR" "$CATALOG_DB" "$INSTANCES_DB" << 'PYEOF'
import sys, sqlite3, os, re
from collections import defaultdict

apps_dir     = sys.argv[1]
catalog_db   = sys.argv[2]
instances_db = sys.argv[3]

if not os.path.isdir(apps_dir):
    sys.exit(0)

inst = sqlite3.connect(instances_db, timeout=10)
count = inst.execute("SELECT COUNT(*) FROM app_instances").fetchone()[0]
if count > 0:
    inst.close()
    sys.exit(0)

cat = sqlite3.connect(catalog_db, timeout=5) if os.path.exists(catalog_db) else None

def lookup_slug_and_name(source, source_id):
    if not cat:
        return None, source_id
    try:
        cat.execute("PRAGMA query_only = ON")
        col = 'flatpak_id' if source == 'flatpak' else 'nix_attr'
        row = cat.execute(
            f"SELECT slug, display_name FROM app_map WHERE {col}=?", (source_id,)
        ).fetchone()
        return (row[0], row[1]) if row else (None, source_id)
    except Exception:
        return None, source_id

instances = []
for fname in sorted(os.listdir(apps_dir)):
    if not fname.endswith('.nix'):
        continue
    path = os.path.join(apps_dir, fname)
    instance_id = fname[:-4]
    try:
        content = open(path).read()
    except Exception:
        continue
    source = 'unknown'
    source_id = instance_id
    if 'services.flatpak' in content:
        source = 'flatpak'
        m = re.search(r'appId\s*=\s*"([^"]+)"', content)
        if m:
            source_id = m.group(1)
    elif 'home.packages' in content:
        source = 'nix'
        m = re.search(r'pkgs\.(\S+)\s*[\];}]', content)
        if m:
            source_id = m.group(1)
    elif 'homeManagerModules' in content:
        source = 'pro_flake'
    slug, display_name = lookup_slug_and_name(source, source_id)
    instances.append((instance_id, slug, source, source_id, display_name, path))

# Auto-label instances sharing the same slug
slug_groups = defaultdict(list)
for inst_row in instances:
    if inst_row[1]:
        slug_groups[inst_row[1]].append(inst_row)

label_map = {}
for slug, group in slug_groups.items():
    if len(group) < 2:
        continue
    display_name = group[0][4]
    src_counts = defaultdict(int)
    for r in group:
        src_counts[r[2]] += 1
    src_idx = defaultdict(int)
    for r in group:
        src = r[2]
        src_idx[src] += 1
        src_label = 'Flatpak' if src == 'flatpak' else src.capitalize()
        if src_counts[src] > 1:
            label_map[r[0]] = f"{display_name} ({src_label} {src_idx[src]})"
        else:
            label_map[r[0]] = f"{display_name} ({src_label})"

rows = []
for instance_id, slug, source, source_id, _, path in instances:
    rows.append((instance_id, slug, source, source_id, label_map.get(instance_id), path))

with inst:
    inst.executemany("""
        INSERT OR IGNORE INTO app_instances
            (instance_id, slug, source, source_id, display_label, module_file)
        VALUES (?,?,?,?,?,?)
    """, rows)

if cat:
    cat.close()
inst.close()
print(f"Migrated {len(rows)} existing installations.", file=sys.stderr)
PYEOF
}

# Register an installed app instance. Prints a note if duplicate slug detected.
# Usage: register_instance <instance_id> <source> <source_id> <module_file>
register_instance() {
    local instance_id="$1" source="$2" source_id="$3" module_file="$4"
    ensure_instances_schema
    python3 - "$INSTANCES_DB" "$CATALOG_DB" \
              "$instance_id" "$source" "$source_id" "$module_file" << 'PYEOF'
import sys, sqlite3, os

instances_db = sys.argv[1]
catalog_db   = sys.argv[2]
instance_id  = sys.argv[3]
source       = sys.argv[4]
source_id    = sys.argv[5]
module_file  = sys.argv[6]

slug = None
display_name = instance_id
if os.path.exists(catalog_db):
    try:
        cat = sqlite3.connect(catalog_db, timeout=5)
        cat.execute("PRAGMA query_only = ON")
        col = 'flatpak_id' if source == 'flatpak' else 'nix_attr'
        row = cat.execute(
            f"SELECT slug, display_name FROM app_map WHERE {col}=?", (source_id,)
        ).fetchone()
        if row:
            slug, display_name = row
        cat.close()
    except Exception:
        pass

inst = sqlite3.connect(instances_db, timeout=10)

existing = []
if slug:
    existing = inst.execute(
        "SELECT instance_id, source, display_label FROM app_instances "
        "WHERE slug=? AND instance_id != ?",
        (slug, instance_id)
    ).fetchall()

label = None
if existing:
    src_label = 'Flatpak' if source == 'flatpak' else source.capitalize()
    label = f"{display_name} ({src_label})"
    for ex_id, ex_src, ex_label in existing:
        if ex_label is None or (ex_label.startswith(display_name) and ex_label.endswith(')')):
            ex_src_label = 'Flatpak' if ex_src == 'flatpak' else ex_src.capitalize()
            with inst:
                inst.execute(
                    "UPDATE app_instances SET display_label=?, "
                    "updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE instance_id=?",
                    (f"{display_name} ({ex_src_label})", ex_id)
                )

with inst:
    inst.execute("""
        INSERT OR REPLACE INTO app_instances
            (instance_id, slug, source, source_id, display_label, module_file,
             installed_at, updated_at)
        VALUES (?,?,?,?,?,?,
                strftime('%Y-%m-%dT%H:%M:%SZ','now'),
                strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    """, (instance_id, slug, source, source_id, label, module_file))

if label:
    print(f"Note: also installed via another source. Labeled as '{label}'.")

inst.close()
PYEOF
}

# Deregister an uninstalled app. Clears auto-labels on remaining single instance.
# Usage: deregister_instance <instance_id>
deregister_instance() {
    local instance_id="$1"
    [ -f "$INSTANCES_DB" ] || return 0
    python3 - "$INSTANCES_DB" "$instance_id" << 'PYEOF'
import sys, sqlite3

instances_db = sys.argv[1]
instance_id  = sys.argv[2]

inst = sqlite3.connect(instances_db, timeout=10)
row = inst.execute(
    "SELECT slug FROM app_instances WHERE instance_id=?", (instance_id,)
).fetchone()

with inst:
    inst.execute("DELETE FROM app_instances WHERE instance_id=?", (instance_id,))

if row and row[0]:
    slug = row[0]
    remaining = inst.execute(
        "SELECT instance_id, display_label FROM app_instances WHERE slug=?", (slug,)
    ).fetchall()
    if len(remaining) == 1:
        ex_id, ex_label = remaining[0]
        if ex_label and ex_label.endswith(')'):
            with inst:
                inst.execute(
                    "UPDATE app_instances SET display_label=NULL, "
                    "updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE instance_id=?",
                    (ex_id,)
                )

inst.close()
PYEOF
}
