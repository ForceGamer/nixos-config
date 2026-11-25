# Hindsight: Hermes' long-term memory, as a server on localhost (nixpkgs'
# hindsight-api-slim) over PostgreSQL with pgvector. The slim build has no
# local models, so each part is external:
# - LLM (fact extraction on retain, reasoning on reflect): Claude via the
#   Claude Code CLI on the Max subscription (the user's choice: the same
#   provider Hermes defaults to). Its own `claude setup-token` token in sops.
# - Embeddings: Ollama on TEMPLAR (OpenAI-compatible API). While TEMPLAR is
#   off, nothing new is remembered and recall fails, and the server won't
#   even start; Hermes carries on without memory.
# - Reranking: reciprocal rank fusion, no model.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.hindsight;
  ollama = config.homelab.hermes.ollama;
  stateDir = "/var/lib/hindsight";
in
{
  options.homelab.hindsight = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 8888;
    };
    embeddingModel = lib.mkOption {
      type = lib.types.str;
      # Multilingual and small. The vector size is fixed when the database is
      # first set up: changing the model later means re-embedding everything.
      default = "qwen3-embedding:0.6b";
      description = "Ollama embedding model; pull it on TEMPLAR first.";
    };
  };

  config = {
    homelab.unfreePackages = [ "claude-code" ];
    homelab.hostPorts = [
      cfg.port
      config.services.postgresql.settings.port
    ];

    services.postgresql = {
      enable = true;
      extensions = ps: [ ps.pgvector ];
      ensureDatabases = [ "hindsight" ];
      ensureUsers = [
        {
          name = "hindsight";
          ensureDBOwnership = true;
        }
      ];
    };
    # pgvector needs a superuser to create the extension; Hindsight's own
    # migrations then find it.
    systemd.services.postgresql-setup.script = lib.mkAfter ''
      psql -d hindsight -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS vector'
    '';

    users.users.hindsight = {
      isSystemUser = true;
      group = "hindsight";
    };
    users.groups.hindsight = { };

    sops.secrets."hindsight/claude-token" = { };
    sops.templates."hindsight.env" = {
      owner = "hindsight";
      content = ''
        HINDSIGHT_API_LLM_API_KEY=${config.sops.placeholder."hindsight/claude-token"}
      '';
    };

    systemd.services.hindsight = {
      description = "Hindsight memory server";
      wantedBy = [ "multi-user.target" ];
      requires = [ "postgresql-setup.service" ];
      after = [
        "postgresql-setup.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      # The Claude Agent SDK starts this.
      path = [ pkgs.claude-code ];
      environment = {
        HOME = stateDir;
        HINDSIGHT_API_HOST = "127.0.0.1";
        HINDSIGHT_API_PORT = toString cfg.port;
        # Peer authentication over the socket: no database password.
        HINDSIGHT_API_DATABASE_URL = "postgresql://hindsight@/hindsight?host=/run/postgresql";
        HINDSIGHT_API_LLM_PROVIDER = "claude-code";
        # An alias the CLI resolves, so it follows new Claude releases.
        HINDSIGHT_API_LLM_MODEL = "sonnet";
        HINDSIGHT_API_EMBEDDINGS_PROVIDER = "openai";
        HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL = "http://${ollama.address}:${toString ollama.port}/v1";
        HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL = cfg.embeddingModel;
        # Ollama ignores it. Unset, the client would fall back to the LLM key
        # and send the Claude token to TEMPLAR.
        HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY = "ollama";
        HINDSIGHT_API_RERANKER_PROVIDER = "rrf";
        # Each start would otherwise spend a Claude call checking the login,
        # and the server restarts until TEMPLAR answers (below).
        HINDSIGHT_API_SKIP_LLM_VERIFICATION = "true";
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
      };
      serviceConfig = {
        ExecStart = lib.getExe' pkgs.hindsight-api-slim "hindsight-api";
        EnvironmentFile = config.sops.templates."hindsight.env".path;
        User = "hindsight";
        Group = "hindsight";
        StateDirectory = "hindsight";
        StateDirectoryMode = "0700";
        # The server exits at start when the embedding endpoint (TEMPLAR)
        # doesn't answer; it comes up within a minute of TEMPLAR.
        Restart = "always";
        RestartSec = "1min";
        UMask = "0077";
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
        LockPersonality = true;
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
        # Anthropic's API on the internet, PostgreSQL over its socket, and of
        # the LAN only Ollama on TEMPLAR.
        IPAddressAllow = [
          "localhost"
          "${ollama.address}/32"
        ];
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
  };
}
