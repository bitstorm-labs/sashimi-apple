#!/bin/bash
# Tests for scripts/next-version.sh in a throwaway git repo.
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/next-version.sh"
repo=$(mktemp -d); trap 'rm -rf "$repo"' EXIT
cd "$repo"
git init -q; git config user.email t@t; git config user.name t
git commit -q --allow-empty -m init
fails=0
expect() { # expect <want> <description> <args...>
  local want="$1" desc="$2"; shift 2
  local got; got=$("$script" "$@")
  if [ "$got" = "$want" ]; then echo "ok   $desc"; else echo "FAIL $desc (got $got, want $want)"; fails=1; fi
}

git tag v1.6.82-beta1; git tag ios-v1.6.82-beta1; git tag mac-v1.6.82-beta1
expect 1.6.83 "released version: next patch" 1.6.82
expect 1.6.83 "bump merged but never tagged: ship it, don't bump again" 1.6.83
git tag ios-v1.6.83-beta1
expect 1.6.84 "any platform tagged counts as released" 1.6.83
expect 2.0.0 "a requested version wins" 1.6.83 2.0.0
expect 1.6.83 "a requested re-release of main's version" 1.6.83 1.6.83

exit $fails
