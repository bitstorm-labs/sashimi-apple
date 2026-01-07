# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sashimi is a tvOS client for Jellyfin media servers, built with SwiftUI. It targets tvOS 17+ and uses Swift 5.9.

## Build Commands

```bash
# Build with Swift Package Manager
swift build

# Build with Xcode (uses project.yml with XcodeGen)
xcodebuild -project Sashimi.xcodeproj -scheme Sashimi -destination 'platform=tvOS Simulator,name=Apple TV'

# Generate Xcode project from project.yml (requires XcodeGen)
xcodegen generate
```

## Architecture

### MVVM Pattern
- **Views** (`Sashimi/Views/`): SwiftUI views organized by feature (Home, Auth, Library, Detail, Player, Components)
- **ViewModels** (`Sashimi/ViewModels/`): `@MainActor` `ObservableObject` classes managing view state
- **Models** (`Sashimi/Models/`): Codable DTOs matching Jellyfin API responses

### Core Services
- **JellyfinClient** (`Services/JellyfinClient.swift`): Swift `actor` handling all Jellyfin REST API communication. Singleton accessed via `JellyfinClient.shared`. Manages authentication headers, device identification, and playback URL generation.
- **SessionManager** (`Services/SessionManager.swift`): `@MainActor` `ObservableObject` singleton managing auth state, token persistence via UserDefaults, and session restoration.

### Data Flow
1. App entry (`SashimiApp.swift`) injects `SessionManager` as `@EnvironmentObject`
2. `ContentView` shows `ServerConnectionView` or `MainTabView` based on `sessionManager.isAuthenticated`
3. Views create their own `@StateObject` ViewModels which call `JellyfinClient.shared` methods
4. API responses are decoded into `BaseItemDto` and related model types

### Key Model Types
- `BaseItemDto`: Universal media item (movies, series, episodes, seasons)
- `ItemType`: Enum distinguishing media types
- `MediaSourceInfo`/`MediaStream`: Playback stream metadata
- `PlaybackInfoResponse`: Contains transcoding URLs and direct play options

### Video Playback
`PlayerViewModel` handles playback via AVKit:
- Fetches `PlaybackInfoResponse` to determine best stream URL (transcoding vs direct)
- Reports playback progress to Jellyfin server every 10 seconds
- Supports resume from last position via `userData.playbackPositionTicks`

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

## Git Workflow & CI

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
