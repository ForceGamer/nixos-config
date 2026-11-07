{
  description = "Homelab NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
    }:
    {
      nixosConfigurations.arbiter = nixpkgs.lib.nixosSystem {
        # auto-upgrade.nix needs this flake's own source to rebuild from.
        specialArgs = { inherit self; };
        modules = [
          disko.nixosModules.disko
          ./hosts/arbiter
        ];
      };

      # nixfmt's own wrapper for `nix fmt`; bare nixfmt no longer accepts
      # directories. Anchor the tree root on flake.nix so formatting never
      # wanders outside the repo when it isn't a git checkout.
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree.override {
        settings.tree-root-file = "flake.nix";
      };
    };
}
