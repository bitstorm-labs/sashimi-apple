# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. It is the canonical project guidance shared with Codex through the `AGENTS.md` symlink.

## Project Overview

Sashimi is a native SwiftUI Jellyfin client for Apple TV, iPhone, and iPad. It targets tvOS 17+ and iOS 17+ and uses Swift 5.9. The tvOS and iOS apps share networking, authentication, media models, and playback logic where the behavior is genuinely cross-platform.

### Target Taxonomy

- **`Sashimi/`**: tvOS application UI, including remote-focus behavior, the tvOS player, and tvOS settings.
- **`SashimiMobile/`**: iPhone and iPad application UI, including phone tabs, iPad navigation, offline downloads, and mobile-only playback behavior.
- **`Shared/`**: cross-platform Jellyfin models, services, view models, session/authentication, playback selection, and shared components. Put behavior here only when both application targets need the same contract.
- **`TopShelf/`**: tvOS Top Shelf extension. Keep extension-specific content-provider behavior here.
- **`SashimiTests/`**: the tvOS-hosted unit-test target for shared and tvOS application behavior. Do not compile `Shared/` into the test bundle a second time; the test host provides those symbols.

The project is a single Universal Purchase product with separate tvOS and iOS targets. A feature is not complete if a change to shared behavior silently regresses the other platform.

## Build Commands

```bash
# Build with Swift Package Manager
swift build

# Build with Xcode (uses project.yml with XcodeGen)
xcodebuild -project Sashimi.xcodeproj -scheme Sashimi -destination 'platform=tvOS Simulator,name=Apple TV'

# Build the iOS app (iPhone/iPad)
xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPhone 16'

# Generate Xcode project from project.yml (requires XcodeGen)
xcodegen generate
```

## Claude Code helpers

`.claude/` holds this repo's automation (committed; `settings.local.json` is
personal and gitignored):

- **`/install-tvs`** — build the tvOS app and install it on both Apple TVs
- A `PostToolUse` hook runs `swiftlint --strict` on each edited `.swift` file, so
  violations surface at the edit rather than failing CI.

## Architecture

### MVVM Pattern
- **Views** (`Sashimi/Views/`): SwiftUI views organized by feature (Home, Auth, Library, Detail, Player, Components)
- **ViewModels** (`Shared/ViewModels/`): `@MainActor` `ObservableObject` classes managing view state (shared between the tvOS and iOS targets)
- **Models** (`Shared/Models/`): Codable DTOs matching Jellyfin API responses (shared between targets)

### Core Services
- **JellyfinClient** (`Shared/Services/JellyfinClient.swift`): Swift `actor` handling all Jellyfin REST API communication. Singleton accessed via `JellyfinClient.shared`. Manages authentication headers, device identification, and playback URL generation.
- **SessionManager** (`Shared/Services/SessionManager.swift`): `@MainActor` `ObservableObject` singleton managing auth state, server metadata in UserDefaults, access tokens in the Keychain, and session restoration.

### Data Flow
1. App entry (`SashimiApp.swift` or `SashimiMobileApp.swift`) injects `SessionManager` as an `@EnvironmentObject`
2. Root content shows the appropriate authentication flow or authenticated navigation based on `sessionManager.isAuthenticated`
3. Views create their own `@StateObject` view models, which call `JellyfinClient.shared` methods
4. API responses are decoded into `BaseItemDto` and related model types

### Key Model Types
- `BaseItemDto`: Universal media item (movies, series, episodes, seasons)
- `ItemType`: Enum distinguishing media types
- `MediaSourceInfo`/`MediaStream`: Playback stream metadata
- `PlaybackInfoResponse`: Contains transcoding URLs and direct play options

### Video Playback
`PlayerViewModel` handles playback via AVKit:
- Fetches `PlaybackInfoResponse` to determine best stream URL (transcoding vs direct)
- Reports playback progress to Jellyfin server every 5 seconds (and immediately on play/pause)
- Auto-resumes from saved progress when it exceeds the resume threshold setting (no dialog)
- Supports Up Next feature for continuous episode playback
- Preserves audio/subtitle selection, quality switching, trailers, and skip-intro/credits behavior when changing playback flows
- Mobile playback also coordinates Picture-in-Picture and offline downloaded media; tvOS and iOS presentation differences belong in their respective targets

