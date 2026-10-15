#!/bin/bash
# Tests for scripts/app-changed.sh in a throwaway git repo.
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/app-changed.sh"
repo=$(mktemp -d); trap 'rm -rf "$repo"' EXIT
cd "$repo"
git init -q; git config user.email t@t; git config user.name t
fails=0
expect() { # expect <exit code> <description>
  local got=0; "$script" >/dev/null || got=$?
  if [ "$got" = "$1" ]; then echo "ok   $2"; else echo "FAIL $2 (exit $got, want $1)"; fails=1; fi
}
commit() { mkdir -p "$(dirname "$1")"; echo "$2" >> "$1"; git add -A; git commit -qm "$3"; }

commit README.md hi "init"
expect 2 "no release tag yet"

commit Shared/A.swift a "app"
printf 'targets:\n  MARKETING_VERSION: "1.0.0"\n  OTHER: x\n' > project.yml; git add -A; git commit -qm "project"
git tag v1.0.0-beta1
expect 1 "HEAD is the release tag"

commit docs/x.md doc "docs"
expect 1 "only docs changed"

sed -i.bak 's/1.0.0/1.0.1/' project.yml; rm project.yml.bak; git commit -qam "chore: 1.0.1"
expect 1 "only the version bump in project.yml"

sed -i.bak 's/OTHER: x/OTHER: y/' project.yml; rm project.yml.bak; git commit -qam "settings"
expect 0 "a real project.yml change"

git tag v1.0.1-beta1
commit Sashimi/B.swift b "tvOS code"
expect 0 "app code changed"

exit $fails
