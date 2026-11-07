{ config, lib, ... }:
let
  cfg = config.homelab.admin;
in
{
  # One place to set the admin identity; ssh.nix and nix.nix read it too.
  options.homelab.admin = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Login name of the single admin account.";
    };
    sshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "SSH public keys allowed to log in as the admin.";
    };
  };

  config = {
    users.mutableUsers = false;

    users.users.root.hashedPassword = "!";

    users.users.${cfg.name} = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = cfg.sshKeys;
    };

    security.sudo = {
      execWheelOnly = true;
      # SSH is key-only and the admin has no password, so the key is the
      # credential. Revisit once secrets management exists.
      wheelNeedsPassword = false;
    };
  };
}
