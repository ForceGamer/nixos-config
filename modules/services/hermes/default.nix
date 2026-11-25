# Hermes Agent (Nous Research): an always-on assistant with long-term memory
# (Hindsight, hindsight.nix), web search (SearXNG, searxng.nix) and a headless
# browser. Reached by e-mail (a dedicated Gmail account, whitelisted senders),
# Hermes Desktop over SSH as `hermes`, and the dashboard at hermes.<domain>.
# Models: Claude Max and Google AI Pro through their CLIs (plugins below),
# ChatGPT and Grok through Hermes' own OAuth, and Ollama on TEMPLAR. The
# logins are made by hand as `hermes` and live in its state; see HERMES.md.
#
# Upstream's NixOS module (flake input hermes-agent) runs the gateway and the
# dashboard; this file pins its package and plugins, adds the hardening it
# lacks, and confines the `hermes` user to the internet like `agent`.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.homelab.hermes;
  hermes = self.inputs.hermes-agent;
  user = "hermes";
  # Static, because the nftables rules below match on it.
  uid = 381;
  stateDir = "/var/lib/hermes";
  host = "hermes.${config.homelab.domain}";
  dashboardPort = 9119;
  ollamaUrl = "http://${cfg.ollama.address}:${toString cfg.ollama.port}";

  # Upstream patches patchelf 0.19.2 for a bug that corrupts node
  # (NixOS/patchelf#674). Our nixpkgs has gone back to 0.15.2, which predates
  # the bug and which the patch doesn't apply to, so hand it 0.15.2 as is.
  # Drop this once upstream checks the version or nixpkgs ships the fix.
  patchelf = pkgs.patchelf // {
    overrideAttrs = _: pkgs.patchelf;
  };
  package = hermes.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
    pmPackages = lib.filterAttrs (_: lib.isDerivation) (
      pkgs.callPackage "${hermes}/nix/pm-packages.nix" { inherit patchelf; }
    );
  };

  # Plugins from Hermes' plugin catalog, at the commits the catalog pins
  # (plugin-catalog/<name>.yaml in the hermes-agent input), installed here
  # rather than with `hermes plugins install` at runtime. When bumping the
  # input, take the new SHAs from there.
  plugin =
    name: src:
    pkgs.runCommand "hermes-plugin-${name}" { } ''
      cp -r ${src} $out
    '';
  hindsightSrc = pkgs.fetchFromGitHub {
    owner = "vectorize-io";
    repo = "hindsight";
    rev = "f14cc1eb5624b0374cb4d82768eb2e0b9c21ae24";
    hash = "sha256-/i9dq5v7w0agur17alI3rutFyrSwtlwsP2yA8kOHYD0=";
  };
  officialPluginsSrc = pkgs.fetchFromGitHub {
    owner = "NousResearch";
    repo = "hermes-official-plugins";
    rev = "72eb3b87215e98d11cecfb26ca95b86be73b32de";
    hash = "sha256-LlQvSm8vEHrZns8UPHYTzY1e+Kq6+k/Xuoan+KQq5SI=";
  };
  # Community plugin (the only subscription route for Gemini); Hermes' catalog
  # reviewed this commit.
  antigravitySrc = pkgs.fetchFromGitHub {
    owner = "soyelmismo";
    repo = "hermes-antigravity-subscription";
    rev = "f1c1a8ccc5a560b8d5926e2b7e4b544d272d2dd2";
    hash = "sha256-0ECTK7SNo2z2wOCAvGJbf0KI2ctexue8k7/JcfqX+Iw=";
  };

  # The Hindsight plugin talks to the server through hindsight-client, which
  # Hermes would otherwise pip-install at runtime. Built from the same commit,
  # with Hermes' interpreter; its dependencies (aiohttp, aiohttp-retry,
  # pydantic, yarl, urllib3, python-dateutil) are already in Hermes' venv, so
  # none are added here that could shadow those.
  hindsightClient = package.python.pkgs.buildPythonPackage {
    pname = "hindsight-client";
    version = "1.2.0";
    pyproject = true;
    src = "${hindsightSrc}/hindsight-clients/python";
    build-system = [ package.python.pkgs.hatchling ];
    dontCheckRuntimeDeps = true;
    doCheck = false;
  };

  # Hindsight and SearXNG may be reached; everything else on loopback that is
  # one of ARBITER's services may not (homelab.hostPorts, t3-code.nix).
  allowedHostPorts = [
    config.homelab.hindsight.port
    config.homelab.searxng.port
    dashboardPort
  ];