### Dependencies
- **Nuke/NukeUI**: Image loading and caching (via SPM)

### YouTube Library Handling

The app has special handling for YouTube content (from Pinchflat). YouTube libraries differ from regular TV shows:

- **Detection**: Check `libraryName` for "youtube" (case insensitive), not `collectionType` (which is "tvshows" for both)
- **Series images**: Have poster.jpg, banner.jpg, fanart.jpg from Pinchflat
- **Season images**: Do NOT have images (unlike regular TV seasons)
- **Episode images**: Have their own Primary thumbnails embedded
- **Display preference**: Use series poster in rows, episode thumbnails only in episode detail hero

When adding new views that display media items, pass `libraryName` to `MediaPosterButton` to enable proper YouTube detection. The `isYouTubeStyle` computed property handles the logic.

## Feature Development Standards

### Target and architecture boundaries

- Classify a change by target before editing. Put shared behavior in `Shared/`, tvOS presentation and focus behavior in `Sashimi/`, mobile layouts/downloads/offline behavior in `SashimiMobile/`, and Top Shelf behavior in `TopShelf/`.
- Follow MVVM: views present state and user actions; `@MainActor` `ObservableObject` view models own UI state and orchestration; Codable Jellyfin DTOs belong in `Shared/Models/`; reusable server, auth, playback, and persistence behavior belongs in `Shared/Services/`.
- Route Jellyfin API calls through the actor-based `JellyfinClient`. Do not add ad-hoc URLSession calls from views, duplicate authentication headers, or bypass `SessionManager` for session state.
- Respect Swift concurrency. Keep UI-facing state on `@MainActor`, use actors for shared mutable service state, handle cancellation and errors deliberately, and do not add unsafe isolation annotations without documenting the invariant.

### UI and platform behavior

- Preserve tvOS remote focus and readable focus states, iPhone tab navigation, and iPad sidebar/adaptive layouts. Do not use size-class changes to swap the entire mobile root when device identity is the actual distinction.
- Reuse existing loading, empty, error, toast, image, theme, and navigation components before introducing variants. Keep business logic out of view composition and make loading/error transitions explicit so stale media is not displayed as current.
- When displaying media, preserve the YouTube rules above and pass `libraryName` through the component tree rather than reconstructing library type from `collectionType`.

### Domain, persistence, and security

- Playback changes must account for direct play/transcoding selection, progress reporting, resume behavior, subtitles, audio tracks, trailers, Up Next, offline downloads, and Picture-in-Picture where applicable.
- Treat persisted data as a compatibility surface. Server metadata and active-server state use UserDefaults, access tokens use the Keychain, certificate allowances/pins use per-host persisted settings, and mobile downloads use SwiftData plus app Documents storage. Preserve existing keys and add migrations when changing their meaning or shape.
- Keep server URLs, credentials, access tokens, certificate details, and user/media data out of logs and source control. Use the existing Keychain/session flows; do not broaden entitlements or App Transport Security exceptions without a concrete requirement.

### Tests and verification

- Add or update focused tests in `SashimiTests/` for model decoding, validation, URL construction, playback selection, session behavior, downloads, and view-model state transitions. Tests must exercise the production path and assert the behavior that changed, not merely echo mock data.
- For target-specific changes, build and test the affected Xcode scheme. For `Shared/` changes, validate both tvOS and iOS when the environment permits. Run SwiftLint in strict mode and use `swift build` only as a package-level check, not as a substitute for an affected Xcode build.
- Report exactly what was and was not verified. Distinguish simulator/build results from hardware-only behavior such as tvOS remote focus, offline playback, AVPlayer codec behavior, Picture-in-Picture, and physical-remote interaction.

### Generated project, dependencies, and assets

- `project.yml` is the source of truth for Xcode targets, build settings, entitlements, and package attachment. Update it and run `xcodegen generate` when needed; do not hand-edit generated project files.
- Respect the existing target/dependency graph. Keep Nuke/NukeUI image loading on the targets that use it and use `SashimiImagePipeline` so image requests share the app's caching and certificate-trust policy.
- Add images through the appropriate asset catalog. Preserve tvOS layered icon structures, iOS app-icon structures, and required scale/device variants.

## Git Workflow & CI

### Issue Tracking
**Always create a GitHub issue before starting work.** This ensures:
- Work is tracked and discoverable
- PRs can reference issues (`Fixes #123`)
- Progress is visible to all contributors

