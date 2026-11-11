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

  # Names and patterns the generic PII filter can't know, replaced in every
  # tool result before it reaches an AI client. One file per rule group in
  # pii/, applied in filename order; a group can be scoped to a sender or
  # subject (see CONTEXTFORGE.md). Add a name with ./add-pii.sh.
  homelab.contextforge.rulesDir = ./pii;

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
