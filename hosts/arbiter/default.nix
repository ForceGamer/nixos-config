{ config, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../modules/base.nix
    ../../modules/nix.nix
    ../../modules/users.nix
    ../../modules/ssh.nix
    ../../modules/networking.nix
    ../../modules/nvidia.nix
    ../../modules/auto-upgrade.nix
    ../../modules/failure-alert.nix
    ../../modules/merge-test
    ../../modules/wireguard.nix
    ../../modules/claude-vm.nix
    ../../modules/fail2ban.nix
    ../../modules/services/caddy.nix
    ../../modules/services/ntfy.nix
    ../../modules/services/contextforge.nix
  ];

  networking.hostName = "arbiter";

  # Encrypted with sops; decrypted at activation with the SSH host key.
  sops.defaultSopsFile = ./secrets.yaml;

  # DNS at Cloudflare. The apex and *.gameforce.me point at ARBITER's LAN
  # address; only tun.gameforce.me (DDNS, WireGuard) points at the WAN.
  homelab.domain = "gameforce.me";

  # The router forwards WAN 443 here (claude.ai can't reach other ports). Any
  # free port works; Caddy and the firewall follow.
  homelab.contextforge.publicPort = 47231;

  # Names and patterns the generic detectors can't know, replaced in every
  # tool result before it reaches an AI client. One file per rule group in
  # pii/, applied in filename order; a group can be scoped to a sender or
  # subject (see CONTEXTFORGE.md). Add a name with ./add-pii.sh. This is the
  # global list: people, links, identifiers, amounts, for every server.
  homelab.contextforge.rulesDir = ./pii;

  # E-mail addresses of organisations stay readable (noreply@, support@, ...
  # and these domains); addresses at your own domains are always hashed:
  # homelab.domain plus the one in sops.
  homelab.contextforge.allowDomainsFile = ./pii/allow-domains.txt;
  homelab.contextforge.ownDomainSecrets = [ "own-domain" ];

  # Upstream MCP servers by their gateway id (admin UI → Gateways), each with
  # rules for it alone, run after the global list. Fastmail's are the
  # per-sender groups (one shop or service each).
  homelab.contextforge.servers.fastmail = {
    id = "95002935e45f4c67a039d2579cc06b4d";
    rulesDir = ./pii/servers/fastmail;
  };

  # Local model on TEMPLAR as the last filter, for every tool. Fail closed:
  # while TEMPLAR or its Ollama is unreachable, every tool call fails. The
  # address must stay TEMPLAR's: reserve it in UniFi, or a new lease breaks
  # every tool call.
  homelab.contextforge.llm = {
    enable = true;
    url = "http://192.168.1.145:11434";
    # A personal upload on ollama.com, not the official library; unpinned.
    model = "oamazonasgabriel/qwen3.6-35b-a3b:q4-24gbGPU";
  };

  # Another LAN device behind the wildcard certificate; like every Caddy site
  # on 443, reachable from the LAN and WireGuard only. Its address must stay
  # put: reserve it in UniFi. The device serves HTTPS with a self-signed
  # certificate, so the hop from here is encrypted but not authenticated.
  # Caddy (since 2.11) sends the upstream's own address as Host on HTTPS
  # upstreams, so the device sees requests as if browsed directly.
  services.caddy.virtualHosts."files.${config.homelab.domain}" = {
    useACMEHost = "wildcard";
    extraConfig = ''
      reverse_proxy https://192.168.1.152:9443 {
        transport http {
          tls_insecure_skip_verify
        }
      }
    '';
  };

  homelab.admin = {
    name = "admin";
    sshKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEipz/4NceWoq5jFiUcOAeNWm+ZRRX02GmDIEw10I2IA templar"
    ];
  };

  boot.loader = {
    systemd-boot = {
      enable = true;
      configurationLimit = 10;
    };
    efi.canTouchEfiVariables = true;
  };

  hardware.cpu.amd.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  # Set once for the first install on 26.05. Never change it afterwards, even
  # when nixpkgs moves to a newer release.
  system.stateVersion = "26.05";
}
