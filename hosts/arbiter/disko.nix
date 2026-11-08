# Single-disk layout: EFI system partition + ext4 root, no encryption.
# ext4 was chosen for lowest maintenance; no LUKS so unattended auto-upgrade
# reboots come back up without intervention.
{
  disko.devices.disk.main = {
    type = "disk";
    # by-id is stable across reboots and controller ordering, unlike
    # /dev/nvmeXnY. ARBITER's only disk.
    device = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_with_Heatsink_1TB_S6WSNS0W619318E";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          type = "EF00";
          size = "1G";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            # The ESP holds the systemd-boot random seed; keep it root-only.
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
