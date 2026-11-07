{
  networking.useNetworkd = true;
  # Replace NixOS's catch-all DHCP fallback with one explicit network below.
  networking.useDHCP = false;

  # Addressing comes from a DHCP reservation in UniFi, not from this repo.
  systemd.network.networks."10-wired" = {
    matchConfig.Name = "en*";
    networkConfig.DHCP = "yes";
    linkConfig.RequiredForOnline = "routable";
  };

  networking.nftables.enable = true;
  networking.firewall.enable = true;
}
