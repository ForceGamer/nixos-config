# SearXNG: Hermes' web search, on localhost only. It queries the search
# engines itself, from ARBITER's address, so no search provider holds an
# account or a history of the agent's queries.
{ config, lib, ... }:
let
  cfg = config.homelab.searxng;
in
{
  options.homelab.searxng.port = lib.mkOption {
    type = lib.types.port;
    default = 8890;
  };

  config = {
    homelab.hostPorts = [ cfg.port ];

    sops.secrets."searxng/secret-key" = { };
    sops.templates."searxng.env".content = ''
      SEARX_SECRET_KEY=${config.sops.placeholder."searxng/secret-key"}
    '';

    services.searx = {
      enable = true;
      environmentFile = config.sops.templates."searxng.env".path;
      settings = {
        use_default_settings = true;
        server = {
          bind_address = "127.0.0.1";
          inherit (cfg) port;
          secret_key = "$SEARX_SECRET_KEY";
          # Only Hermes asks; the bot limiter would need Valkey and guards
          # public instances.
          limiter = false;
          public_instance = false;
          image_proxy = false;
        };
        # Hermes reads results as JSON.
        search.formats = [
          "html"
          "json"
        ];
        outgoing.request_timeout = 5.0;
      };
    };

    # The engines are on the internet; nothing on the LAN.
    systemd.services.searx.serviceConfig = {
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
}
