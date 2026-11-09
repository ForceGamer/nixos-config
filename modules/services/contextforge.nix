# ContextForge (IBM's MCP gateway) as a PII-scrubbing proxy between MCP
# servers that return personal data (mail, notes, ...) and the AI clients that
# call them. Tool results pass through two plugins before leaving the gateway:
# the regex-based PII filter (hashes e-mails, phone numbers, IBANs, ...) and a
# search-and-replace list for names that no generic pattern can catch.
#
# Two faces, both on this host:
#   https://mcp-admin.<domain>        LAN and WireGuard only (admin UI and API).
#   https://tun.<domain>:<publicPort> Internet; only /servers/* with a bearer
#                                     header is proxied. Everything else is
#                                     dropped without a response, and clients
#                                     without the hostname get a decoy cert.
# Clients authenticate with a ContextForge bearer token; fail2ban bans sources
# that keep hitting the public port without one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.contextforge;
  domain = config.homelab.domain;
  adminHost = "mcp-admin.${domain}";
  # Shares the WireGuard name: already in public DNS on the WAN IP via DDNS,
  # so no new record hints at a web service.
  publicHost = "tun.${domain}";
  publicPort = cfg.publicPort;
  decoy = config.homelab.caddy.decoyCert;
  upstream = "127.0.0.1:4444";
  user = "contextforge";
  home = "/var/lib/${user}";
  unit = "podman-${user}.service";
  accessLog = "${config.services.caddy.logDir}/access-${publicHost}.log";

  secret = name: config.sops.secrets."contextforge/${name}";
  placeholder = name: config.sops.placeholder."contextforge/${name}";

  # Plugin pipeline. Only *post* hooks: the AI's own inputs need no scrubbing,
  # and masking tool arguments would break lookups (e.g. search by sender).
  # Resources have no PII hook in these plugins, so virtual servers must expose
  # tools only (see CONTEXTFORGE.md).
  postHooks = [
    "tool_post_invoke"
    "prompt_post_fetch"
  ];
  plugins = {
    plugin_settings = {
      # A plugin error must fail the call, never let the raw result through.
      fail_on_plugin_error = true;
      parallel_execution_within_band = false;
      plugin_timeout = 30;
    };
    plugins = [
      {
        # Fixed names first, so their labels are never re-masked below.
        name = "Pseudonyms";
        kind = "plugins.regex_filter.search_replace.SearchReplacePlugin";
        hooks = postHooks;
        mode = "enforce";
        priority = 40;
        config.words = cfg.pseudonyms;
      }
      {
        name = "PIIFilter";
        kind = "cpex_pii_filter.PIIFilterPlugin";
        hooks = postHooks;
        mode = "enforce";
        priority = 50;
        config = {
          detect_email = true;
          detect_phone = true; # US and +<cc> formats; Norwegian ones below
          detect_credit_card = true;
          detect_bank_account = true; # IBAN and "account <digits>"
          detect_date_of_birth = true;
          # Off: US/NL-only formats or English keyword matches that would only
          # add false positives here.
          detect_ssn = false;
          detect_bsn = false;
          detect_ip_address = false;
          detect_passport = false;
          detect_driver_license = false;
          detect_medical_record = false;
          # "hash" is the only consistent pseudonym: the same value becomes the
          # same [HASH:...] token, so the model can still tell two people apart.
          # The salt is random per process (GUNICORN_WORKERS=1 keeps it to one),
          # so tokens are stable until the gateway restarts. "tokenize" is a
          # fresh random token per occurrence, "redact" a fixed string.
          default_mask_strategy = "hash";
          redaction_text = "[REDACTED]";
          block_on_detection = false;
          # Types and counts only, never the values.
          log_detections = true;
          include_detection_details = false;
          custom_patterns = [
            {
              # DDMMYY + 5 digits, optional space; D-numbers add 40 to the day.
              pattern = "\\b(?:[04][1-9]|[1256]\\d|[37][01])(?:0[1-9]|1[0-2])\\d{2} ?\\d{5}\\b";
              description = "Norwegian national identity number";
            }
            {
              # +47 / 0047 with any 8 digits, or a bare 8-digit mobile (4x/9x).
              pattern = "(?:\\+|00)47 ?\\d{2} ?\\d{2} ?\\d{2} ?\\d{2}\\b|\\b[49]\\d{7}\\b|\\b[49]\\d{2} \\d{2} \\d{3}\\b";
              description = "Norwegian phone number";
            }
          ];
          whitelist_patterns = [ ];
        };
      }
    ];
  };