```bash
# Create an issue for new work
gh issue create --title "feat: add dark mode support" --body "Description of the feature"

# List open issues
gh issue list

# Reference issue in PR (auto-closes when merged)
gh pr create --title "feat: add dark mode" --body "Fixes #123"
```

For bug fixes, enhancements, or new features - create the issue first, then the branch and PR.

### Branch Protection
- **main** branch has protection rules enforced (including for admins)
- All changes MUST go through pull requests
- Required status checks: `Build tvOS App` and `SwiftLint`
- Never bypass PR requirements - create a branch and PR instead

### Creating Changes
```bash
# Create feature branch
git checkout -b feature/my-change

# Make changes, then commit
git add -A && git commit -m "feat: description"

# Push and create PR
git push -u origin feature/my-change
gh pr create --fill
```

### Testing Before Merge
**Merge on green CI.** Hardware confirmation is no longer a gate on merging.

CI must be green first — `Build tvOS App`, `Build iOS App` and `SwiftLint` (strict).
Beyond that, use judgement:

- State plainly in the PR what was and was not verified. "Builds and tests pass"
  is not the same claim as "exercised on a device", and conflating them is how a
  broken build reaches a shipped app.
- Anything that can only be judged on real hardware — focus traversal, offline
  playback, AVPlayer behaviour, anything involving a physical remote — should say
  so explicitly rather than implying it was checked.
- The gate that still matters is the deploy tag, not the merge. A merge is
  recoverable; a TestFlight build in someone's hands is less so.

### CI Monitoring
After pushing changes or creating PRs, always monitor CI until completion:
```bash
# List recent CI runs
gh run list --limit 5

# Watch a specific run in real-time
gh run watch

# View failed run details
gh run view <run-id> --log-failed
```

### SwiftLint
- CI runs SwiftLint in strict mode (warnings fail the build)
- Run locally before committing: `swiftlint lint`
- Auto-fix issues: `swiftlint --fix`
- Documented exceptions use inline `swiftlint:disable` comments with explanations

## Updating the App Icon

tvOS app icons use a layered image stack (Back, Middle, Front) for parallax effects. To update the app icon:

