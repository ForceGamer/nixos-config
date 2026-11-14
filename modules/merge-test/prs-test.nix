# Tests merge-test-prs against a local "GitHub": a bare repo with branches
# and refs/pull/N/head, the way GitHub exposes pull requests to a deploy key.
{ pkgs }:
let
  prs = pkgs.callPackage ./prs.nix { };
in
pkgs.runCommand "merge-test-prs-check"
  {
    nativeBuildInputs = [
      prs
      pkgs.git
    ];
  }
  ''
    set -euo pipefail
    export HOME=$PWD GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org
    git config --global init.defaultBranch master

    git init --quiet --bare github.git
    git init --quiet work && cd work
    commit() { echo "$1" >> f; git add f; git commit --quiet -m "$1"; }
    pr() { git push --quiet ../github.git "$2:refs/pull/$1/head"; }   # pr N REF

    commit "base"; git push --quiet ../github.git master
    git checkout --quiet -b claude/old; commit "Old change"; git push --quiet ../github.git claude/old; pr 1 claude/old
    git checkout --quiet master
    cd ..

    git init --quiet --bare mirror.git
    git -C mirror.git fetch --quiet ../github.git master:master
    state=$PWD/last-pr

    expect() {  # expect DESCRIPTION EXPECTED-OUTPUT
      got=$(merge-test-prs "$PWD/github.git" "$PWD/mirror.git" "$state")
      if [ "$got" != "$2" ]; then
        printf 'FAIL %s\n  want: %q\n  got:  %q\n' "$1" "$2" "$got"; exit 1
      fi
      echo "ok   $1"
    }

    expect "first run only records" ""
    [ "$(< "$state")" = 1 ] || { echo "FAIL seed state is $(< "$state")"; exit 1; }
    expect "nothing new" ""

    cd work
    git checkout --quiet -b claude/new; commit "First commit of the PR"; commit "Follow-up fix"
    git push --quiet ../github.git claude/new; pr 2 claude/new
    git checkout --quiet master; git checkout --quiet -b feature/mine; commit "Not Claude's"
    git push --quiet ../github.git feature/mine; pr 3 feature/mine
    git checkout --quiet master; git checkout --quiet -b claude/later; commit "Later change"
    git push --quiet ../github.git claude/later; pr 4 claude/later
    cd ..

    expect "new claude/ PRs, oldest first, titled by their first commit" "$(printf '2\tFirst commit of the PR\n4\tLater change')"
    [ "$(< "$state")" = 4 ] || { echo "FAIL state is $(< "$state")"; exit 1; }
    expect "announced once" ""

    # A PR whose branch is already gone (merged and deleted within a poll).
    cd work; git checkout --quiet -b claude/gone; commit "Gone"; pr 5 claude/gone; cd ..
    expect "a PR without a claude/ branch is skipped" ""
    [ "$(< "$state")" = 5 ] || { echo "FAIL skipped PR not recorded"; exit 1; }

    git -C mirror.git for-each-ref refs/prs | grep -q . && { echo "FAIL temporary refs left"; exit 1; }
    echo ok > "$out"
  ''
