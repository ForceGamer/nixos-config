# Host side of the Claude Code microVM: a sandbox with internet access only.
{ config, lib, ... }:
let
  net = {
    tap = "vm-claude";
    mac = "02:00:00:00:01:01";
    host = "10.101.0.1";
    guest = "10.101.0.2";
  };
in
{
  microvm.vms.claude = {
    specialArgs = {
      inherit net;
      adminKeys = config.homelab.admin.sshKeys;
    };
    config = ./claude-vm-guest.nix;
  };

  # Only needed for bridged networking; this VM uses a plain tap device, so
  # don't ship a cap_net_admin helper binary.
  security.wrappers.qemu-bridge-helper.enable = false;

  systemd.network.networks."60-${net.tap}" = {
    matchConfig.Name = net.tap;
    address = [ "${net.host}/24" ];
    linkConfig.RequiredForOnline = "no";
  };

  # DNS through the host's resolver, so the VM needs no route to the router.
  services.resolved.settings.Resolve.DNSStubListenerExtra = net.host;
  networking.firewall.interfaces.${net.tap} = {
    allowedUDPPorts = [ 53 ];
    allowedTCPPorts = [ 53 ];
  };

  # The global firewall ports (SSH, WireGuard) would otherwise be reachable
  # from the VM too. A drop here is final, whatever nixos-fw later accepts.
  networking.nftables.tables.claude-vm = {
    family = "inet";
    content = ''
      chain input {
        type filter hook input priority filter - 10; policy accept;
        iifname "${net.tap}" ct state established,related return
        iifname "${net.tap}" meta l4proto { tcp, udp } th dport 53 return
        iifname "${net.tap}" drop
      }
    '';
  };

  networking.nat = {
    enable = true;
    internalInterfaces = [ net.tap ];
    externalInterface = "en*";
  };
  networking.firewall.filterForward = true;
  # Internet only: no home LAN, no WireGuard peers, no CGNAT or link-local.
  networking.firewall.extraForwardRules = lib.mkBefore ''
    iifname "${net.tap}" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } drop comment "claude vm: internet only"
  '';
}
