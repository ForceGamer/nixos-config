nix run nixpkgs#nixos-rebuild -- test --flake .#arbiter --target-host admin@arbiter --sudo
# Shorthand to make deploys to ARBITER simpler.
# Will probably rename when more hosts are added.
