# The dead man's switch on its own, so the VM test (test.nix) runs the same
# script as ARBITER.
{
  writeShellApplication,
  systemd,
  coreutils,
  iproute2,
}:
writeShellApplication {
  name = "merge-test-activate";
  runtimeInputs = [
    systemd
    coreutils
    iproute2
  ];
  text = builtins.readFile ./activate.sh;
}
