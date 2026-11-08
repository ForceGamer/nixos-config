# Proprietary NVIDIA driver for ARBITER's GTX 1080 Ti (Pascal), headless.
# No X server: putting "nvidia" in videoDrivers is just how the nixpkgs module
# is switched on; services.xserver itself stays disabled.
{ lib, ... }:
{
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    # The default branch (595+) dropped Maxwell, Pascal and Volta. 580 is
    # NVIDIA's long-term branch for them, supported until August 2028.
    branch = "legacy_580";
    # The open kernel modules only support Turing and newer.
    open = false;
    # GUI tool; useless without a display and pulls in GTK.
    nvidiaSettings = false;
    # Without a display server the driver tears the GPU down whenever the last
    # client exits; the daemon keeps it initialised so it idles in a low power
    # state and jobs start without re-init latency.
    nvidiaPersistenced = true;
  };

  # Userspace driver libraries in /run/opengl-driver (CUDA, NVENC/NVDEC).
  hardware.graphics.enable = true;

  # Allow only the driver's own unfree packages, not unfree software in general.
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "nvidia-x11"
      "nvidia-kernel-modules"
      "nvidia-persistenced"
    ];
}
