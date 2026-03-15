{
  description = "MirrorOS image dev shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    devShells.${system}.default = pkgs.mkShell {
      name = "mirror-os";
      packages = with pkgs; [
        podman         # local image builds: podman build -t mirror-os .
        skopeo         # inspect/copy images from GHCR; used in CI verify steps
        cosign         # verify signed images locally
        python3        # embedded TOML parser in mirror-sync
        jq             # JSON/registry API processing
        shellcheck     # lint bash scripts under files/usr/libexec/
        yq-go          # inspect/query recipes/mirror-os.yml
        git
        curl
      ];
      shellHook = ''
        echo "MirrorOS dev shell — image build tools ready."
        echo "  Build:  podman build -t mirror-os ."
        echo "  Verify: skopeo inspect docker://ghcr.io/mirror-os/mirror-os:latest"
      '';
    };
  };
}
