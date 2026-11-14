# Guest side of the Claude Code microVM. Evaluated by microvm.nix, not as part
# of the host. Claude Code and T3 Code are installed by hand with their own
# installers into ~/.local/bin (both self-updating, so not pinned here).
{
  pkgs,
  net,
  t3,
  adminKeys,
  ...
}:
let
  # A pairing link that points at Caddy on ARBITER (https://code.<domain>)
  # rather than at the VM's own address, which only the host can reach.
  # `t3 pair` has no option for the address, but it prints the one-time
  # token, and the link format is <address>/pair#token=<token>.
  t3-pair = pkgs.writeShellApplication {
    name = "t3-pair";
    runtimeInputs = with pkgs; [
      gnused
      jq
      qrencode
    ];
    text = ''
      args=(pair)
      [ -z "''${1:-}" ] || args+=(--label "$1")
      out=$(t3 "''${args[@]}")
      token=$(sed -nE 's/^Token: ([A-Za-z0-9_-]+)$/\1/p' <<<"$out")
      if [ -z "$token" ]; then
        echo "t3 pair printed no token; is the t3code service running?" >&2
        exit 1
      fi
      url="https://${t3.host}/pair#token=$token"
      qrencode -t ANSIUTF8 "$url"
      echo "Pairing URL: $url"
      echo "App link:    t3code://pair?pairingUrl=$(jq -rn --arg u "$url" '$u | @uri')"
      echo "One device, once. Revoke later with: t3 auth session list / revoke <id>"
    '';
  };

  # Managed policy (docs/user/managed-policy.md): defaults that the user may
  # still change per thread, and limits nobody can. No maxRuntimeMode: with
  # one set, every provider's launch settings would have to live here too.
  t3Policy = {
    schemaVersion = 1;
    organization = "homelab";
    settings.defaultRuntimeMode = {
      value = "auto";
      locked = false;
    };
    limits.telemetry = false;
  };
in
{
  imports = [ ./base.nix ];

  microvm = {
    # microvm.nix's default and most-tested hypervisor; runs as the
    # unprivileged microvm user on the host. Also the only one whose guest can
    # be booted on the workstation without root (user-mode networking).
    hypervisor = "qemu";
    # Room for several agents in parallel worktrees.
    vcpu = 8;
    # Not exactly 2048: QEMU hangs at that size (microvm.nix issue 171).
    mem = 16384;
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
  # T3 Code, for Caddy on the host only.
  networking.firewall.extraInputRules = ''
    ip saddr ${net.host} tcp dport ${toString t3.port} accept
  '';

  users.mutableUsers = false;
  users.users.root.hashedPassword = "!";
  # Deliberately no admin login inside the VM; it is managed from ARBITER's
  # config and can always be rebuilt or restarted from the host.
  users.allowNoPasswordLogin = true;
  # No sudo: Claude Code works as this user, and the VM is managed from the repo.
  users.users.claude = {
    isNormalUser = true;
    openssh.authorizedKeys.keys = adminKeys;
    # Start claude's user services at boot, without anyone logged in.
    linger = true;
  };

  # T3 Code's server: one place for the desktop, web and mobile apps to run
  # and steer agents (Claude Code, Codex, ...) in this VM. It drives the
  # provider CLIs on PATH with their own logins, so a provider is ready once
  # its CLI is in ~/.local/bin or the Nix profile and logged in (e.g.
  # `nix profile install nixpkgs#codex && codex login`, then restart this
  # service). Skipped until t3 is installed:
  #   curl -fsSL https://t3.codes/install.sh | sh   (pin: T3CODE_VERSION=…)
  # Devices pair with `t3-pair`. Replaces Claude Code's Remote Control.
  systemd.user.services.t3code = {
    description = "T3 Code server";
    wantedBy = [ "default.target" ];
    unitConfig = {
      ConditionUser = "claude";
      ConditionPathExists = "%h/.local/bin/t3";
    };
    environment = {
      # Also off in the policy; these cover the relay traces too.
      T3CODE_TELEMETRY_ENABLED = "false";
      OTEL_SDK_DISABLED = "true";
    };
    serviceConfig = {
      # A login shell gives agents the same environment as an SSH login:
      # system PATH, ~/.local/bin, the Nix profile and nix-ld's variables.
      ExecStart = "${pkgs.bash}/bin/bash -lc 'mkdir -p ~/src && cd ~/src && exec t3 serve --no-browser --host ${net.guest} --port ${toString t3.port} ~/src'";
      # Also covers exits after `t3 update`.
      Restart = "always";
      RestartSec = "30s";
    };
  };
  environment.etc."t3code/policy.json".text = builtins.toJSON t3Policy;

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
    t3-pair
  ];

  system.stateVersion = "26.05";
}
