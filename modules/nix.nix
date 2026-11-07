{ config, ... }:
{
  nix = {
    # Flake-only system; channels would be a second, unpinned source of nixpkgs.
    channel.enable = false;

    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      allowed-users = [ "@wheel" ];
      # The admin must be trusted to accept unsigned closures pushed from the
      # workstation by nixos-rebuild --target-host. "root" is already in the
      # nixpkgs default, which this list merges with.
      trusted-users = [ config.homelab.admin.name ];
    };

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };

    optimise.automatic = true;
  };
}
