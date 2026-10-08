#!/bin/bash

# Version bump script for Sashimi
# Usage: ./scripts/bump-version.sh [major|minor|patch|X.Y.Z]
# Portable (BSD and GNU sed): the Release workflow runs it on Linux.

set -e

cd "$(dirname "$0")/.."

BUMP_TYPE=${1:-patch}
PROJECT_FILE="project.yml"

# Get current version
CURRENT_VERSION=$(grep "MARKETING_VERSION:" "$PROJECT_FILE" | head -1 | sed 's/.*MARKETING_VERSION: //' | tr -d '"')

if [ -z "$CURRENT_VERSION" ]; then
    echo "Error: Could not find current version in $PROJECT_FILE"
    exit 1
fi

# Parse version components
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# Bump version based on type
case $BUMP_TYPE in
    [0-9]*.[0-9]*.[0-9]*)
        if ! [[ "$BUMP_TYPE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Error: '$BUMP_TYPE' is not X.Y.Z"
            exit 1
        fi
        IFS='.' read -r MAJOR MINOR PATCH <<< "$BUMP_TYPE"
        ;;
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
    *)
        echo "Usage: $0 [major|minor|patch|X.Y.Z]"
        echo "  major - Bump major version (X.0.0)"
        echo "  minor - Bump minor version (x.X.0)"
        echo "  patch - Bump patch version (x.x.X)"
        exit 1
        ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"

echo "Bumping version: $CURRENT_VERSION -> $NEW_VERSION"

# Update project.yml. This bumps every target whose MARKETING_VERSION matches
# Global on purpose: Sashimi, SashimiMobile and TopShelf ship under ONE App Store
# listing (Universal Purchase), so their marketing versions stay in lockstep.
# This sed rewrites all three.
sed -i.bak "s/MARKETING_VERSION: $CURRENT_VERSION/MARKETING_VERSION: $NEW_VERSION/g" "$PROJECT_FILE" && rm -f "$PROJECT_FILE.bak"

# Get current build number and increment
CURRENT_BUILD=$(grep "CURRENT_PROJECT_VERSION:" "$PROJECT_FILE" | head -1 | sed 's/.*CURRENT_PROJECT_VERSION: //')
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "Bumping build: $CURRENT_BUILD -> $NEW_BUILD"

# Same global rewrite as above -- all targets share the build number.
sed -i.bak "s/CURRENT_PROJECT_VERSION: $CURRENT_BUILD/CURRENT_PROJECT_VERSION: $NEW_BUILD/g" "$PROJECT_FILE" && rm -f "$PROJECT_FILE.bak"

# Regenerate Xcode project
if command -v xcodegen &> /dev/null; then
    echo "Regenerating Xcode project..."
    xcodegen generate
fi

echo ""
echo "Version updated successfully!"
echo "  Version: $NEW_VERSION"
echo "  Build: $NEW_BUILD"
echo ""
echo "Next steps (see docs/RELEASING.md):"
echo "  Prefer the one-click Release workflow, which does the bump, merge, tags"
echo "  and deploys for you:  gh workflow run release.yml -f version=$NEW_VERSION"
echo ""
echo "  By hand: commit, merge to main on green CI, then tag the merge commit"
echo "  (v$NEW_VERSION-beta1 tvOS, ios-v$NEW_VERSION-beta1 iOS, mac-v$NEW_VERSION-beta1 Mac)."
