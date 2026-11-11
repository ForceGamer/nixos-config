{ config, lib, ... }:
let
  secret = name: config.sops.placeholder."ntfy/${name}";
  host = "ntfy.${config.homelab.domain}";
  listen = "127.0.0.1:2586";
in
{
  services.ntfy-sh = {
    enable = true;
    settings = {
      # The URL clients use; iOS push derives its topics from it.
      base-url = "https://${host}";
      listen-http = listen;
      # Rate-limit by the client address Caddy puts in X-Forwarded-For, not by
      # Caddy's own 127.0.0.1. Caddy overwrites any client-supplied value.
      behind-proxy = true;
      auth-default-access = "deny-all";
      # Every ntfy identity and its access lives in this file, so it is the one
      # place to audit. Users and tokens are secrets and come from sops below.
      auth-access = [
        "upgrade-notifier:arbiter-alerts:write-only"
        "phone:arbiter-alerts:read-only"
      ];
      # iOS suspends the app, so only Apple push can wake it, and only ntfy.sh
      # can send that for the ntfy app. Per message, ntfy.sh gets the message
      # id and a SHA-256 of base-url/topic, never the content; the phone then
      # fetches the message from here, over the LAN or WireGuard.
      upstream-base-url = "https://ntfy.sh";
    };
    environmentFile = config.sops.templates."ntfy.env".path;
  };

  sops.secrets."ntfy/upgrade-notifier-hash" = { };
  sops.secrets."ntfy/upgrade-notifier-token" = { };
  # The iOS app logs in with username and password; it has no token field.
  sops.secrets."ntfy/phone-hash" = { };

  # Single quotes stop systemd from touching the `$` in bcrypt hashes.
  sops.templates."ntfy.env" = {
    content = ''
      NTFY_AUTH_USERS='upgrade-notifier:${secret "upgrade-notifier-hash"}:user,phone:${secret "phone-hash"}:user'
      NTFY_AUTH_TOKENS='upgrade-notifier:${secret "upgrade-notifier-token"}:upgrade-alert'
    '';
    restartUnits = [ "ntfy-sh.service" ];
  };

  services.caddy.virtualHosts.${host} = {
    useACMEHost = "wildcard";
    extraConfig = "reverse_proxy ${listen}";
    # ntfy accepts credentials as a query parameter (the web app uses it for
    # subscriptions); keep them out of the access log. Caddy already redacts
    # the Authorization header.
    logFormat = ''
      output file ${config.services.caddy.logDir}/access-${host}.log
      format filter {
        request>uri query {
          delete auth
          delete authorization
        }
      }
    '';
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
    # Clients reach ntfy only through Caddy on this host. The one outbound
    # connection is the poll request to ntfy.sh, whose addresses can't be
    # pinned here, so the internet is open and everything private is not
    # (an allow entry wins over a deny entry; anything unlisted is allowed).
    IPAddressAllow = "localhost";
    IPAddressDeny = [
      "10.0.0.0/8"
      "172.16.0.0/12"
      "192.168.0.0/16"
      "100.64.0.0/10"
      "link-local"
      "fc00::/7"
    ];
  };
}
