# mirror-os lib/modules.bash — .nix module generation and app install confirmation
# Sourced by mirror-os; do not execute directly.

# ── Generate app module files ────────────────────────────────────────────────

write_flatpak_module() {
    local app_id="$1" app_name="$2" out_file="$3"
    cat > "$out_file" << EOF
# ${app_name} — installed via mirror-os
# To remove: mirror-os uninstall ${app_id}
{ ... }: {
  services.flatpak = {
    enable = true;
    packages = [
      { appId = "${app_id}"; origin = "flathub"; }
    ];
  };
}
EOF
}

write_nix_module() {
    local attr="$1" pkg_name="$2" out_file="$3"
    cat > "$out_file" << EOF
# ${pkg_name} — installed via mirror-os
# To remove: mirror-os uninstall ${attr}
{ pkgs, ... }: {
  home.packages = [ pkgs.${attr} ];
}
EOF
}

# Look up programs_name for a nix attr in programs-map.toml.
# Prints the programs_name (e.g. "git") or nothing if not mapped.
_lookup_programs_name() {
    local attr="$1"
    local map_file="/usr/share/mirror-os/programs-map.toml"
    [ -f "$map_file" ] || return 0
    python3 - "$map_file" "$attr" << 'PYEOF'
import sys, tomllib
map_file, attr = sys.argv[1], sys.argv[2]
with open(map_file, "rb") as f:
    data = tomllib.load(f)
for entry in data.get("program", []):
    if entry.get("attr") == attr:
        print(entry.get("programs_name", ""))
        break
PYEOF
}

# Write a Home Manager programs.<name> module, optionally hydrating options
# from a sidecar JSON file.
# $1 = attr (used in comments and for sidecar lookup)
# $2 = programs_name (HM programs key, e.g. "git")
# $3 = sidecar_file (path to .options.json, or "" to skip)
# $4 = out_file
write_programs_module() {
    local attr="$1" programs_name="$2" sidecar_file="$3" out_file="$4"

    # Build the options block from the sidecar JSON if provided and non-empty.
    local options_block=""
    if [ -n "$sidecar_file" ] && [ -f "$sidecar_file" ]; then
        options_block=$(python3 - "$sidecar_file" "$programs_name" << 'PYEOF'
import sys, json

sidecar_file, programs_name = sys.argv[1], sys.argv[2]
with open(sidecar_file) as f:
    opts = json.load(f)

def nix_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    # Coerce string "true"/"false" to Nix booleans.
    # Sidecars written by older software center versions store booleans as strings.
    if v == "true":
        return "true"
    if v == "false":
        return "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, list):
        items = " ".join('"' + str(i).replace('\\', '\\\\').replace('"', '\\"') + '"' for i in v)
        return f"[ {items} ]"
    # string / path
    escaped = str(v).replace('\\', '\\\\').replace('"', '\\"')
    return f'"{escaped}"'

prefix = f"programs.{programs_name}."
opts = {(k[len(prefix):] if k.startswith(prefix) else k): v for k, v in opts.items()}

lines = []
for key, val in opts.items():
    # Handle nested dot-notation keys like "signing.key"
    parts = key.split(".")
    if len(parts) == 1:
        lines.append(f"  programs.{programs_name}.{key} = {nix_value(val)};")
    else:
        # Emit as nested attr set
        inner = ".".join(parts[1:])
        lines.append(f"  programs.{programs_name}.{parts[0]}.{inner} = {nix_value(val)};")

print("\n".join(lines))
PYEOF
)
    fi

    {
        echo "# ${attr} — installed via mirror-os"
        echo "# To remove: mirror-os uninstall ${attr}"
        echo "{ ... }: {"
        echo "  programs.${programs_name}.enable = true;"
        if [ -n "$options_block" ]; then
            echo "$options_block"
        fi
        echo "}"
    } > "$out_file"
}

# Regenerate a .nix module for attr from its sidecar JSON (if any).
# Detects whether the current module uses programs or home.packages format
# and regenerates accordingly.
# $1 = attr
regenerate_module_from_sidecar() {
    local attr="$1"
    local apps_dir="${HOME}/.config/home-manager/apps"
    local module_file="${apps_dir}/${attr}.nix"
    local sidecar_file="${apps_dir}/${attr}.options.json"

    [ -f "$module_file" ] || die "No module file found for '${attr}' at ${module_file}"

    # Detect format
    if grep -q "programs\." "$module_file" 2>/dev/null; then
        local programs_name
        programs_name=$(_lookup_programs_name "$attr")
        if [ -z "$programs_name" ]; then
            # Fall back to using attr as programs name if somehow we got here
            programs_name="$attr"
        fi
        write_programs_module "$attr" "$programs_name" "$sidecar_file" "$module_file"
        log "regenerated programs module for '${attr}'"
    else
        # home.packages format — just keep it, options don't apply here
        log "regenerate_module_from_sidecar: '${attr}' uses home.packages format, nothing to regenerate"
    fi
}

