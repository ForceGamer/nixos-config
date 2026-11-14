# merge-test-prs REMOTE REPO STATEFILE
#
# Prints "N<TAB>subject" for each pull request opened since the last run
# whose branch starts with PR_PREFIX (default claude/), oldest first, and
# records the highest number seen in STATEFILE. The first run only records,
# so existing pull requests aren't announced. REPO is a bare clone that has
# BASE_BRANCH (default master) fetched; the subject is the first commit the
# pull request adds, which is what Claude also titles it.
#
# It needs no GitHub API token: pull requests show up as refs/pull/N/head,
# which a read-only deploy key can list. A pull request is matched to its
# branch by commit, since that ref doesn't name the branch.
remote=$1
repo=$2
statefile=$3
prefix=${PR_PREFIX:-claude/}
base=${BASE_BRANCH:-master}

refs=$(git ls-remote "$remote")

declare -A branch_of=()
while read -r sha ref; do
  case $ref in
    "refs/heads/$prefix"*) branch_of[$sha]=${ref#refs/heads/} ;;
  esac
done <<<"$refs"

# "N SHA", by number.
mapfile -t prs < <(sed -nE 's#^([0-9a-f]+)\trefs/pull/([0-9]+)/head$#\2 \1#p' <<<"$refs" | sort -n)

if [ ! -e "$statefile" ]; then
  last=0
  for p in "${prs[@]}"; do last=${p%% *}; done
  echo "$last" >"$statefile"
  exit 0
fi

last=$(<"$statefile")
for p in "${prs[@]}"; do
  n=${p%% *}
  sha=${p#* }
  [ "$n" -gt "$last" ] || continue
  # Recorded first, so a pull request is announced at most once.
  echo "$n" >"$statefile"
  last=$n
  branch=${branch_of[$sha]:-}
  [ -n "$branch" ] || continue
  git -C "$repo" fetch --quiet "$remote" "+refs/pull/$n/head:refs/prs/$n"
  # sed, not head: head would close the pipe early and pipefail would trip.
  subject=$(git -C "$repo" log --reverse --format=%s "refs/heads/$base..refs/prs/$n" | sed -n 1p)
  git -C "$repo" update-ref -d "refs/prs/$n"
  printf '%s\t%s\n' "$n" "${subject:-$branch}"
done
