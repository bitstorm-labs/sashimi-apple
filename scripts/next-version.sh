#!/bin/bash
# Prints the version the Release workflow should ship (#851).
#   next-version.sh <main's MARKETING_VERSION> [requested version]
# A requested version wins. Otherwise main's version is shipped as it is when
# no platform has a tag for it yet (a bump that merged but never released, e.g.
# a Release re-run after its bump PR stalled in the merge queue); once any tag
# for it exists, the next patch version is.
set -euo pipefail
current="$1"; requested="${2:-}"
if [ -n "$requested" ]; then echo "$requested"; exit 0; fi
if [ -z "$(git tag -l "v$current-beta*" "ios-v$current-beta*" "mac-v$current-beta*")" ]; then
  echo "$current"
else
  IFS=. read -r ma mi pa <<< "$current"
  echo "$ma.$mi.$((pa + 1))"
fi
