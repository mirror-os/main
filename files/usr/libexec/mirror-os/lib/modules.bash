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
