{ pkgs, ... }:

{
  imports = [ /usr/share/mirror-os/home-manager/default.nix ];

  # ── Identity ──────────────────────────────────────────────────────────────
  # These are set automatically by the first-boot service.
  home.username = "__USERNAME__";
  home.homeDirectory = "/home/__USERNAME__";
  home.stateVersion = "24.11";

  # ── Your personal configuration ───────────────────────────────────────────
  # Override any Mirror OS defaults or add your own packages and settings.
  # This file is yours — image updates will never modify it.
  # Remove the import above to fully detach from Mirror OS defaults.
  #
  # Examples:
  #
  #   home.packages = with pkgs; [ ripgrep fd bat ];
  #
  #   programs.git = {
  #     enable = true;
  #     userName = "Your Name";
  #     userEmail = "you@example.com";
  #   };
  #
  #   programs.zsh.oh-my-zsh.theme = "agnoster";  # override the default theme
}
