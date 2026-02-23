# Mirror OS — system-provided Home Manager defaults
#
# This file is shipped in the image at /usr/share/mirror-os/home-manager/default.nix
# and is updated with every image release.
#
# It is imported by the user's ~/.config/home-manager/home.nix.
# Users can override anything declared here in their own home.nix — their
# settings always win. Remove the import line entirely to fully detach.
#
# NOTE: This module requires the nix-flatpak flake input to be present in the
# user's flake.nix (homeManagerModules.nix-flatpak). The scaffolded flake.nix
# includes this automatically.

{ pkgs, lib, ... }:

{
  # Let Home Manager manage itself so the `home-manager` CLI stays in PATH
  # and can apply future configuration updates.
  programs.home-manager.enable = true;

  # ── Shell — Zsh ───────────────────────────────────────────────────────────
programs.zsh = {
  enable = true;

  # Built-in Home Manager options — no manual plugin sourcing needed
  autosuggestion.enable = true;
  syntaxHighlighting.enable = true;

  oh-my-zsh = {
    enable = true;
    theme = "robbyrussell";
    plugins = [ "git" ];
  };
};

  # ── htop ─────────────────────────────────────────────────────────────────
  programs.htop = {
    enable = true;
    settings = {
      color_scheme = 5;          # Black Night — dark and readable
      highlight_base_name = 1;
      highlight_megabytes = 1;
      highlight_threads = 1;
      show_thread_names = 1;
      tree_view = 1;
      header_margin = 0;
      show_cpu_frequency = 1;
    };
  };

  # ── Flatpaks via nix-flatpak ──────────────────────────────────────────────
  services.flatpak = {
    enable = true;

    packages = [
      # AppImage manager — handles .AppImage files with launcher integration
      { appId = "it.mijoras.GearLever"; origin = "flathub"; }
    ];

    overrides.global = {
      # Force consistent GTK theme and icons across all Flatpak apps
      Environment = {
        GTK_THEME = "adw-gtk3-dark";
        ICON_THEME = "Papirus-Dark";
        # Request server-side decorations (libadwaita apps may ignore this)
        GTK_CSD = "0";
        # Enable compositor-side decorations for Qt/Wayland apps
        QT_WAYLAND_DISABLE_WINDOWDECORATION = "0";
      };
    };
  };
}