in
{
  options.homelab.contextforge = {
    publicPort = lib.mkOption {
      type = lib.types.port;
      default = 8443;
      description = ''
        TCP port Caddy serves the MCP endpoint on, and the port the router
        forwards to. Non-standard on purpose: mass scanners rarely look
        beyond the usual HTTPS ports, so fewer probes reach the host at all.
      '';
    };
    image = lib.mkOption {
      type = lib.types.str;
      # v1.1.0 (2026-10-20). The digest is the multi-arch index; podman picks
      # amd64. Bump by hand: `skopeo inspect docker://ghcr.io/ibm/mcp-context-forge:vX.Y.Z`.
      default = "ghcr.io/ibm/mcp-context-forge@sha256:7eb21fb9a8070df59435c03c76c40d8c71230c55ba89f884f2482d2cc81cff1c";
      description = "ContextForge image, pinned by digest.";
    };
    pseudonyms = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule (
          { config, ... }:
          {
            options = {
              secret = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "school-name";
                description = ''
                  sops key under `contextforge/` whose value is the text to
                  match, case-insensitively and as whole words. Add one with
                  `./add-pii.sh`, which also escapes regex metacharacters.
                  The secret is declared for you.
                '';
              };
              search = lib.mkOption {
                type = lib.types.str;
                description = ''
                  Python regex matched in tool results and rendered prompts.
                  Derived from `secret` when that is set; give it directly for
                  patterns that aren't secret.
                '';
              };
              replace = lib.mkOption {
                type = lib.types.str;
                description = "Replacement text, e.g. a fixed label like [SCHOOL].";
              };
            };
            config.search = lib.mkIf (config.secret != null) (
              lib.mkDefault "(?i)\\b${placeholder config.secret}\\b"
            );
          }
        )
      );
      default = [ ];
      description = ''
        Search-and-replace rules applied to tool results before the generic
        PII filter. For names and places the regex patterns can't know.
        Keep the names themselves out of the repo: use `secret`.
      '';
    };
  };

  config = {
    virtualisation.podman = {
      enable = true;
      autoPrune.enable = true;
    };
    virtualisation.oci-containers.backend = "podman";

    # Rootless: the container runs under this user, with its own subuid range.
    # Static uid: the oci-containers module needs it for /run/user/<uid>.
    users.users.${user} = {
      isSystemUser = true;
      uid = 380;
      group = user;
      home = home;
      createHome = true;
      autoSubUidGidRange = true;
      # user@380.service from boot, so podman has its runtime dir.
      linger = true;
    };
    users.groups.${user}.gid = 380;

    systemd.tmpfiles.rules = [
      "d ${home}/data 0700 ${user} ${user} -"
    ];

    # Root-only; they reach the container through the templates below. The
    # pseudonym secrets are whatever the host's entries name.
    sops.secrets = lib.genAttrs (
      [
        "contextforge/jwt-secret-key"
        "contextforge/auth-encryption-secret"
        "contextforge/admin-password"
        "contextforge/default-user-password"
      ]
      ++ map (p: "contextforge/${p.secret}") (lib.filter (p: p.secret != null) cfg.pseudonyms)
    ) (_: { });

    # Secrets reach the container as an env file podman reads as this user.
    # DEFAULT_USER_PASSWORD is the initial password for accounts created in
    # the UI. Nobody gets one here (registration is off), but the gateway
    # validates it at start and its built-in default fails the 12-character
    # minimum.
    sops.templates."contextforge.env" = {
      owner = user;
      content = ''
        JWT_SECRET_KEY=${placeholder "jwt-secret-key"}
        AUTH_ENCRYPTION_SECRET=${placeholder "auth-encryption-secret"}
        PLATFORM_ADMIN_PASSWORD=${placeholder "admin-password"}
        DEFAULT_USER_PASSWORD=${placeholder "default-user-password"}
      '';
      restartUnits = [ unit ];
    };

    # The plugin config is a sops template too, so pseudonym rules can carry
    # names from sops without putting them in the store. JSON is valid YAML.
    sops.templates."contextforge-plugins.yaml" = {
      owner = user;
      content = builtins.toJSON plugins;
      restartUnits = [ unit ];
    };

    virtualisation.oci-containers.containers.${user} = {
      image = cfg.image;
      podman.user = user;
      ports = [ "${upstream}:4444" ];
      volumes = [
        "${home}/data:/data"
        "${config.sops.templates."contextforge-plugins.yaml".path}:/etc/mcpgateway/plugins.yaml:ro"
      ];
      environmentFiles = [ config.sops.templates."contextforge.env".path ];
      environment = {
        HOST = "0.0.0.0"; # inside the container; published on loopback only
        PORT = "4444";
        ENVIRONMENT = "production";
        DATABASE_URL = "sqlite:////data/mcp.db";
        APP_DOMAIN = "https://${adminHost}";
        ALLOWED_ORIGINS = builtins.toJSON [ "https://${adminHost}" ];
        SECURE_COOKIES = "true";
        # Authentication everywhere; the admin account is created at first start.
        AUTH_REQUIRED = "true";
        MCP_CLIENT_AUTH_ENABLED = "true";
        EMAIL_AUTH_ENABLED = "true";
        PUBLIC_REGISTRATION_ENABLED = "false";
        API_ALLOW_BASIC_AUTH = "false";
        DOCS_ALLOW_BASIC_AUTH = "false";
        REQUIRE_TOKEN_EXPIRATION = "true";
        PLATFORM_ADMIN_EMAIL = "admin@${domain}";
        PLATFORM_ADMIN_FULL_NAME = "Administrator";
        # The UI and admin API are reachable through the LAN-only vhost.
        MCPGATEWAY_UI_ENABLED = "true";
        MCPGATEWAY_ADMIN_API_ENABLED = "true";
        # Surface we don't use.
        MCPGATEWAY_A2A_ENABLED = "false";
        MCPGATEWAY_CATALOG_ENABLED = "false";
        MCPGATEWAY_BULK_IMPORT_ENABLED = "false";
        LLMCHAT_ENABLED = "false";
        PLUGINS_ENABLED = "true";
        PLUGINS_CONFIG_FILE = "/etc/mcpgateway/plugins.yaml";
        # One worker: one hash salt, so pseudonyms stay consistent (see above).
        GUNICORN_WORKERS = "1";
        LOG_LEVEL = "INFO";
        LOG_TO_FILE = "false";
      };
      extraOptions = [
        # Map this host user onto the image's uid, so /data stays writable
        # without chown games.
        "--userns=keep-id:uid=10001,gid=10001"
        "--read-only"
        "--tmpfs=/tmp:rw,nosuid,nodev,noexec,size=64m"
        "--cap-drop=ALL"
        "--security-opt=no-new-privileges"
        "--pids-limit=512"
      ];
    };

    # Admin side: full gateway, LAN and WireGuard only (port 443 is
    # private-source-only in caddy.nix).
    services.caddy.virtualHosts.${adminHost} = {
      useACMEHost = "wildcard";
      extraConfig = ''
        reverse_proxy ${upstream} {
          flush_interval -1
        }
      '';
    };

    # Public side: only the MCP endpoints of virtual servers, and only for
    # requests that carry a bearer header at all. Anything else is dropped
    # with `abort` (connection closed, no bytes), so a probe learns nothing,
    # not even that an HTTP server answers. The gateway still validates the
    # token; Caddy only checks that one is present. Caddy logs aborted
    # requests with status 0, which the jail below counts.
    services.caddy.virtualHosts."${publicHost}:${toString publicPort}" = {
      useACMEHost = "wildcard";
      logFormat = ''
        output file ${accessLog}
      '';
      extraConfig = ''
        request_body {
          max_size 2MB
        }
        header -Server
        @noauth not header Authorization Bearer*
        handle @noauth {
          abort
        }
        @mcp path /servers/*
        handle @mcp {
          reverse_proxy ${upstream} {
            flush_interval -1
          }
        }
        handle {
          abort
        }
      '';
    };

    # Catch-all on the same port for any other or no SNI: presents the decoy
    # certificate instead of the wildcard and drops the request. Shares the
    # access log so the jail sees these probes too.
    services.caddy.virtualHosts.":${toString publicPort}" = {
      logFormat = ''
        output file ${accessLog}
      '';
      extraConfig = ''
        tls ${decoy}/cert.pem ${decoy}/key.pem
        abort
      '';
    };

    # The one port besides WireGuard that the router forwards.
    networking.firewall.allowedTCPPorts = [ publicPort ];

    # Repeated junk on the public port from one address: scanner or a
    # misconfigured client. 0 = dropped by Caddy (no bearer header, wrong path,
    # unknown SNI), 421 = Host didn't match the SNI, 401/403/404 = the gateway
    # rejected it. Private sources are in fail2ban's ignoreIP.
    services.fail2ban.jails.contextforge = {
      filter.Definition = {
        failregex = ''^.*"request":\{"remote_ip":"<HOST>",.*"status":(?:0|401|403|404|421),'';
        datepattern = ''^.*"ts":{EPOCH}'';
      };
      settings = {
        logpath = accessLog;
        backend = "auto";
        maxretry = 5;
        findtime = "10m";
        # Drop the source everywhere, not just on the public port.
        banaction = "%(banaction_allports)s";
      };
    };

    # Caddy must create the access log before fail2ban looks for it.
    systemd.services.fail2ban = {
      after = [ "caddy.service" ];
      wants = [ "caddy.service" ];
    };
  };
}
