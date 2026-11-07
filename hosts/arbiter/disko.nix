# Single-disk layout: EFI system partition + ext4 root, no encryption.
# ext4 was chosen for lowest maintenance; no LUKS so unattended auto-upgrade
# reboots come back up without intervention.
{
  disko.devices.disk.main = {
    type = "disk";
    # Fill in from `ls -l /dev/disk/by-id` on the installer. by-id is stable
    # across reboots and controller ordering, unlike /dev/sdX or /dev/nvmeXnY.
    device = "/dev/disk/by-id/<DISK_ID>";
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
