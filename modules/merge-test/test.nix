# VM test of the dead man's switch: a healthy system is kept and its rollback
# cancelled; a failing unit, a lost sshd or a failed check roll back at once;
# and if the script dies after activating, the timer still rolls back. The
# last case is the one that matters when the network goes, and it relies on
# the transient timer surviving switch-to-configuration.
{ pkgs }:
let
  activate = pkgs.callPackage ./activate.nix { };
in
pkgs.testers.runNixOSTest {
  name = "merge-test";

  nodes.machine =
    { lib, ... }:
    {
      services.openssh.enable = true;
      environment.systemPackages = [ activate ];
      specialisation = {
        good.configuration.systemd.services.harmless = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
        broken.configuration.systemd.services.broken = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/false";
        };
        no-ssh.configuration.services.openssh.enable = lib.mkForce false;
      };
    };

  testScript = ''
    from datetime import timedelta

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("sshd.service")

    base = machine.succeed("readlink -f /run/current-system").strip()
    spec = {
        n: machine.succeed(f"readlink -f {base}/specialisation/{n}").strip()
        for n in ["good", "broken", "no-ssh"]
    }
    # A test VM boots its toplevel directly; give it the boot default that
    # deploy.sh leaves on ARBITER.
    machine.succeed(f"mkdir -p /nix/var/nix/profiles && ln -sfn {base} /nix/var/nix/profiles/system")

    def current():
        return machine.succeed("readlink -f /run/current-system").strip()

    def back_to_base():
        machine.succeed(f"{base}/bin/switch-to-configuration test")
        assert current() == base

    env = "REVERT_AFTER=30s SETTLE=2"

    with subtest("refused without a boot default"):
        machine.succeed("mv /nix/var/nix/profiles/system /nix/var/nix/profiles/system.off")
        out = machine.fail(f"{env} merge-test-activate {spec['good']}")
        assert out.startswith("refused"), out
        assert current() == base
        machine.succeed("mv /nix/var/nix/profiles/system.off /nix/var/nix/profiles/system")

    with subtest("a healthy system is kept and its rollback cancelled"):
        out = machine.succeed(f"{env} merge-test-activate {spec['good']}")
        assert out.strip() == "kept", out
        assert current() == spec["good"]
        machine.fail("systemctl is-active merge-test-revert.timer")
        # Past the rollback deadline: nothing reverts it.
        machine.sleep(timedelta(seconds=40))
        assert current() == spec["good"]
        back_to_base()

    with subtest("a unit that fails rolls back"):
        out = machine.fail(f"{env} merge-test-activate {spec['broken']}")
        assert out.startswith("rolled back"), out
        assert "broken.service" in out, out
        assert current() == base
        machine.succeed("systemctl reset-failed broken.service || true")

    with subtest("losing sshd rolls back"):
        out = machine.fail(f"{env} merge-test-activate {spec['no-ssh']}")
        assert "sshd.service is not active" in out, out
        assert current() == base
        # This rollback re-executes systemd mid-way; the script must still
        # wait for it to finish.
        machine.fail("systemctl is-active merge-test-revert.service")
        machine.wait_for_unit("sshd.service")

    with subtest("a failing check rolls back"):
        out = machine.fail(f"{env} merge-test-activate {spec['good']} false")
        assert "check failed: false" in out, out
        assert current() == base

    with subtest("the timer rolls back when the script dies after activating"):
        # Killed while its check hangs, the way a lost network would leave it.
        machine.fail(f"{env} timeout 15 merge-test-activate {spec['good']} sleep 600")
        assert current() == spec["good"]
        machine.wait_until_succeeds(f'[ "$(readlink -f /run/current-system)" = {base} ]', timeout=timedelta(seconds=90))
        machine.wait_for_unit("sshd.service")
  '';
}
