# Caddy as the TLS-terminating reverse proxy. Each service module adds its own
# virtual host on a subdomain of homelab.domain, with useACMEHost = "wildcard".
{ config, lib, ... }:
let
  domain = config.homelab.domain;
in
{
  options.homelab.domain = lib.mkOption {
    type = lib.types.str;
    description = "Domain whose subdomains name the services behind Caddy.";
  };

  config = {
    # Certificates come from the NixOS ACME module (lego, which ships with
    # nixpkgs) over a Cloudflare DNS-01 challenge, not from Caddy itself: stock
    # Caddy has no Cloudflare plugin, and a custom build would pull extra Go
    # modules and compile locally. DNS-01 also needs no inbound port 80.
    security.acme = {
      acceptTerms = true;
      certs.wildcard = {
        # One wildcard instead of a certificate per service: Certificate
        # Transparency logs then don't list every service hostname, and new
        # services need no new certificate.
        domain = "*.${domain}";
        dnsProvider = "cloudflare";
        # The token is handed to lego via LoadCredential, never in its env file.
        credentialFiles.CF_DNS_API_TOKEN_FILE = config.sops.secrets."cloudflare/dns-api-token".path;
        # Check propagation against a public resolver, so a local DNS override
        # for the domain in UniFi can't stall issuance.
        dnsResolver = "1.1.1.1:53";
        # The Caddy module sets group = "caddy" and reloads Caddy on renewal.
      };
    };

    # Root-owned: lego reads it through systemd credentials.
    sops.secrets."cloudflare/dns-api-token" = { };

    services.caddy = {
      enable = true;
      globalConfig = ''
        # The default admin API is TCP on localhost:2019, which any local
        # process could use to rewrite the proxy. A socket only caddy can open
        # keeps `caddy reload` (run as caddy) working.
        admin unix//run/caddy/admin.sock|0600
        # Certificates are managed by lego above. Without redirects Caddy
        # doesn't bind port 80 at all.
        auto_https disable_redirects
        # No HTTP/3, so no UDP listener and no UDP port to open.
        servers {
          protocols h1 h2
        }
      '';
    };

    networking.firewall.allowedTCPPorts = [ 443 ];

    # Tighten the upstream unit (which grants CAP_NET_ADMIN for QUIC buffers).
    systemd.services.caddy.serviceConfig = {
      AmbientCapabilities = lib.mkForce [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = lib.mkForce [ "CAP_NET_BIND_SERVICE" ];
      RuntimeDirectory = "caddy";
      RuntimeDirectoryMode = "0700";
      ProtectSystem = lib.mkForce "strict";
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
      UMask = "0077";
    };
  };
}
