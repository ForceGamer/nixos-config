# Guest side of the Claude Code microVM. Evaluated by microvm.nix, not as part
# of the host. Claude Code itself is installed by hand with Anthropic's native
# installer (self-updating, so not pinned here).
{
  pkgs,
  net,
  adminKeys,
  ...
}:
{
  imports = [ ./base.nix ];

  microvm = {
    # microvm.nix's default and most-tested hypervisor; runs as the
    # unprivileged microvm user on the host. Also the only one whose guest can
    # be booted on the workstation without root (user-mode networking).
    hypervisor = "qemu";
    vcpu = 4;
    # Not exactly 2048: QEMU hangs at that size (microvm.nix issue 171).
    mem = 8192;
    interfaces = [
      {
        type = "tap";
        id = net.tap;
        inherit (net) mac;
      }
    ];
    # No host directories are shared: the store comes from a read-only image
    # (storeOnDisk) and all state lives on these volumes.
    volumes = [
      {
        image = "var.img";
        mountPoint = "/var";
        size = 8 * 1024;
      }
      {
        image = "home.img";
        mountPoint = "/home";
        size = 64 * 1024;
      }
      {
        image = "nix-rw-store.img";
        mountPoint = "/nix/.rw-store";
        size = 64 * 1024;
      }
    ];
    # Lets Nix in the VM build and fetch per-project toolchains.
    writableStoreOverlay = "/nix/.rw-store";
  };

  # Mount before activation, which creates home directories and the
  # uid/gid map under /var/lib/nixos.
  fileSystems."/var".neededForBoot = true;
  fileSystems."/home".neededForBoot = true;

  networking.hostName = "claude";
  networking.useNetworkd = true;
  networking.useDHCP = false;
  systemd.network.networks."10-uplink" = {
    matchConfig.MACAddress = net.mac;
    address = [ "${net.guest}/24" ];
    gateway = [ net.host ];
    dns = [ net.host ];
  };
  networking.nftables.enable = true;

  users.mutableUsers = false;
  users.users.root.hashedPassword = "!";
  # Deliberately no admin login inside the VM; it is managed from ARBITER's
  # config and can always be rebuilt or restarted from the host.
  users.allowNoPasswordLogin = true;
  # No sudo: Claude Code works as this user, and the VM is managed from the repo.
  users.users.claude = {
    isNormalUser = true;
    openssh.authorizedKeys.keys = adminKeys;
  };

  services.openssh = {
    enable = true;
    openFirewall = true;
    # / is tmpfs in the VM; keep the host key on /var so it survives reboots.
    hostKeys = [
      {
        path = "/var/lib/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "claude" ];
      X11Forwarding = false;
    };
  };

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      allowed-users = [ "claude" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };
  # `nix shell nixpkgs#…` uses the same pinned nixpkgs as ARBITER.
  nixpkgs.flake.source = pkgs.path;

  # The native installer drops a generic-Linux binary in ~/.local/bin.
  programs.nix-ld.enable = true;
  environment.localBinInPath = true;

  environment.systemPackages = with pkgs; [
    curl
    gh
    tmux
  ];

  system.stateVersion = "26.05";
}
