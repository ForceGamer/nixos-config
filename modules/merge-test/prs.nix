# The pull-request check on its own, so its test (prs-test.nix) runs the same
# script as ARBITER.
{
  writeShellApplication,
  coreutils,
  git,
  gnused,
}:
writeShellApplication {
  name = "merge-test-prs";
  runtimeInputs = [
    coreutils
    git
    gnused
  ];
  text = builtins.readFile ./prs.sh;
}
