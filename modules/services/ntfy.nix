{ config, lib, ... }:
let
  secret = name: config.sops.placeholder."ntfy/${name}";
in
{
  services.ntfy-sh = {
    enable = true;
    settings = {
      # Placeholder until ntfy is exposed through the reverse proxy. It must then
      # be the URL clients use, since iOS push derives its topics from it.
      base-url = "http://localhost:2586";
      listen-http = "127.0.0.1:2586";
      auth-default-access = "deny-all";
      # Every ntfy identity and its access lives in this file, so it is the one
      # place to audit. Users and tokens are secrets and come from sops below.
      auth-access = [ "upgrade-notifier:arbiter-alerts:write-only" ];
    };
    environmentFile = config.sops.templates."ntfy.env".path;
  };

  sops.secrets."ntfy/upgrade-notifier-hash" = { };
  sops.secrets."ntfy/upgrade-notifier-token" = { };

  # Single quotes stop systemd from touching the `$` in bcrypt hashes.
  sops.templates."ntfy.env" = {
    content = ''
      NTFY_AUTH_USERS='upgrade-notifier:${secret "upgrade-notifier-hash"}:user'
      NTFY_AUTH_TOKENS='upgrade-notifier:${secret "upgrade-notifier-token"}:upgrade-alert'
    '';
    restartUnits = [ "ntfy-sh.service" ];
  };

  # Tighten the upstream module's sandbox.
  systemd.services.ntfy-sh.serviceConfig = {
    # Port 2586 is unprivileged, so no capabilities are needed.
    AmbientCapabilities = lib.mkForce "";
    CapabilityBoundingSet = lib.mkForce "";
    ProtectSystem = lib.mkForce "strict";
    ProtectHome = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    PrivateUsers = true;
    LockPersonality = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
    ];
    UMask = "0077";
    # Localhost-only for now. Opening this up (iOS upstream, reverse proxy on
    # another host) is part of exposing ntfy.
    IPAddressAllow = "localhost";
    IPAddressDeny = "any";
  };
}
