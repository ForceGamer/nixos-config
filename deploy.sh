nix run nixpkgs#nixos-rebuild -- switch --flake .#arbiter --target-host admin@arbiter --sudo --ask-sudo-password
# Shorthand to make deploys to ARBITER simpler.
# Will probably rename when more hosts are added.
