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

{ config, pkgs, lib, ... }:

{
  # Let Home Manager manage itself so the `home-manager` CLI stays in PATH
  # and can apply future configuration updates.
  programs.home-manager.enable = true;

  wayland.desktopManager.cosmic = {
    enable = true;
  };
  home.stateVersion = "24.11";
  
  # ── Prompt — Starship ─────────────────────────────────────────────────────
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      format = "$directory$git_branch$git_status$nix_shell$cmd_duration$line_break$character";
      character = {
        success_symbol = "[❯](bold green)";
        error_symbol = "[❯](bold red)";
      };
      directory = {
        truncation_length = 3;
        truncate_to_repo = true;
        style = "bold blue";
      };
      git_branch = {
        symbol = " ";
        style = "bold purple";
      };
      git_status = {
        style = "bold red";
      };
      nix_shell = {
        symbol = " ";
        style = "bold cyan";
      };
      cmd_duration = {
        min_time = 2000;
        style = "bold yellow";
      };
    };
  };

  # ── Packages ─────────────────────────────────────────────────────────────
  home.packages = [
    pkgs.htop
  ];

  # ── htop desktop entry (hidden from app menus) ────────────────────────────
  xdg.desktopEntries."htop" = {
    name = "htop";
    exec = "htop";
    noDisplay = true;
  };

  # ── Flatpaks via nix-flatpak ──────────────────────────────────────────────
  services.flatpak = {
    enable = true;
    remotes = [
      { name = "flathub"; location = "https://dl.flathub.org/repo/flathub.flatpakrepo"; }
      { name = "kde"; location = "https://distribute.kde.org/kdeapps.flatpakrepo"; }
    ];
    packages = [
      { appId = "app.zen_browser.zen"; origin = "flathub"; }
      { appId = "org.localsend.localsend_app"; origin = "flathub"; }
      { appId = "org.onlyoffice.desktopeditors"; origin = "flathub"; }
      { appId = "org.gnome.Calendar"; origin = "flathub"; }
      { appId = "org.gnome.Geary"; origin = "flathub"; }
      { appId = "it.mijorus.gearlever"; origin = "flathub"; }
      { appId = "io.github.dvlv.boxbuddyrs"; origin = "flathub"; }
      { appId = "org.kde.haruna"; origin = "flathub"; }
      { appId = "org.gnome.Loupe"; origin = "flathub"; }
      { appId = "com.github.k4zmu2a.spacecadetpinball"; origin = "flathub"; }
      { appId = "com.usebottles.bottles"; origin = "flathub"; }
      { appId = "com.github.tchx84.Flatseal"; origin = "flathub"; }
      { appId = "org.gnome.Mahjongg"; origin = "flathub"; }
      { appId = "org.gnome.Aisleriot"; origin = "flathub"; }
      { appId = "org.gnome.Sudoku"; origin = "flathub"; }
      { appId = "org.gnome.TwentyFortyEight"; origin = "flathub"; }
      { appId = "org.gnome.Calculator"; origin = "flathub"; }
      { appId = "org.kde.kdeconnect"; origin = "kde"; }
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
