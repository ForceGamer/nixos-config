{ config, self, ... }:
{
  # Update option (b): rebuild the config that was last deployed (its source is
  # in the store via `self`) against the newest nixos-26.05 nixpkgs. No repo
  # hosting needed; the running nixpkgs drifts ahead of the committed lock until
  # the next deploy from the workstation.
  system.autoUpgrade = {
    enable = true;
    flake = "${self}#${config.networking.hostName}";
    flags = [
      # Keep in sync with inputs.nixpkgs.url in flake.nix.
      "--override-input"
      "nixpkgs"
      "github:NixOS/nixpkgs/nixos-26.05"
      # The source is a read-only store path.
      "--no-write-lock-file"
    ];
    # --upgrade only refreshes channels, which are disabled.
    upgrade = false;

    dates = "03:15";
    randomizedDelaySec = "30min";
    allowReboot = true;
    # Kernel/initrd changes only reboot inside this window; a run outside it
    # (e.g. catching up after downtime) stages the new generation for next boot.
    rebootWindow = {
      lower = "03:00";
      upper = "05:00";
    };
  };
}
