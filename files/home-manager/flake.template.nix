{
  description = "Mirror OS Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=v0.5.1";

    cosmic-manager = {
      url = "github:HeitorAugustoLN/cosmic-manager";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
      };
    };
  };

  outputs = { nixpkgs, home-manager, nix-flatpak, cosmic-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      homeConfigurations."__USERNAME__" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          nix-flatpak.homeManagerModules.nix-flatpak
          cosmic-manager.homeManagerModules.cosmic-manager
          ./home.nix
        ];
      };
    };
}
