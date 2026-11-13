# ContextForge (IBM's MCP gateway) as a PII-scrubbing proxy between MCP
# servers that return personal data (mail, notes, ...) and the AI clients that
# call them. Tool results pass through our search-and-replace rules (a global
# list plus one per upstream server, for names and patterns no generic filter
# can know), then the regex-based PII filter (hashes e-mails, phone numbers,
# IBANs, ...), then, for every tool not in `llm.excludeTools`, a local LLM on
# another host that looks for anything the first two missed.
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

  # Operator rules: groups of search-and-replace rules, each group global or
  # scoped to an email's sender/subject. Applied by the scoped_filter plugin
  # (modules/services/contextforge/), which is ours, not upstream's: the stock
  # regex_filter plugin has no scoping and silently drops a rule whose regex
  # doesn't compile. Ours fails at start, and the check below fails earlier.
  ruleType = lib.types.submodule (
    { config, ... }:
    {
      options = {
        secret = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "school-name";
          description = ''
            sops key under `contextforge/` whose value is the text to match,
            case-insensitively and as whole words. Add one with
            `./add-pii.sh`, which also escapes regex metacharacters. The
            secret is declared for you.
          '';
        };
        search = lib.mkOption {
          type = lib.types.str;
          description = ''
            Python regex matched in tool results and rendered prompts.
            Derived from `secret` when that is set; give it directly for
            patterns that aren't secret. Case-insensitive unless it opens
            with its own `(?...)` flags.
          '';
        };
        replace = lib.mkOption {
          type = lib.types.str;
          description = "Replacement text, e.g. a fixed label like [SCHOOL]; `\\1` keeps a group.";
        };
      };
      config.search = lib.mkIf (config.secret != null) (
        lib.mkDefault "\\b${placeholder config.secret}\\b"
      );
    }
  );
  optionalRegex = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
  };
  groupType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Label used in test output.";
      };
      server = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Name in `servers` this group belongs to; null for the global list.
          Set by the loader for files in a server's `rulesDir`.
        '';
      };
      when = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              from = optionalRegex // {
                description = "Regex the email's sender must match (any, if null).";
              };
              subject = optionalRegex // {
                description = "Regex the email's subject must match (any, if null).";
              };
            };
          }
        );
        default = null;
        description = ''
          null: global, always applied. Otherwise the group applies only to
          emails whose sender and subject match. Where the plugin can't tell
          what it is looking at, every group applies: scoping adds rules to
          a known context, it never removes protection from an unknown one.
        '';
      };
      rules = lib.mkOption {
        type = lib.types.listOf ruleType;
        default = [ ];
        description = "Applied in order, each on the previous one's output.";
      };
      examples = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              input = lib.mkOption { type = lib.types.str; };
              expect = lib.mkOption { type = lib.types.str; };
              from = optionalRegex // {
                description = "Sender to pretend the input came from.";
              };
              subject = optionalRegex // {
                description = "Subject to pretend the input had.";
              };
            };
          }
        );
        default = [ ];
        description = ''
          Synthetic inputs and the expected output after the whole rule set,
          run by `nix flake check`. Write a secret's key where its value
          would be; never real data.
        '';
      };
    };
  };

  # What the plugin receives. Secret-backed rules carry sops placeholders,
  # substituted when the template is rendered on the host.
  filterConfig = {
    # Gateway id → name; the plugin sees only the id.
    servers = lib.mapAttrs' (name: s: lib.nameValuePair s.id name) cfg.servers;
    groups = map (g: {
      inherit (g) name server;
      when = if g.when == null then null else { inherit (g.when) from subject; };
      rules = map (r: { inherit (r) search replace; }) g.rules;
    }) cfg.ruleGroups;
  };

  # One directory of rule files, in filename order.
  loadRules =
    dir:
    map (f: import (dir + "/${f}")) (
      lib.sort lib.lessThan (
        lib.filter (lib.hasSuffix ".nix") (builtins.attrNames (builtins.readDir dir))
      )
    );

  llm = cfg.llm;
  llmOn = llm.enable;
  secretsUsed = lib.unique (
    lib.concatMap (g: map (r: r.secret) (lib.filter (r: r.secret != null) g.rules)) cfg.ruleGroups
  );

  # Our plugins, mounted into the image's plugins/ package.
  pluginDir = pkgs.runCommand "contextforge-plugins" { } ''
    mkdir -p "$out"
    cp ${./contextforge/scoped_filter.py} "$out/scoped_filter.py"
    cp ${./contextforge/scoped_filter_core.py} "$out/scoped_filter_core.py"
    cp ${./contextforge/llm_detector.py} "$out/llm_detector.py"
    cp ${./contextforge/llm_detector_core.py} "$out/llm_detector_core.py"
    : > "$out/__init__.py"
  '';

  # Unit tests of the engine, then the host's examples against the rendered
  # config with every placeholder replaced by a stand-in for its secret:
  # SECRET_ plus the key in UPPER_SNAKE (`home-full` → SECRET_HOME_FULL).
  # Underscores keep one stand-in from matching inside another, which
  # hyphens would not, and the prefix keeps it from matching inside a label
  # like [HOME]. Wired into `nix flake check` from flake.nix.
  standIn = s: "SECRET_" + lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] s);
  check =
    pkgs.runCommand "contextforge-filter-check"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        config = builtins.replaceStrings (map placeholder secretsUsed) (map standIn secretsUsed) (
          builtins.toJSON filterConfig
        );
        examples = builtins.toJSON (
          lib.concatMap (
            g:
            map (e: {
              inherit (e)
                input
                expect
                from
                subject
                ;
              inherit (g) server;
              group = g.name;
            }) g.examples
          ) cfg.ruleGroups
        );
        passAsFile = [
          "config"
          "examples"
        ];
      }
      ''
        cp ${./contextforge/scoped_filter_core.py} scoped_filter_core.py
        cp ${./contextforge/test_scoped_filter.py} test_scoped_filter.py
        cp ${./contextforge/llm_detector_core.py} llm_detector_core.py
        cp ${./contextforge/test_llm_detector.py} test_llm_detector.py
        CONFIG="$configPath" EXAMPLES="$examplesPath" python3 -m unittest -v test_scoped_filter test_llm_detector
        touch "$out"
      '';
  plugins = {
    plugin_settings = {
      # A plugin error must fail the call, never let the raw result through.
      fail_on_plugin_error = true;
      parallel_execution_within_band = false;
      # One limit for every plugin (cpex 0.1.4 has no per-plugin timeout). The
      # LLM detector needs minutes for a long search; the regex plugins take
      # milliseconds, so the higher limit costs them nothing.
      plugin_timeout = if llmOn then llm.timeout + 15 else 30;
    };
    plugins = [
      {
        # Operator rules first, so their labels are never re-masked below.
        name = "ScopedFilter";
        kind = "plugins.custom.scoped_filter.ScopedFilterPlugin";
        hooks = postHooks;
        mode = "enforce";
        priority = 40;
        config = filterConfig;
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
    ]
    ++ lib.optional llmOn {
      # Last, so the model sees only what the regex plugins left: less to
      # send over the LAN, and less for it to read.
      name = "LlmDetector";
      kind = "plugins.custom.llm_detector.LlmDetectorPlugin";
      hooks = [ "tool_post_invoke" ];
      mode = "enforce";
      priority = 60;
      # No `conditions`: they can only allow-list, and every tool goes through
      # the model unless excluded. The plugin skips excluded tools itself.
      config = {
        inherit (llm) url model;
        exclude_tools = llm.excludeTools;
        request_timeout = llm.requestTimeout;
        budget_seconds = llm.timeout;
        num_ctx = llm.numCtx;
        keep_alive = llm.keepAlive;
        max_chars = llm.maxChars;
      };
    };
  };
in
{
  options.homelab.contextforge = {
    check = lib.mkOption {
      type = lib.types.package;
      default = check;
      readOnly = true;
      description = "Tests of the rule engine and of this host's rule examples; a flake check.";
    };
    rulesDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./pii";
      description = ''
        Directory of `*.nix` files, each one rule group, loaded into
        `ruleGroups` in filename order (so prefix them with numbers).
      '';
    };
    ruleGroups = lib.mkOption {
      type = lib.types.listOf groupType;
      default = [ ];
      description = ''
        Search-and-replace rule groups applied to tool results and rendered
        prompts before the generic PII filter, for names and patterns it
        can't know. Keep the names themselves out of the repo: use `secret`.
      '';
    };
    servers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            id = lib.mkOption {
              type = lib.types.str;
              example = "8f14e45fceea167a5a36dedd4bea2543";
              description = ''
                The upstream MCP server's id in the gateway (admin UI →
                Gateways). Not the virtual server's: in v1.1.0 a tool call's
                plugin context carries the upstream id only. A wrong id makes
                the server unknown, and an unknown server gets every server's
                rules, so a mistake filters more, never less.
              '';
            };
            rulesDir = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = ''
                Rule files for this server only, in the same format as
                `rulesDir`. They add to the global list, never replace it.
              '';
            };
          };
        }
      );
      default = { };
      description = "Upstream MCP servers with rule groups of their own, by a name of your choice.";
    };
    llm = {
      enable = lib.mkEnableOption "the local-LLM detector behind the regex plugins";
      url = lib.mkOption {
        type = lib.types.str;
        example = "http://templar.lan:11434";
        description = "Ollama base URL, reachable from inside the container.";
      };
      model = lib.mkOption {
        type = lib.types.str;
        example = "qwen3.6:35b-a3b";
        description = "Ollama model name (must be pulled on the LLM host).";
      };
      excludeTools = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Tools that skip the model, exactly as the client calls them (the
          gateway logs each as "Invoking tool: <name>"). Every other tool's
          result goes through it, so while the LLM host is off every tool
          not listed here fails.
        '';
      };
      timeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = ''
          Seconds one tool call may spend in the model, all emails together.
          Past it the call fails. Also sets the gateway's plugin timeout
          (this plus 15 s).
        '';
      };
      requestTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 120;
        description = "Seconds for one Ollama request (one email, or one part of a long one).";
      };
      numCtx = lib.mkOption {
        type = lib.types.ints.positive;
        default = 16384;
        description = "Ollama context length per request.";
      };
      keepAlive = lib.mkOption {
        type = lib.types.str;
        default = "30m";
        description = "How long Ollama keeps the model loaded after a request.";
      };
      maxChars = lib.mkOption {
        type = lib.types.ints.positive;
        default = 12000;
        description = "Longest text per request; a longer email is split at line breaks.";
      };
    };
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
  };

  config = {
    # Global groups first, then each server's (by name); within a directory,
    # filename order.
    homelab.contextforge.ruleGroups =
      lib.optionals (cfg.rulesDir != null) (loadRules cfg.rulesDir)
      ++ lib.concatLists (
        lib.mapAttrsToList (
          name: s:
          lib.optionals (s.rulesDir != null) (map (g: g // { server = name; }) (loadRules s.rulesDir))
        ) cfg.servers
      );

    assertions = [
      {
        assertion =
          let
            ids = lib.mapAttrsToList (_: s: s.id) cfg.servers;
          in
          lib.length ids == lib.length (lib.unique ids);
        message = "homelab.contextforge.servers: two servers share an id.";
      }
      {
        assertion = llm.timeout > llm.requestTimeout;
        message = "homelab.contextforge.llm.timeout must exceed llm.requestTimeout.";
      }
    ];

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
    # rule secrets are whatever the host's rule files name.
    sops.secrets = lib.genAttrs (
      [
        "contextforge/jwt-secret-key"
        "contextforge/auth-encryption-secret"
        "contextforge/admin-password"
        "contextforge/default-user-password"
      ]
      ++ map (s: "contextforge/${s}") secretsUsed
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
        # Our plugin, importable as plugins.custom.scoped_filter next to the
        # image's own plugins/ package.
        "${pluginDir}:/app/plugins/custom:ro"
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
