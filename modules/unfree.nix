# Unfree packages are allowed one by one, by name, by the module that needs
# them; never unfree software in general. nixpkgs takes a single predicate,
# so the modules add names to this list instead of each setting their own.
{ config, lib, ... }:
{
  options.homelab.unfreePackages = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Names (lib.getName) of unfree packages that may be built.";
  };

  config.nixpkgs.config.allowUnfreePredicate =
    pkg: builtins.elem (lib.getName pkg) config.homelab.unfreePackages;
}
