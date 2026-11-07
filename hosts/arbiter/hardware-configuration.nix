# PLACEHOLDER until first install. Replace this whole file with the output of
#   nixos-generate-config --no-filesystems --show-hardware-config
# run from the installer ISO on ARBITER. Filesystems come from disko.nix.
{
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "sd_mod"
  ];
  boot.kernelModules = [ "kvm-amd" ];

  nixpkgs.hostPlatform = "x86_64-linux";
}
