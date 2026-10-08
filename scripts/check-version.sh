#!/bin/bash
# Refuse to ship a build whose MARKETING_VERSION doesn't match its release tag.
#
#   scripts/check-version.sh ios-v1.6.41-beta1   # tag: version is parsed from it
#   scripts/check-version.sh 1.6.41              # bare version
#   scripts/check-version.sh ""                  # no tag (manual run): report only
#
# project.yml carries MARKETING_VERSION three times (tvOS, iOS, TopShelf) and
# all three must agree with each other and with the tag. Without this, a tag
# cut on the wrong commit ships a build TestFlight shows under the old version.
set -euo pipefail

cd "$(dirname "$0")/.."

want="${1:-}"
versions=$(grep -E '^\s*MARKETING_VERSION:' project.yml | sed -E 's/.*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/' | sort -u)
count=$(grep -cE '^\s*MARKETING_VERSION:' project.yml)

if [ "$(printf '%s\n' "$versions" | wc -l | tr -d ' ')" != 1 ]; then
  echo "::error title=MARKETING_VERSION mismatch::project.yml has differing MARKETING_VERSION values: $(echo $versions)"
  exit 1
fi
if [ "$count" != 3 ]; then
  echo "::error title=MARKETING_VERSION count::expected 3 MARKETING_VERSION entries in project.yml, found $count"
  exit 1
fi

if [ -z "$want" ]; then
  echo "No release tag: building MARKETING_VERSION $versions without a tag check."
  exit 0
fi

# ios-v1.6.41-beta1 / mac-v1.6.41-rc1 / v1.6.41 / 1.6.41 -> 1.6.41
expected="${want#ios-}"
expected="${expected#mac-}"
expected="${expected#v}"
expected="${expected%%-*}"

if ! [[ "$expected" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error title=Bad release tag::cannot read a version out of '$want'"
  exit 1
fi

if [ "$versions" != "$expected" ]; then
  echo "::error title=Version/tag mismatch::'$want' says $expected but project.yml MARKETING_VERSION is $versions. Bump the version (Release workflow) or tag the right commit."
  exit 1
fi

echo "MARKETING_VERSION $versions matches $want."
