# Usage: merge-test-activate TOPLEVEL [CHECK-COMMAND...]
#
# Activates TOPLEVEL with `switch-to-configuration test` behind a dead man's
# switch, checks the result, and either keeps it or rolls back to the boot
# default. The last line on stdout says which. Exit 0: kept. Exit 1: rolled
# back. Exit 2: refused.
#
# REVERT_AFTER (default 15min) is how long the switch waits for this script.
# It covers activation, which can pull container images, plus SETTLE (default
# 60 seconds) for services to fail before the checks run.

toplevel=$1
shift
revert_after=${REVERT_AFTER:-15min}
settle=${SETTLE:-60}
profile=/nix/var/nix/profiles/system
unit=merge-test-revert

if [ ! -x "$profile/bin/switch-to-configuration" ]; then
  echo "refused: no boot default at $profile to roll back to"
  exit 2
fi

failed_units() {
  systemctl list-units --state=failed --no-legend --plain | cut -d' ' -f1 | sort
}

# What the new system must not lose. Only what works now counts, so a unit
# that was already failing doesn't roll back every test.
failed_before=$(failed_units)
essential=()
for u in sshd.service systemd-networkd.service; do
  if systemctl is-active --quiet "$u"; then essential+=("$u"); fi
done
had_route=$(ip route show default)
had_wg0=false
if ip link show wg0 >/dev/null 2>&1; then had_wg0=true; fi

# Arm before activating. Whatever happens from here on, to this script, to
# the network or to SSH, the timer returns the host to the boot default. The
# profile path resolves when the timer fires, so a deploy.sh in between
# turns the rollback into a no-op.
systemctl stop "$unit.timer" "$unit.service" 2>/dev/null || true
systemctl reset-failed "$unit.timer" "$unit.service" 2>/dev/null || true
systemd-run --quiet --unit="$unit" --on-active="$revert_after" \
  --timer-property=AccuracySec=1s --property=Type=oneshot \
  "$profile/bin/switch-to-configuration" test

reasons=()
# In a transient unit, as nixos-rebuild does: activation may stop or restart
# the unit this script runs in, and must not take itself down with it.
if ! systemd-run --quiet --collect --no-ask-password --pipe --wait \
  --service-type=exec --unit=merge-test-switch \
  "$toplevel/bin/switch-to-configuration" test >&2; then
  reasons+=("switch-to-configuration failed")
fi

sleep "$settle"

new_failed=$(comm -13 <(echo "$failed_before") <(failed_units) | tr '\n' ' ')
if [ -n "${new_failed// /}" ]; then reasons+=("failed units: ${new_failed% }"); fi
for u in "${essential[@]}"; do
  systemctl is-active --quiet "$u" || reasons+=("$u is not active")
done
if [ -n "$had_route" ] && [ -z "$(ip route show default)" ]; then
  reasons+=("no default route")
fi
if $had_wg0 && ! ip link show wg0 >/dev/null 2>&1; then
  reasons+=("wg0 is gone")
fi
if [ $# -gt 0 ] && ! "$@" >/dev/null 2>&1; then
  reasons+=("check failed: $*")
fi

if [ ${#reasons[@]} -eq 0 ]; then
  systemctl stop "$unit.timer"
  echo "kept"
  exit 0
fi

# Roll back now instead of waiting for the timer. Start the service before
# stopping its timer: systemd unloads a transient service nothing refers to.
systemctl start "$unit.service" || true
systemctl stop "$unit.timer" || true
echo "rolled back: $(IFS=';'; echo "${reasons[*]}")"
exit 1
