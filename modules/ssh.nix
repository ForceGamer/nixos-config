{ config, ... }:
{
  services.openssh = {
    enable = true;
    # Only firewall opening in phase 1; tied to sshd so it closes if sshd goes.
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ config.homelab.admin.name ];
      X11Forwarding = false;
    };
  };
}
