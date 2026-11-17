# T3 Code and its coding agents, run directly on ARBITER as the `agent` user.
# Not sandboxed: a deliberate exception (the user's choice, replacing the
# Claude Code microVM). The agents can do anything `agent` can, including read
# the Nix store and world-readable files and see every process. What stays in
# place: no sudo, home directories 0700 both ways, internet-only networking,
# and a memory cap.
#
# Installed by hand as `agent` with upstream's installers into ~/.local/bin;
# all self-updating, so not pinned here. T3 Code isn't taken from nixpkgs
# because upstream ships several releases a week and nixpkgs lags behind
# (0.1.8 there vs. 0.1.10 upstream on 2026-11-17):
#   curl -fsSL https://t3.codes/install.sh | sh
#   curl -fsSL https://claude.ai/install.sh | bash
#   curl -fsSL https://chatgpt.com/codex/install.sh | sh
#   curl -fsSL https://x.ai/cli/install.sh | bash
# then log each one in and `systemctl --user restart t3code`. An installer
# that uses a directory other than ~/.local/bin must put it on PATH in
# ~/.profile, which the service's login shell reads.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = "agent";
  # Static, because the nftables rules below match on it and are checked at
  # build time, before the user exists.
  uid = 1001;
  port = 3773;
  host = "code.${config.homelab.domain}";

  # A pairing link that points at Caddy (https://code.<domain>) rather than
  # at the loopback address T3 Code listens on. `t3 pair` has no option for
  # the address, but it prints the one-time token, and the link format is
  # <address>/pair#token=<token>.
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
      url="https://${host}/pair#token=$token"
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

  # ARBITER's own services, which agents must not reach over loopback (or
  # the host's own addresses, which also route through lo). Other loopback
  # ports stay open so agents can run and test their own servers. A new
  # service listening on localhost belongs in this list.
  hostPorts = [
    22 # sshd
    443 # Caddy: every LAN site, including this one and the gateway admin
    config.homelab.contextforge.publicPort # Caddy: public MCP endpoint
    2586 # ntfy (ntfy.nix)
    4444 # ContextForge (contextforge.nix)
  ];
in
{
  users.users.${user} = {
    isNormalUser = true;
    inherit uid;
    # The NixOS default, stated because it is what keeps other users out of
    # the installed agents, their logins and ~/src.
    homeMode = "700";
    openssh.authorizedKeys.keys = config.homelab.admin.sshKeys;
    # Start the user's services at boot, without anyone logged in.
    linger = true;
    # Only on agent's PATH, not the admin's.
    packages = with pkgs; [
      # Context7's documentation lookup, for the find-docs skill in
      # ~/.claude/skills. From nixpkgs so it is pinned and updated with the
      # system, unlike upstream's `npx ctx7@latest`.
      ctx7
      curl
      pnpm
      uv
      ruff
      fnm
      gh
      tmux
      t3-pair
    ];
  };
  services.openssh.settings.AllowUsers = [ user ];

  # Agents build and fetch per-project toolchains; not a trusted user, so it
  # can't import unsigned paths or change substituters.
  nix.settings.allowed-users = [ user ];

  # The native installers drop generic-Linux binaries in ~/.local/bin.
  programs.nix-ld.enable = true;
  environment.localBinInPath = true;
  # ctx7 otherwise reports each command to context7.com.
  environment.variables.CTX7_TELEMETRY_DISABLED = "1";

  # Everything agent runs (SSH sessions, T3 Code and the agents it starts)
  # lives in this slice. Generous, but leaves the rest of the 64 GiB for the
  # services; over the limit the OOM killer picks from agent's processes
  # only. CPU needs no cap: under contention system.slice (every service,
  # the ContextForge container and Nix builds included) gets at least half.
  systemd.slices."user-${toString uid}" = {
    overrideStrategy = "asDropin";
    sliceConfig.MemoryMax = "56G";
  };

  # Internet only, as the microVM was: no home LAN, no WireGuard peers, no
  # IPv6 (the LAN's global prefix isn't known here), and none of ARBITER's
  # own services. Nix build users get the same, since agent can have the
  # daemon run a fixed-output derivation, which has the host's network.
  # `reject`, not `drop`, so clients fall back to IPv4 at once.
  networking.nftables.tables.t3-code = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority filter; policy accept;
        meta skuid ${toString uid} ct state new jump restrict
        meta skgid ${toString config.ids.gids.nixbld} ct state new jump restrict
      }
      chain restrict {
        oifname "lo" meta l4proto { tcp, udp } th dport { ${
          lib.concatMapStringsSep ", " toString hostPorts
        } } reject comment "t3-code: not the host's services"
        oifname "lo" return
        meta nfproto ipv6 reject comment "t3-code: IPv4 internet only"
        ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 } reject comment "t3-code: internet only"
      }
    '';
  };

  # T3 Code's server: one place for the desktop, web and mobile apps to run
  # and steer agents. It drives the provider CLIs on PATH with their own
  # logins. Skipped until t3 is installed. Devices pair with `t3-pair`.
  systemd.user.services.t3code = {
    description = "T3 Code server";
    wantedBy = [ "default.target" ];
    unitConfig = {
      ConditionUser = user;
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
      ExecStart = "${pkgs.bash}/bin/bash -lc 'mkdir -p ~/src && cd ~/src && exec t3 serve --no-browser --host 127.0.0.1 --port ${toString port} ~/src'";
      # Also covers exits after `t3 update`.
      Restart = "always";
      RestartSec = "30s";
    };
  };
  environment.etc."t3code/policy.json".text = builtins.toJSON t3Policy;

  # Port 443 only takes private sources (caddy.nix), so this is LAN and
  # WireGuard only. Pairing (`t3-pair`) is what admits a device. Always go
  # through Caddy: over plain HTTP the web app can't pair.
  services.caddy.virtualHosts.${host} = {
    useACMEHost = "wildcard";
    extraConfig = ''
      reverse_proxy 127.0.0.1:${toString port} {
        flush_interval -1
      }
    '';
  };
}
