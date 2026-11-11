# Tests each new commit on master on ARBITER, behind a dead man's switch.
# Merging a pull request on GitHub is the approval: ARBITER polls the repo
# with a read-only deploy key, builds the new commit and hands it to
# merge-test-activate (activate.sh), which schedules a rollback before
# activating and cancels it only if the host still looks healthy. It never
# switches: the boot default stays the last deploy.sh, so a reboot or the
# weekly upgrade ends the test too. Results go to ntfy (arbiter-alerts).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  host = config.networking.hostName;
  # A branch of its own instead would keep master to tested commits only.
  branch = "master";
  remote = "git@github.com:ForceGamer/nixos-config.git";
  ntfy = "http://${config.services.ntfy-sh.settings.listen-http}/arbiter-alerts";

  # GitHub's published host key (api.github.com/meta), so the deploy key is
  # only ever offered to GitHub.
  knownHosts = pkgs.writeText "github-known-hosts" ''
    github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
  '';

  activate = pkgs.callPackage ./activate.nix { systemd = config.systemd.package; };

  poll = pkgs.writeShellApplication {
    name = "merge-test";
    runtimeInputs = [
      activate
      config.nix.package
      config.systemd.package
      pkgs.coreutils
      pkgs.curl
      pkgs.git
      pkgs.openssh
    ];
    text = ''
      state=$STATE_DIRECTORY
      key=$state/deploy-key
      repo=$state/repo.git
      export GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${knownHosts} -o ConnectTimeout=20"

      # notify PRIORITY TAGS TITLE BODY. The token goes to curl on stdin,
      # never in argv where /proc would show it.
      notify() {
        local token
        token=$(< "$CREDENTIALS_DIRECTORY/token")
        printf 'header = "Authorization: Bearer %s"\n' "$token" \
          | curl --fail --silent --show-error --output /dev/null --config - \
              -H "Title: $3" -H "Priority: $1" -H "Tags: $2" -d "$4" ${ntfy} \
          || echo "could not publish to ntfy" >&2
      }

      # Generated here so the private key never leaves ARBITER.
      if [ ! -e "$key" ]; then
        ssh-keygen -q -t ed25519 -N "" -C "${host} merge-test" -f "$key"
        notify default key "merge-test needs its deploy key on GitHub" \
          "Add it to the repo as a read-only deploy key: $(< "$key.pub")"
      fi
      [ -d "$repo" ] || git init --quiet --bare "$repo"

      # A failing fetch (key not added yet, GitHub down) is reported once,
      # not on every tick.
      if ! err=$(git -C "$repo" fetch --quiet "${remote}" "+refs/heads/${branch}:refs/heads/${branch}" 2>&1); then
        if [ ! -e "$state/fetch-failing" ]; then
          touch "$state/fetch-failing"
          notify high warning "merge-test can't fetch ${branch}" "$err"
        fi
        exit 0
      fi
      if [ -e "$state/fetch-failing" ]; then
        rm "$state/fetch-failing"
        notify default ok "merge-test fetches ${branch} again" "Watching for merges."
      fi

      new=$(git -C "$repo" rev-parse "refs/heads/${branch}")
      if [ ! -e "$state/last" ]; then
        echo "$new" > "$state/last"
        notify default eyes "merge-test is watching ${branch}" \
          "Starting from ''${new:0:7}; the next merge gets tested."
        exit 0
      fi
      [ "$new" != "$(< "$state/last")" ] || exit 0
      # The weekly upgrade switches the whole system; try on the next tick.
      if systemctl is-active --quiet nixos-upgrade.service; then exit 0; fi

      # Recorded before testing, so a commit is tried once, not on every tick.
      echo "$new" > "$state/last"
      short=''${new:0:7}
      subject=$(git -C "$repo" log -1 --format=%s "$new")

      # The exact commit fetched, never whatever the branch says by now.
      if ! toplevel=$(nix build --no-link --print-out-paths \
        "git+file://$repo?ref=${branch}&rev=$new#nixosConfigurations.${host}.config.system.build.toplevel"); then
        notify high warning "$short doesn't build" "$subject. Nothing was activated. Check: journalctl -u merge-test"
        exit 0
      fi
      if [ "$(readlink -f /run/current-system)" = "$toplevel" ]; then
        notify default ok "$short is already running" "$subject"
        exit 0
      fi

      notify default hourglass_flowing_sand "Testing $short" "$subject"
      # The extra check proves DNS, routing and outbound SSH still work.
      if result=$(merge-test-activate "$toplevel" git ls-remote --quiet --exit-code "${remote}" HEAD); then
        notify default white_check_mark "$short is active" \
          "$subject. It passed its checks and stays until the next reboot or upgrade; deploy.sh makes it permanent."
      else
        notify high rotating_light "$short was rolled back" "$subject. $result"
      fi
    '';
  };
in
{
  # Root and unconfined: it activates whole systems, so a sandbox around it
  # would be decorative. What it activates comes from master, which only the
  # user can change.
  systemd.services.merge-test = {
    description = "Test new commits on ${branch} with automatic rollback";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # Activation must not restart the unit that drives it; removing the unit
    # in a test stops it instead, and then the rollback timer takes over.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe poll;
      StateDirectory = "merge-test";
      StateDirectoryMode = "0700";
      LoadCredential = "token:${config.sops.secrets."ntfy/upgrade-notifier-token".path}";
    };
  };

  systemd.timers.merge-test = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitInactiveSec = "2min";
    };
  };
}
