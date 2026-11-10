#!/bin/sh
# Add a name (school, employer, street, ...) to the sops secrets so that
# ContextForge replaces it in every tool result before an AI client sees it.
#
#   ./add-pii.sh <key> [label]        e.g.  ./add-pii.sh employer "[EMPLOYER]"
#   ./add-pii.sh -r <key> [label]     store the value as a regex, unescaped
#
# The value is read from the terminal, not taken as an argument, so it never
# lands in shell history or `ps`. It is stored under contextforge/<key> in
# hosts/arbiter/secrets.yaml, escaped so that it matches literally (the module
# wraps it in a case-insensitive whole-word regex). Afterwards, reference the
# key once in hosts/arbiter/default.nix; the script prints the lines.
set -eu

cd "$(dirname "$0")"
file=hosts/arbiter/secrets.yaml

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

raw=0
if [ "${1-}" = "-r" ] || [ "${1-}" = "--regex" ]; then
  raw=1
  shift
fi
key=${1-}
label=${2-}
[ -n "$key" ] || die "usage: $0 [-r] <key> [label]   (key: lower-case letters, digits, dashes)"
case $key in
  *[!a-z0-9-]* | -* | *-) die "key must be lower-case letters, digits and dashes, e.g. school-name" ;;
esac
[ -f "$file" ] || die "$file not found; run from the repo checkout"
command -v sops >/dev/null || die "sops not found in PATH"

# Default label: [SCHOOL_NAME] for school-name.
[ -n "$label" ] || label="[$(printf '%s' "$key" | tr 'a-z-' 'A-Z_')]"

if grep -q "^    $key:" "$file"; then
  printf 'contextforge/%s already exists. Replace it? [y/N] ' "$key"
  read -r answer
  case $answer in
    y | Y) ;;
    *) die "left unchanged" ;;
  esac
fi

printf 'Value for contextforge/%s (as it appears in mail and notes): ' "$key"
read -r value
[ -n "$value" ] || die "empty value"

if [ "$raw" -eq 0 ]; then
  # Escape Python regex metacharacters so the name matches literally.
  value=$(printf '%s' "$value" | sed 's/[][\\^$.|?*+(){}]/\\&/g')
fi
# JSON-encode for `sops set`: backslashes first, then quotes.
json=$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')

sops set "$file" "[\"contextforge\"][\"$key\"]" "\"$json\""

cat <<EOF

Stored contextforge/$key (regex: $value).

Next, unless the key is already referenced, add to the rules of the right
group in hosts/arbiter/pii/ (10-people.nix for a person or place; longer
values before shorter ones they contain):

    {
      secret = "$key";
      replace = "$label";
    }

Then: nix flake check && git add -A && git commit -m "Pseudonymise $key" && git push
and deploy. Test a tool in the admin UI; the name should show as $label.
EOF