write_pro_flake_module() {
    local input_name="$1" module_name="$2" out_file="$3"
    cat > "$out_file" << EOF
# ${module_name} — pro flake installed via mirror-os
# To remove: mirror-os uninstall ${module_name}
{ inputs, ... }: {
  imports = [ inputs.${input_name}.homeManagerModules.default ];
}
EOF
}

# ── Inject pro flake input into flake.nix ───────────────────────────────────
inject_flake_input() {
    local input_name="$1" flake_url="$2"
    local marker="# Pro flake inputs are added here by mirror-os tool"
    if ! grep -q "$marker" "$FLAKE_NIX"; then
        die "Could not find pro flake marker in $FLAKE_NIX. Is it from the current image template?"
    fi
    sed -i "s|${marker}|${marker}\n    ${input_name}.url = \"${flake_url}\";|" "$FLAKE_NIX"
    echo "Added flake input: ${input_name} = ${flake_url}"
}

# ── App install confirmation preview ─────────────────────────────────────────
# Shows a metadata table for the selected app and prompts for confirmation.
# $1 = app_id, $2 = source label ("Flathub" / "Nix"), $3 = original query
# Returns 0 to proceed, 1 to abort (cancel or after delegating search-again).
_confirm_install() {
    local app_id="$1" src_display="$2" orig_query="$3"

    # Fetch size from cached Flatpak remote metadata (no network required).
    local download_size="" installed_size=""
    if [ "${src_display,,}" != "nix" ]; then
        local _rinfo
        _rinfo=$(flatpak remote-info --user flathub --cached "$app_id" 2>/dev/null \
                 || flatpak remote-info flathub --cached "$app_id" 2>/dev/null || true)
        download_size=$(printf '%s' "$_rinfo" | grep -i "^Download size:" \
                        | sed 's/[Dd]ownload size: *//' | head -1)
        installed_size=$(printf '%s' "$_rinfo" | grep -i "^Installed size:" \
                         | sed 's/[Ii]nstalled size: *//' | head -1)
    fi

    python3 - "$CATALOG_DB" "$app_id" "${src_display,,}" "$src_display" \
              "$download_size" "$installed_size" << 'PYEOF'
import sys, sqlite3, os, textwrap
db_path, app_id, src_l, src_disp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
pkg_dl   = sys.argv[5] if len(sys.argv) > 5 else ""
pkg_inst = sys.argv[6] if len(sys.argv) > 6 else ""
W = 54

def rule(): print("  " + "\u2501" * W)
def field(label, value, indent=12):
    if not value: return
    lines = textwrap.wrap(str(value), W - indent)
    if not lines: return
    print(f"  {label:<{indent}}{lines[0]}")
    for l in lines[1:]: print(f"  {' ' * indent}{l}")

name, summary, rows = app_id, "", []
if os.path.exists(db_path):
    try:
        conn = sqlite3.connect(db_path, timeout=5)
        conn.execute("PRAGMA query_only = ON")
        conn.row_factory = sqlite3.Row
        if src_l != 'nix':
            r = conn.execute(
                "SELECT name, summary, version, release_date, developer, license "
                "FROM flatpak_apps WHERE app_id = ?", (app_id,)).fetchone()
            if r:
                name    = r['name'] or app_id
                parts   = [p for p in [r['summary'], r['developer']] if p]
                summary = "  —  ".join(parts)
                rows    = [("ID",        app_id),
                           ("Version",   r['version']),
                           ("Source",    src_disp),
                           ("Released",  r['release_date']),
                           ("Download",  pkg_dl),
                           ("Installed", pkg_inst),
                           ("License",   r['license'])]
        else:
            r = conn.execute(
                "SELECT pname, version, description, homepage, license "
                "FROM nix_packages WHERE attr = ?", (app_id,)).fetchone()
            if r:
                name    = r['pname'] or app_id
                summary = r['description'] or ""
                rows    = [("Nix attr", app_id),
                           ("Version",  r['version']),
                           ("Source",   src_disp),
                           ("Homepage", r['homepage']),
                           ("License",  r['license'])]
        conn.close()
    except Exception: pass

if not rows:
    rows = [("ID", app_id), ("Source", src_disp)]

print()
rule()
for l in textwrap.wrap(name, W): print(f"  {l}")
if summary:
    for l in textwrap.wrap(summary, W): print(f"  {l}")
rule()
for label, value in rows: field(label, value)
rule()
print()
PYEOF
    # Skip confirmation prompt when called non-interactively (--yes flag)
    if ${yes:-false}; then
        return 0
    fi
    printf "Install? [Y]es  [s]earch again  [n]o: "
    local choice
    read -r choice
    case "${choice,,}" in
        ""|y|yes) return 0 ;;
        s|search)
            cmd_search "$orig_query"
            return 1 ;;
        *) echo "Cancelled."; return 1 ;;
    esac
}