### Icon Requirements
- **Dimensions**: 400x240 (1x), 800x480 (2x)
- **Format**: PNG with dark background (#1a1a2e)
- **Files to update** (same image for all layers):
  - `App Icon.imagestack/Back.imagestacklayer/Content.imageset/icon_back.png` (1x)
  - `App Icon.imagestack/Back.imagestacklayer/Content.imageset/icon_back@2x.png` (2x)
  - `App Icon.imagestack/Front.imagestacklayer/Content.imageset/icon_front.png` (1x)
  - `App Icon.imagestack/Front.imagestacklayer/Content.imageset/icon_front@2x.png` (2x)
  - `App Icon.imagestack/Middle.imagestacklayer/Content.imageset/icon_middle.png` (1x)
  - `App Icon.imagestack/Middle.imagestacklayer/Content.imageset/icon_middle@2x.png` (2x)

All files are in: `Sashimi/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets/`

### Creating Icons with ImageMagick
```bash
# Example: Create icon from source image with positioning adjustments
# -trim removes whitespace, -resize scales, -splice adds padding, -extent sets final size
magick source.png -trim +repage -resize 390x -background '#1a1a2e' \
  -gravity north -splice 0x100 \  # Add 100px top padding to shift down
  -gravity east -splice 20x0 \    # Add 20px right padding to shift left
  -gravity center -extent 400x240 icon_1x.png

magick source.png -trim +repage -resize 780x -background '#1a1a2e' \
  -gravity north -splice 0x200 \
  -gravity east -splice 40x0 \
  -gravity center -extent 800x480 icon_2x.png
```

### Critical: Force Asset Recompilation
**tvOS aggressively caches app icons.** After updating icon files, you MUST:

1. Delete derived data before building:
   ```bash
   rm -rf /Users/mondo/Library/Developer/Xcode/DerivedData/Sashimi-*
   ```

2. Build fresh:
   ```bash
   xcodebuild -project Sashimi.xcodeproj -scheme Sashimi \
     -destination 'platform=tvOS,id=DEVICE_ID' -configuration Release build
   ```

3. Uninstall and reinstall the app (install alone may use cached icon):
   ```bash
   xcrun devicectl device uninstall app --device DEVICE_ID com.mondominator.sashimi
   xcrun devicectl device install app --device DEVICE_ID \
     ~/Library/Developer/Xcode/DerivedData/Sashimi-*/Build/Products/Release-appletvos/Sashimi.app
   ```

**Warning**: Be careful with `rm -rf` wildcards - ensure you're only deleting DerivedData, not source folders.

## Adding Alternate App Icons

tvOS alternate icons must be **direct imagestacks** in Assets.xcassets (NOT in brandassets folders - those don't work for alternates).

### Step 1: Create the Imagestack Structure

For a new icon called `MyIcon`, create this folder structure in `Sashimi/Resources/Assets.xcassets/`:

```
MyIcon.imagestack/
├── Contents.json
├── Back.imagestacklayer/
│   ├── Contents.json
│   └── Content.imageset/
│       ├── Contents.json
│       ├── icon.png      (400x240)
│       └── icon@2x.png   (800x480)
├── Middle.imagestacklayer/
│   ├── Contents.json
│   └── Content.imageset/
│       ├── Contents.json
│       ├── icon.png      (400x240)
│       └── icon@2x.png   (800x480)
└── Front.imagestacklayer/
    ├── Contents.json
    └── Content.imageset/
        ├── Contents.json
        ├── icon.png      (400x240)
        └── icon@2x.png   (800x480)
```

### Step 2: Contents.json Files

**MyIcon.imagestack/Contents.json:**
```json
{
  "info" : { "author" : "xcode", "version" : 1 },
  "layers" : [
    { "filename" : "Front.imagestacklayer" },
    { "filename" : "Middle.imagestacklayer" },
    { "filename" : "Back.imagestacklayer" }
  ]
}
```

**Each .imagestacklayer/Contents.json:**
```json
{
  "info" : { "author" : "xcode", "version" : 1 }
}
```

**Each Content.imageset/Contents.json:**
```json
{
  "images" : [
    { "filename" : "icon.png", "idiom" : "tv", "scale" : "1x" },
    { "filename" : "icon@2x.png", "idiom" : "tv", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

### Step 3: Create Preview Image (for Settings)

Create `AppIconPreviewMyIcon.imageset/` in Assets.xcassets with a preview image for the settings screen.

### Step 4: Update project.yml

Add the icon name to `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`:

```yaml
ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES: "CatIcon ChopsticksIcon WhitefishIcon MyIcon"
```

### Step 5: Update Info.plist

Add the icon name to the `CFBundleAlternateIcons` array:

```xml
<key>CFBundleAlternateIcons</key>
<array>
    <string>CatIcon</string>
    <string>ChopsticksIcon</string>
    <string>WhitefishIcon</string>
    <string>MyIcon</string>
</array>
```

### Step 6: Update SettingsView.swift

Add the icon to the `icons` array:

```swift
private let icons: [AppIconOption] = [
    AppIconOption(id: nil, name: "Default", previewImage: "AppIconPreviewDefault"),
    // ... existing icons ...
    AppIconOption(id: "MyIcon", name: "My Icon", previewImage: "AppIconPreviewMyIcon")
]
```

### Quick Copy Method

Copy an existing imagestack and rename:
```bash
cd Sashimi/Resources/Assets.xcassets
cp -r CatIcon.imagestack MyIcon.imagestack
# Then replace the icon.png and icon@2x.png files in each layer
```

## Releasing: bump MARKETING_VERSION every TestFlight build

`MARKETING_VERSION` is hardcoded in **`project.yml`** in three places (tvOS, iOS,
and the shared target) — `xcodegen` writes it into the pbxproj, so editing the
pbxproj directly is pointless. Fastlane only auto-increments the *build* number
(epoch seconds); nothing touches the marketing version.

**Bump all three before triggering a TestFlight deploy.** Shipping several builds
under one version makes them indistinguishable in TestFlight and in Jellyfin's
`ApplicationVersion` — during the 2026-08-03 playback investigation three builds
all reported `1.2.0`, so neither the user nor the server logs could say which
code was running while a fix was being tested.

```bash
sed -i '' 's/MARKETING_VERSION: 1\.2\.0/MARKETING_VERSION: 1.2.1/g' project.yml
```
