{ pkgs, ... }:
{
  time.timeZone = "Europe/Oslo";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "no";

  services.journald.extraConfig = ''
    SystemMaxUse=1G
  '';

  # Drop the implicit defaults (perl, rsync, strace, ...) so everything on the
  # system is listed here on purpose.
  environment.defaultPackages = [ ];
  environment.systemPackages = with pkgs; [
    git
    htop
    smartmontools
  ];
}
