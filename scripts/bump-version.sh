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
# the tvOS app's current version (Sashimi + TopShelf, which are kept in sync).
# The iOS target (SashimiMobile) has an independently-managed MARKETING_VERSION
# and is intentionally NOT touched here.
sed -i '' "s/MARKETING_VERSION: $CURRENT_VERSION/MARKETING_VERSION: $NEW_VERSION/g" "$PROJECT_FILE"

# Get current build number and increment
CURRENT_BUILD=$(grep "CURRENT_PROJECT_VERSION:" "$PROJECT_FILE" | head -1 | sed 's/.*CURRENT_PROJECT_VERSION: //')
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "Bumping build: $CURRENT_BUILD -> $NEW_BUILD"

# Same match-based behavior as above: bumps Sashimi + TopShelf, not SashimiMobile.
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
echo "Next steps:"
echo "  1. Review changes: git diff"
echo "  2. Commit: git commit -am 'chore: bump version to $NEW_VERSION'"
echo "  3. Tag: git tag -a v$NEW_VERSION -m 'Release $NEW_VERSION'"
echo "  4. Push: git push && git push --tags"
