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

      # Unit tests of the PII rule engine, plus the examples declared next to
      # ARBITER's rules, against the rendered configuration.
      checks.x86_64-linux.contextforge-filter =
        self.nixosConfigurations.arbiter.config.homelab.contextforge.check;

      # The survey tool must never print a raw identifier: run it on the
      # fixtures and check that masks appear and the raw values don't.
      checks.x86_64-linux.pii-survey =
        nixpkgs.legacyPackages.x86_64-linux.runCommand "pii-survey-check"
          { nativeBuildInputs = [ nixpkgs.legacyPackages.x86_64-linux.python3 ]; }
          ''
            python3 ${./tools/pii-survey.py} --no-llm --fixture ${./tools/fixtures}/*.json > report
            for want in AAA-AA999999 a9a9a9a9a9a9 AaA999aaa999 99999999999999999 'name "Yubico"'; do
              grep -qF -- "$want" report || { echo "missing $want"; cat report; exit 1; }
            done
            for raw in ORD-EU313765 a1b2c3d4e5f6 AbC123xyz789 70712345678901234 Stl_ AjRx; do
              ! grep -qF -- "$raw" report || { echo "raw value leaked: $raw"; cat report; exit 1; }
            done
            cp report "$out"
          '';

      # The dead man's switch behind merge-test, in a VM: kept when healthy,
      # rolled back on failure, and rolled back by its timer when the script
      # dies after activating.
      checks.x86_64-linux.merge-test = import ./modules/merge-test/test.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
      };

      # nixfmt's own wrapper for `nix fmt`; bare nixfmt no longer accepts
      # directories. Anchor the tree root on flake.nix so formatting never
      # wanders outside the repo when it isn't a git checkout.
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree.override {
        settings.tree-root-file = "flake.nix";
      };
    };
}
