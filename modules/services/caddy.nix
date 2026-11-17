# Caddy as the TLS-terminating reverse proxy. Each service module adds its own
# virtual host on a subdomain of homelab.domain, with useACMEHost = "wildcard".
{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = config.homelab.domain;
  # Served to TLS clients that send no SNI or an unknown one (port scanners,
  # bare-IP probes). Without it Caddy falls back to the only real certificate
  # and hands `*.gameforce.me` to anyone who connects to an open port. Looks
  # like a stock dev server; proves nothing, so the key may live in the store.
  # `decoy.invalid` is the lookup name; `localhost` alone would make Caddy try
  # its internal CA instead of this file.
  decoyCert =
    pkgs.runCommand "caddy-decoy-cert"
      {
        nativeBuildInputs = [ pkgs.openssl ];
      }
      ''
        mkdir "$out"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
          -keyout "$out/key.pem" -out "$out/cert.pem" -days 3650 \
          -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,DNS:decoy.invalid"
      '';
in
{
  options.homelab.domain = lib.mkOption {
    type = lib.types.str;
    description = "Domain whose subdomains name the services behind Caddy.";
  };

  options.homelab.caddy.decoyCert = lib.mkOption {
    type = lib.types.package;
    default = decoyCert;
    readOnly = true;
    description = "Directory with cert.pem/key.pem for catch-all sites on internet-facing ports.";
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
          # Host header must equal the SNI, else 421. Otherwise an HTTP/2
          # request with the right SNI and a foreign :authority slips past
          # every site's host matcher and gets Caddy's empty 200 (verified).
          strict_sni_host on
        }
        # Certificate for clients with no or unknown SNI: the decoy above, not
        # the wildcard. Applies on every port; a LAN client hitting the bare
        # IP sees the decoy and a 421, which is fine.
        default_sni decoy.invalid
        fallback_sni decoy.invalid
      '';
    };

    # Services are for the home LAN and WireGuard peers only; nothing but
    # WireGuard is port-forwarded. Matching on private source addresses (not
    # on interface) keeps that true on the host even if a forward for 443 is
    # ever added in UniFi, since port forwards keep the public source address.
    # The agent user's own connections are refused earlier (t3-code.nix).
    # IPv4 only: the DNS records are A records.
    networking.firewall.extraInputRules = ''
      tcp dport 443 ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } accept comment "caddy: LAN and wg peers only"
    '';

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
