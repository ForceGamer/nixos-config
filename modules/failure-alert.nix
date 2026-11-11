# Failures of these units are otherwise silent; publish them to ntfy.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  url = "http://${config.services.ntfy-sh.settings.listen-http}/arbiter-alerts";
  watched = [
    "nixos-upgrade"
    # Fails only once the certificate is inside its renewal window (the last
    # third of its lifetime) and lego still can't renew, then daily until fixed.
    "acme-order-renew-wildcard"
    # Reports its own results; this covers the script itself crashing.
    "merge-test"
  ];
in
{
  systemd.services =
    lib.genAttrs watched (unit: {
      onFailure = [ "failure-alert@${unit}.service" ];
    })
    // {
      # One template for all of them; the instance is the failed unit's name.
      # They share the `upgrade-notifier` identity: same host, same topic, so
      # a second token would separate nothing.
      "failure-alert@" = {
        description = "Publish a failed %i to ntfy";
        wants = [ "ntfy-sh.service" ];
        after = [ "ntfy-sh.service" ];

        # The token goes to curl on stdin, never in argv where /proc would show it.
        scriptArgs = "%i";
        script = ''
          token=$(< "$CREDENTIALS_DIRECTORY/token")
          printf 'header = "Authorization: Bearer %s"\n' "$token" \
            | ${pkgs.curl}/bin/curl --fail --silent --show-error --config - \
                -H "Title: $1 failed on ${config.networking.hostName}" \
                -H "Priority: high" \
                -H "Tags: warning" \
                -d "Check: journalctl -u $1" \
                ${url}
        '';

        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
          LoadCredential = "token:${config.sops.secrets."ntfy/upgrade-notifier-token".path}";
          CapabilityBoundingSet = "";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateUsers = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectClock = true;
          ProtectHostname = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectProc = "invisible";
          ProcSubset = "pid";
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
          ];
          SystemCallArchitectures = "native";
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
          ];
          IPAddressAllow = "localhost";
          IPAddressDeny = "any";
        };
      };
    };
}
