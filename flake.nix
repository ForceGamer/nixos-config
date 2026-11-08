{
  description = "Homelab NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nixpkgs has no module for decrypting repo-committed secrets at activation.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nixpkgs can run containers but has no module for declarative VMs.
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      sops-nix,
      microvm,
    }:
    {
      nixosConfigurations.arbiter = nixpkgs.lib.nixosSystem {
        # auto-upgrade.nix needs this flake's own source to rebuild from.
        specialArgs = { inherit self; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          microvm.nixosModules.host
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
