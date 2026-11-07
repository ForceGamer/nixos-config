# A failed auto-upgrade is otherwise silent; publish it to ntfy.
{ config, pkgs, ... }:
let
  url = "http://${config.services.ntfy-sh.settings.listen-http}/arbiter-alerts";
in
{
  systemd.services.nixos-upgrade.unitConfig.OnFailure = [ "upgrade-alert.service" ];

  systemd.services.upgrade-alert = {
    description = "Publish a failed nixos-upgrade to ntfy";
    wants = [ "ntfy-sh.service" ];
    after = [ "ntfy-sh.service" ];

    # The token goes to curl on stdin, never in argv where /proc would show it.
    script = ''
      token=$(< "$CREDENTIALS_DIRECTORY/token")
      printf 'header = "Authorization: Bearer %s"\n' "$token" \
        | ${pkgs.curl}/bin/curl --fail --silent --show-error --config - \
            -H "Title: nixos-upgrade failed on ${config.networking.hostName}" \
            -H "Priority: high" \
            -H "Tags: warning" \
            -d "Check: journalctl -u nixos-upgrade" \
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
}
