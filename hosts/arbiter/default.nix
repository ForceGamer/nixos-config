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
    ../../modules/upgrade-alert.nix
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

  # The router forwards this same port from the WAN. Picked at random from the
  # ephemeral range; change it freely, Caddy and the firewall follow.
  homelab.contextforge.publicPort = 47231;

  # Names the generic PII patterns can't know, replaced in every tool result
  # before it reaches an AI client. `secret` names a sops key under
  # contextforge/ whose value is matched case-insensitively as whole words;
  # add one with ./add-pii.sh. `search` takes a raw Python regex instead, for
  # patterns that aren't secret.
  homelab.contextforge.pseudonyms = [
    {
      secret = "school-name";
      replace = "[SCHOOL]";
    }
    #{
    #  # ISO 8601 timestamps, e.g. 2026-11-09T00:00:00Z
    #  search = "\\b\\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\\d|3[01])T(?:[01]\\d|2[0-3]):[0-5]\\d:[0-5]\\d(?:\\.\\d+)?(?:Z|[+-](?:[01]\\d|2[0-3]):?[0-5]\\d)\\b";
    #  replace = "[TIMESTAMP]";
    #}
  ];

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
