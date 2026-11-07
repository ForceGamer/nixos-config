{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../modules/base.nix
    ../../modules/nix.nix
    ../../modules/users.nix
    ../../modules/ssh.nix
    ../../modules/networking.nix
    ../../modules/auto-upgrade.nix
    ../../modules/upgrade-alert.nix
    ../../modules/services/ntfy.nix
  ];

  networking.hostName = "arbiter";

  # Encrypted with sops; decrypted at activation with the SSH host key.
  sops.defaultSopsFile = ./secrets.yaml;

  homelab.admin = {
    name = "admin";
    sshKeys = [ "<ADMIN_SSH_PUBKEY>" ];
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
