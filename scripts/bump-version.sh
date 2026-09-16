#!/bin/bash

# Version bump script for Sashimi
# Usage: ./scripts/bump-version.sh [major|minor|patch]

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
        echo "Usage: $0 [major|minor|patch]"
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
sed -i '' "s/MARKETING_VERSION: $CURRENT_VERSION/MARKETING_VERSION: $NEW_VERSION/g" "$PROJECT_FILE"

# Get current build number and increment
CURRENT_BUILD=$(grep "CURRENT_PROJECT_VERSION:" "$PROJECT_FILE" | head -1 | sed 's/.*CURRENT_PROJECT_VERSION: //')
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "Bumping build: $CURRENT_BUILD -> $NEW_BUILD"

# Same global rewrite as above -- all targets share the build number.
sed -i '' "s/CURRENT_PROJECT_VERSION: $CURRENT_BUILD/CURRENT_PROJECT_VERSION: $NEW_BUILD/g" "$PROJECT_FILE"

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
echo "  1. Review changes: git diff"
echo "  2. Commit:  git commit -am 'chore: bump version to $NEW_VERSION'"
echo "  3. Merge to main with CI green."
echo ""
echo "  4. Tag BOTH platforms -- a plain 'v$NEW_VERSION' tag does NOT ship to"
echo "     TestFlight (it runs release.yml, which only builds an artifact):"
echo "       git tag -a v$NEW_VERSION-beta1     -m 'Sashimi $NEW_VERSION-beta1 (tvOS)'"
echo "       git tag -a ios-v$NEW_VERSION-beta1 -m 'Sashimi $NEW_VERSION-beta1 (iOS/iPad)'"
echo "       git push origin v$NEW_VERSION-beta1 ios-v$NEW_VERSION-beta1"
echo ""
echo "  5. Confirm BOTH deploy workflows started (not 'Release'):"
echo "       gh run list --limit 5"
