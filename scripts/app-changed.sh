#!/bin/bash
# Has app code changed since the last release tag? Used by Auto release (at
# merge time) and again by Release (when its run actually starts), because a
# release queued behind another one may find that run already shipped it.
#
#   scripts/app-changed.sh           # compares HEAD with the newest v*-beta* tag
#
# Prints the changed app paths. Exit 0 = changed, 1 = nothing to ship,
# 2 = no release tag reachable from HEAD.
set -euo pipefail

last=$(git describe --tags --abbrev=0 --match 'v*-beta*' HEAD 2>/dev/null || true)
if [ -z "$last" ]; then
  echo "No earlier release tag."
  exit 2
fi
changed=$(git diff --name-only "$last" HEAD -- \
  Sashimi SashimiMobile Shared TopShelf Vendor project.yml Package.swift Package.resolved \
  | grep -vxE 'project\.yml' || true)
# project.yml counts unless the only change in it is the release version bump.
if git diff --quiet "$last" HEAD -- project.yml; then :; else
  if git diff -U0 "$last" HEAD -- project.yml | grep -E '^[+-][^+-]' | grep -vqE '^[+-][[:space:]]*MARKETING_VERSION:'; then
    changed=$(printf '%s\nproject.yml' "$changed" | sed '/^$/d')
  fi
fi
if [ -z "$changed" ]; then
  echo "No app code changed since $last."
  exit 1
fi
echo "App code changed since $last:"
echo "$changed"
