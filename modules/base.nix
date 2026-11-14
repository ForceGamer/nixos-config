{ pkgs, ... }:
{
  time.timeZone = "Europe/Oslo";
  # English, but with day-month dates and other non-US formats.
  i18n.defaultLocale = "en_GB.UTF-8";
  console.keyMap = "no";

  services.journald.settings.Journal.SystemMaxUse = "1G";

  # Drop the implicit defaults (perl, rsync, strace, ...) so everything on the
  # system is listed here on purpose.
  environment.defaultPackages = [ ];
  environment.systemPackages = with pkgs; [
    git
    htop
    smartmontools
  ];
}
