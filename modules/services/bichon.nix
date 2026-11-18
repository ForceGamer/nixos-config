# Bichon: archives the mailboxes over IMAP and indexes them for search. Its
# own scheduler backs the archive up, incrementally, to a directory on the NAS
# (NFS); restic takes it from there to B2 (not built yet). IMAP accounts and
# the backup target, schedule and retention are set in the web UI and live in
# Bichon's database; see BICHON.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.bichon;
  host = "bichon.${config.homelab.domain}";
  port = 15630;
  stateDir = "/var/lib/bichon";
  # Bichon's backup target. The mount sits in a directory only bichon can
  # enter, so no other local user reaches the share through it.
  nasParent = "/mnt/bichon";
  nasDir = "${nasParent}/nas";
  # Each backup run, changed or not, ends by rewriting <prefix>/v1/meta/LATEST.
  maxBackupAgeHours = 48;

  # Upstream releases several times a week and nixpkgs trails; 2.3.1 fixed a
  # crash recovery that could poison a backup object. nixpkgs' recipe, newer
  # source, used only while nixpkgs is older: the weekly upgrade moves to
  # nixpkgs' build by itself once it catches up; then delete this. The web
  # UI's pnpm lockfile is unchanged since 2.2.0, so the recipe's pnpmDeps hash
  # still fits; a bump that changes it must override pnpmDeps too.
  pinned = "2.4.3";
  package =
    if lib.versionAtLeast pkgs.bichon.version pinned then
      pkgs.bichon
    else
      pkgs.bichon.overrideAttrs (
        finalAttrs: _: {
          version = pinned;
          src = pkgs.fetchFromGitHub {
            owner = "rustmailer";
            repo = "bichon";
            tag = finalAttrs.version;
            hash = "sha256-Bg+3wc9Xpu9scOBryZslkYrgfHU7VWgbxB/SeqItDAg=";
          };
          cargoHash = "sha256-Iy3wFQe+PnK09q7mM9du57uqvVfDx2yd0j62GihiAs0=";
        }
      );
in
{
  options.homelab.bichon.backupNfs = lib.mkOption {
    type = lib.types.str;
    example = "192.168.1.10:/volume1/Email";
    description = "NFS export that Bichon's backups are written to.";
  };

  config = {
    users.users.bichon = {
      isSystemUser = true;
      group = "bichon";
    };
    users.groups.bichon = { };

    # For `bichon-admin restore` (BICHON.md), from the same build as the server.
    environment.systemPackages = [ package ];

    # Encrypts the IMAP passwords Bichon stores. Losing it means re-entering
    # them, not losing mail (the archive itself isn't encrypted).
    sops.secrets."bichon/encrypt-password" = { };

    systemd.tmpfiles.settings.bichon.${nasParent}.d = {
      user = "bichon";
      group = "bichon";
      mode = "0700";
    };

    # Mounted on first use, so a NAS that is down delays nothing at boot. A
    # backup run waits for it (a hard mount, the default: a write is never
    # silently dropped), and the daily check below reports it. Upstream warns
    # against live data on NFS; only the backups go here.
    fileSystems.${nasDir} = {
      device = cfg.backupNfs;
      fsType = "nfs";
      options = [
        "nfsvers=4"
        "noauto"
        "x-systemd.automount"
        "x-systemd.idle-timeout=10min"
        "x-systemd.mount-timeout=30s"
        "nosuid"
        "nodev"
        "noexec"
      ];
    };

    systemd.services.bichon = {
      description = "Bichon e-mail archiver";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment = {
        BICHON_ROOT_DIR = stateDir;
        BICHON_BIND_IP = "127.0.0.1";
        BICHON_HTTP_PORT = toString port;
        BICHON_PUBLIC_URL = "https://${host}";
        # Unset means every origin is allowed.
        BICHON_CORS_ORIGINS = "https://${host}";
        # The code reads this before the password option, which always has a
        # built-in default (2.4.3, utils/encrypt.rs; its --help claims the
        # opposite precedence).
        BICHON_ENCRYPT_PASSWORD_FILE = "%d/encrypt-password";
        BICHON_ANSI_LOGS = "false";
      };
      serviceConfig = {
        ExecStart = lib.getExe package;
        User = "bichon";
        Group = "bichon";
        StateDirectory = "bichon";
        StateDirectoryMode = "0700";
        LoadCredential = "encrypt-password:${config.sops.secrets."bichon/encrypt-password".path}";
        Restart = "on-failure";
        UMask = "0077";
        ReadWritePaths = [ nasParent ];
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
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
          "AF_UNIX"
        ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        # IMAP servers anywhere on the internet; DNS through resolved on
        # localhost. The NAS needs no exception: NFS traffic comes from the
        # kernel, not from this cgroup.
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
    };

    # Bichon's backups run inside the server, so systemd never sees one fail.
    # This does, and failure-alert reports it on ntfy; also when the NAS is
    # unreachable or no backup has been set up yet.
    systemd.services.bichon-backup-check = {
      description = "Check that Bichon backed up to the NAS recently";
      script = ''
        latest=$(${pkgs.findutils}/bin/find ${nasDir} -maxdepth 5 \
          -path '*/v1/meta/LATEST' -mmin -${toString (maxBackupAgeHours * 60)} -print -quit)
        if [ -z "$latest" ]; then
          echo "No Bichon restore point newer than ${toString maxBackupAgeHours} h in ${nasDir}" >&2
          exit 1
        fi
        echo "Newest restore point: $latest"
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "bichon";
        Group = "bichon";
        # A hard NFS mount waits for the NAS indefinitely.
        TimeoutStartSec = "5min";
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = "none";
        IPAddressDeny = "any";
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };
    systemd.timers.bichon-backup-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Bichon's default schedule is 03:00.
        OnCalendar = "09:00";
        Persistent = true;
      };
    };

    services.caddy.virtualHosts.${host} = {
      useACMEHost = "wildcard";
      extraConfig = "reverse_proxy 127.0.0.1:${toString port}";
    };
  };
}