in
{
  imports = [
    hermes.nixosModules.default
    ./hindsight.nix
    ./searxng.nix
  ];

  options.homelab.hermes = {
    ollama = {
      address = lib.mkOption {
        type = lib.types.str;
        example = "192.168.1.10";
        description = "LAN address of the Ollama server (TEMPLAR); the only LAN host Hermes may reach.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 11434;
      };
    };
    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "16G";
      description = "Memory cap for the Hermes services, and separately for the hermes user's own slice (SSH, cron jobs).";
    };
  };

  config = {
    homelab.unfreePackages = [
      "claude-code"
      "antigravity-cli"
    ];

    services.hermes-agent = {
      enable = true;
      inherit package stateDir;

      settings = {
        # Hindsight on localhost (hindsight.nix); its config.json is below.
        memory.provider = "hindsight";
        # Directory plugins only load once named here; memory providers are
        # picked by memory.provider instead. Names are each plugin.yaml's.
        plugins.enabled = [
          "claude-subscription-directsdk-experimental"
          "antigravity-subscription-directsdk"
        ];
        providers.ollama.base_url = "${ollamaUrl}/v1";
        web = {
          backend = "searxng";
          # Otherwise a search with no answer from SearXNG is retried on the
          # free tiers of Exa, Parallel, Firecrawl and Keenable, and they see
          # the query.
          keyless_fallback = false;
          keyless_rescue = false;
        };
        browser = {
          # From nixpkgs instead of the Chromium Hermes downloads on first use.
          executable_path = lib.getExe pkgs.chromium;
          # One persistent profile (the user's choice): logins made in it stay,
          # and are usable by anyone on the e-mail whitelist.
          user_data_dir = "${stateDir}/browser-profile";
        };
        # No pip installs at runtime: every Python dependency comes from the
        # package or extraPythonPackages.
        security.allow_lazy_installs = false;
        # Served by Caddy; naming it here makes the loopback dashboard require
        # a login and accept that Host.
        dashboard.public_url = "https://${host}";
      };

      environment = {
        SEARXNG_URL = "http://127.0.0.1:${toString config.homelab.searxng.port}";
        EMAIL_IMAP_HOST = "imap.gmail.com";
        EMAIL_SMTP_HOST = "smtp.gmail.com";
        # Gmail's receiving servers stamp Authentication-Results with this; a
        # sender only counts as whitelisted once Gmail authenticated it.
        EMAIL_AUTHSERV_ID = "mx.google.com";
        HERMES_DASHBOARD_BASIC_AUTH_USERNAME = "admin";
      };
      # Merged into $HERMES_HOME/.env (0640) at activation.
      environmentFiles = [ config.sops.templates."hermes.env".path ];

      hermesHomeFiles."hindsight/config.json" = builtins.toJSON {
        mode = "local_external";
        api_url = "http://127.0.0.1:${toString config.homelab.hindsight.port}";
        bank_id = "hermes";
      };

      # The Hindsight plugin is linked below instead: extraPlugins names its
      # links nix-managed-*, and a memory provider is found by directory name.
      extraPlugins = [
        (plugin "claude-subscription" "${officialPluginsSrc}/claude-subscription-directsdk")
        (plugin "antigravity-subscription" antigravitySrc)
      ];
      extraPythonPackages = [ hindsightClient ];

      # On the services' PATH and the hermes user's (SSH, Hermes Desktop).
      extraPackages = [
        package
        # The plugins drive these, logged in as hermes.
        pkgs.claude-code
        pkgs.antigravity-cli
        pkgs.chromium
        pkgs.curl
      ];

      # The dashboard: the web UI and what Hermes Desktop's "Remote gateway"
      # mode connects to. Desktop's SSH mode starts its own backend instead.
      backend = {
        mode = "dashboard";
        host = "127.0.0.1";
        port = dashboardPort;
      };
    };

    # After upstream's setup, which creates plugins/ and chowns the hermes home.
    system.activationScripts.hermes-memory-plugin = lib.stringAfter [ "hermes-agent-setup" ] ''
      ln -sfn ${plugin "hindsight" "${hindsightSrc}/hindsight-integrations/hermes"} ${stateDir}/.hermes/plugins/hindsight
      chown -h ${user}:${user} ${stateDir}/.hermes/plugins/hindsight
    '';

    sops.secrets = lib.genAttrs [
      "hermes/email-address"
      "hermes/email-app-password"
      "hermes/email-allowed-users"
      "hermes/dashboard-password"
      "hermes/dashboard-auth-secret"
    ] (_: { });
    # Read by the activation script as root and merged into .env.
    sops.templates."hermes.env".content = ''
      EMAIL_ADDRESS=${config.sops.placeholder."hermes/email-address"}
      EMAIL_PASSWORD=${config.sops.placeholder."hermes/email-app-password"}
      EMAIL_ALLOWED_USERS=${config.sops.placeholder."hermes/email-allowed-users"}
      HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${config.sops.placeholder."hermes/dashboard-password"}
      HERMES_DASHBOARD_BASIC_AUTH_SECRET=${config.sops.placeholder."hermes/dashboard-auth-secret"}
    '';

    users.users.${user} = {
      inherit uid;
      # Hermes Desktop's SSH mode logs in as hermes and runs `hermes serve`
      # with this user's ~/.hermes, which is the service's state.
      openssh.authorizedKeys.keys = config.homelab.admin.sshKeys;
    };
    services.openssh.settings.AllowUsers = [ user ];

    # Upstream sets NoNewPrivileges, ProtectSystem=strict and PrivateTmp. Not
    # ProtectHome: it would hide /run/user, whose bus the cron dispatcher
    # needs; the other homes are 0700 anyway. No namespace or syscall limits:
    # Chromium's sandbox needs user namespaces.
    systemd.services =
      lib.genAttrs
        [
          "hermes-agent"
          "hermes-backend"
        ]
        (_: {
          serviceConfig = {
            Slice = "hermes.slice";
            CapabilityBoundingSet = "";
            PrivateDevices = true;
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
              "AF_NETLINK"
            ];
          };
        });
    systemd.slices.hermes.sliceConfig.MemoryMax = cfg.memoryMax;
    # SSH sessions and cron jobs (`systemd-run --user`) run here instead.
    systemd.slices."user-${toString uid}" = {
      overrideStrategy = "asDropin";
      sliceConfig.MemoryMax = cfg.memoryMax;
    };

    # Like `agent` (t3-code.nix): internet only. The exceptions are Ollama on
    # TEMPLAR, and on loopback Hindsight, SearXNG and its own dashboard. Applies
    # to everything the user runs: the services, cron jobs, SSH sessions.
    networking.nftables.tables.hermes = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          meta skuid ${toString uid} ct state new jump restrict
        }
        chain restrict {
          ip daddr ${cfg.ollama.address} tcp dport ${toString cfg.ollama.port} return
          oifname "lo" tcp dport { ${lib.concatMapStringsSep ", " toString allowedHostPorts} } return
          oifname "lo" meta l4proto { tcp, udp } th dport { ${
            lib.concatMapStringsSep ", " toString (
              lib.unique (lib.subtractLists allowedHostPorts config.homelab.hostPorts)
            )
          } } reject comment "hermes: not the host's services"
          oifname "lo" return
          meta nfproto ipv6 reject comment "hermes: IPv4 internet only"
          ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 } reject comment "hermes: internet only"
        }
      '';
    };

    homelab.hostPorts = [ dashboardPort ];

    # LAN and WireGuard only (caddy.nix); the dashboard's own login is the
    # second gate. Websockets (/api/ws, /api/pty) pass through as is.
    services.caddy.virtualHosts.${host} = {
      useACMEHost = "wildcard";
      extraConfig = ''
        reverse_proxy 127.0.0.1:${toString dashboardPort} {
          flush_interval -1
        }
      '';
    };
  };
}
