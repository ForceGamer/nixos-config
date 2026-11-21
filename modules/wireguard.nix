# WireGuard road-warrior VPN into the home LAN, terminated on this host.
# Server public key (for client configs): WyxmP+q2ILYI4iISn/T7Ht3WLAwAvXhyZSAetXUNkh8=
# Client Endpoint: tun.gameforce.me:51820 (the only DDNS name; Cloudflare).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  port = 51820;
  peers = {
    iphone = {
      publicKey = "RmY9pGOMJsim3WmBd/e0NP0x7jHOp4uynMgIJYs/4hw=";
      address = "10.100.0.2/32";
    };
    laptop = {
      publicKey = "o8t4C7S92x3q0ldXZFq5RWvvm64y6e5AF7PqnN3ybg4=";
      address = "10.100.0.3/32";
    };
  };
  # networkd reads key files itself, as systemd-network.
  keyFile = {
    owner = "systemd-network";
    mode = "0400";
  };
in
{
  sops.secrets = {
    "wireguard/private-key" = keyFile;
  }
  // lib.mapAttrs' (name: _: lib.nameValuePair "wireguard/psk-${name}" keyFile) peers;

  # Configured as a plain networkd netdev with key *files*, not via
  # networking.wireguard: that backend hands keys to systemd-networkd with
  # LoadCredential, so a missing secret would stop networkd entirely and take
  # SSH down with it. Here a missing key only breaks wg0.
  systemd.network.netdevs."50-wg0" = {
    netdevConfig = {
      Kind = "wireguard";
      Name = "wg0";
    };
    wireguardConfig = {
      PrivateKeyFile = config.sops.secrets."wireguard/private-key".path;
      ListenPort = port;
    };
    wireguardPeers = lib.mapAttrsToList (name: peer: {
      PublicKey = peer.publicKey;
      PresharedKeyFile = config.sops.secrets."wireguard/psk-${name}".path;
      AllowedIPs = [ peer.address ];
    }) peers;
  };

  systemd.network.networks."50-wg0" = {
    matchConfig.Name = "wg0";
    address = [ "10.100.0.1/24" ];
    # Don't let a broken tunnel hold up network-online.target (and with it the
    # auto-upgrade).
    linkConfig.RequiredForOnline = "no";
  };

  networking.firewall.allowedUDPPorts = [ port ];

  # `wg show` is the quickest way to see peer handshakes on the host.
  environment.systemPackages = [ pkgs.wireguard-tools ];

  # Peers reach the LAN masqueraded as this host, so UniFi needs no extra
  # routes. "en*" is an nftables wildcard matching the wired NIC.
  networking.nat = {
    enable = true;
    internalInterfaces = [ "wg0" ];
    externalInterface = "en*";
  };

  # Without this the forward chain accepts everything once forwarding is on.
  networking.firewall.filterForward = true;
  # Home LAN only: ARBITER is not an exit to the internet for peers. Runs before
  # the NAT module's blanket accept for wg0.
  networking.firewall.extraForwardRules = lib.mkBefore ''
    iifname "wg0" ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } drop comment "wg peers: private ranges only"
  '';
}
