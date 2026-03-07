# Mirror OS system-managed Home Manager configuration.
# This file lives in the read-only OS image (/usr/share/mirror-os/home.nix)
# and is imported directly by every user's flake.nix.
# It is updated with each image release — do not copy it into your home.
# Your personal customisations belong in ~/.config/home-manager/home-user.nix.
{ config, pkgs, lib, username, ... }:

{
  home.username = username;
  home.homeDirectory = "/var/home/${username}";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  # Git identity — set once at first login, matches the identity mirror-init
  # uses for the state repo.  Users can override in home-user.nix.
  programs.git = {
    enable = true;
    settings.user = {
      name = username;
      email = "${username}@mirror-os.local";
    };
  };

  # Default packages — terminal tools that have no Flatpak equivalent.
  # Waydroid is installed as an RPM via BlueBuild (not here) so the container
  # service and D-Bus policy from the upstream package are used unchanged.
  home.packages = with pkgs; [
    htop
  ];

  # Hide htop from graphical app launchers — it's a terminal-only tool.
  xdg.desktopEntries."htop" = {
    name = "htop";
    exec = "htop";
    noDisplay = true;
  };

  # Shell
  programs.zsh = {
    enable = true;
    # Adopt XDG config directory now to avoid a breaking default change in a
    # future Home Manager release.  Zsh files will live in ~/.config/zsh/.
    dotDir = ".config/zsh";
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    oh-my-zsh = {
      enable = true;
      theme = "robbyrussell";
      plugins = [ "git" "sudo" "history" "dirhistory" ];
    };
    # First-run Waydroid init: prompt for sudo on the very first waydroid
    # invocation.  Waydroid is installed as an RPM so the binary is always
    # at /usr/bin/waydroid; command -v resolves it for sudo's restricted PATH.
    initContent = ''
      waydroid() {
        if ! [ -d /var/lib/waydroid/images ]; then
          printf '\nWaydroid needs a one-time setup to download the Android image.\n'
          printf 'Your sudo password is required.\n\n'
          sudo "$(command -v waydroid)" init || return 1
        fi
        command waydroid "$@"
      }
    '';
  };

  # GTK3 theme for native (non-Flatpak) GTK3 apps.
  # adw-gtk3-theme is baked into the image as an RPM; package = null tells
  # Home Manager not to try to install it from Nixpkgs.
  gtk = {
    enable = true;
    theme = {
      name = "adw-gtk3-dark";
      package = null;
    };
  };

  # Route the xdg-desktop-portal Settings interface through xdg-desktop-portal-gtk
  # so GTK4/Libadwaita Flatpak apps receive the color-scheme preference.
  # xdg-desktop-portal-cosmic does not implement the Settings portal; the gtk
  # backend reads from org.gnome.desktop.interface:color-scheme, which COSMIC
  # already keeps up to date. All other portal interfaces remain on COSMIC.
  home.file.".config/xdg-desktop-portal/portals.conf".text = ''
    [preferred]
    default=cosmic
    org.freedesktop.impl.portal.Settings=gtk
  '';

  # Flatpak — global overrides for theming and window decorations.
  # Written declaratively as a file to avoid nix-flatpak's managed-install service,
  # which sends noisy "Installing 0 Flatpaks" notifications on every activation.
  # To manage Flatpak packages declaratively, add services.flatpak in home-user.nix
  # or install apps via mirror-os install / the Software Center.
  #
  # GTK_THEME=adw-gtk3-dark  — forces dark mode for GTK3 Flatpak apps (GTK4/
  #   Libadwaita apps use the color-scheme portal instead and ignore this).
  # GTK_CSD=0                — tells GTK3 apps to request server-side decorations
  #   from COSMIC rather than drawing their own title bars.
  home.file.".local/share/flatpak/overrides/global".text = ''
    [Environment]
    GTK_THEME=adw-gtk3-dark
    GTK_CSD=0
    ICON_THEME=Breeze
  '';

  # Workaround: prevent duplicate Flatpak entries in COSMIC launcher.
  # COSMIC scans both ~/.local/share/applications/ (XDG_DATA_HOME) and
  # ~/.local/share/flatpak/exports/share/applications/ (appended to
  # XDG_DATA_DIRS by /etc/profile.d/flatpak.sh) and does not de-duplicate
  # by app ID — causing user-scope Flatpaks to appear twice.
  # We set XDG_DATA_DIRS explicitly without the user exports path; Flatpak's
  # own symlinks in ~/.local/share/ remain visible so apps still appear once.
  # Icons are unaffected: Flatpak also symlinks icons into ~/.local/share/icons/.
  # Remove this override once pop-os/cosmic-epoch fixes the de-duplication bug.
  home.sessionVariables = {
    XDG_DATA_DIRS = lib.concatStringsSep ":" [
      "${config.home.homeDirectory}/.nix-profile/share"
      "${config.home.homeDirectory}/.local/share"
      "/usr/local/share"
      "/usr/share"
      "/var/lib/flatpak/exports/share"
    ];
  };
}
