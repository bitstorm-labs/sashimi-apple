# Sashimi iPad Port Design

## Overview

Port the Sashimi tvOS Jellyfin client to iPad with full feature parity.

## Key Decisions

- **Scope**: Full feature parity with tvOS app
- **Structure**: Separate targets with shared sources (not conditional compilation)
- **Platform**: iOS 17+, iPad only (no iPhone initially)
- **Navigation**: Sidebar navigation (NavigationSplitView)
- **Player**: System AVPlayerViewController with custom overlay for skip/quality/subtitles

## Project Structure

```
sashimi/
├── Shared/                     # Extracted shared code
│   ├── Models/                 # Codable DTOs (from Sashimi/Models)
│   ├── Services/               # JellyfinClient, SessionManager (from Sashimi/Services)
│   └── ViewModels/             # All ViewModels (from Sashimi/ViewModels)
│
├── Sashimi/                    # tvOS app (unchanged structure)
│   ├── App/
│   ├── Views/                  # tvOS-specific views
│   ├── Theme/
│   └── Resources/
│
├── SashimiMobile/              # iOS app (new)
│   ├── App/
│   │   └── SashimiMobileApp.swift
│   ├── Views/
│   │   ├── Navigation/
│   │   │   └── SidebarView.swift
│   │   ├── Home/
│   │   ├── Library/
│   │   ├── Player/
│   │   ├── Search/
│   │   ├── Settings/
│   │   └── Components/
│   ├── Theme/
│   │   └── MobileTheme.swift
│   ├── Resources/
│   │   └── Assets.xcassets
│   └── Info.plist
│
├── TopShelf/                   # tvOS only (unchanged)
├── project.yml                 # Updated with SashimiMobile target
└── Package.swift               # Updated to support iOS 17
```

## Navigation Architecture

iPad uses `NavigationSplitView` with collapsible sidebar:

```swift
struct SidebarView: View {
    @State private var selection: SidebarItem? = .home

    enum SidebarItem: String, CaseIterable {
        case home, library, search, settings
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue.capitalized, systemImage: item.icon)
            }
            .navigationTitle("Sashimi")
        } detail: {
            switch selection {
            case .home: HomeView()
            case .library: LibraryView()
            case .search: SearchView()
            case .settings: SettingsView()
            case nil: HomeView()
            }
        }
    }
}
```

## Theme & Sizing

iPad sizes are roughly 40-50% of tvOS values:

| Element | tvOS | iPad |
|---------|------|------|
| Display title | 76pt | 34pt |
| Headline | 40pt | 22pt |
| Body text | 24pt | 15pt |
| Poster width | 220px | 140px |
| Poster height | 330px | 210px |
| Landscape card | 320x180 | 220x124 |
| Section padding | 80pt | 16pt |

## Video Player

Use system `AVPlayerViewController` with minimal custom overlay:

- **System handles**: Play/pause, scrubbing, PiP, AirPlay, volume
- **Custom overlay**: Skip Intro/Credits buttons, quality/subtitle/audio menu
- **Reuse**: `PlayerViewModel` unchanged, handles stream URLs and progress reporting

## Component Changes

| tvOS Pattern | iPad Replacement |
|--------------|------------------|
| `@FocusState` + focus modifiers | Standard `Button` with tap |
| `.onExitCommand` | System back navigation |
| `.onMoveCommand` | Not needed (touch) |
| `.onPlayPauseCommand` | Not needed |
| Long press gesture | `.contextMenu { }` |
| 120pt min hit target | 44pt min hit target |
| Focus scale animation | Press highlight |

## Implementation Phases

### Phase 1: Project Setup
- Create `Shared/` folder, move Models/Services/ViewModels
- Add `SashimiMobile` target to project.yml
- Update Package.swift for iOS 17
- Basic app entry point that builds

### Phase 2: Navigation Shell
- Create `SidebarView` with navigation structure
- Stub placeholder views for each section
- Verify on iPad simulator

### Phase 3: Theme & Core Components
- Create `MobileTheme.swift`
- Build `MediaPosterButton`, `MediaRow`, `PosterImage`

### Phase 4: Home Screen
- Build `HomeView` with Continue Watching, recently added
- Wire to existing `HomeViewModel`

### Phase 5: Library & Detail
- Build `LibraryView` with grid
- Build `MediaDetailView` for movies/series/episodes
- Navigation flow: library → detail → play

### Phase 6: Video Player
- Build `MobilePlayerView` with system controls
- Skip intro/credits overlay
- Quality/subtitle/audio menu

### Phase 7: Search & Settings
- Build `SearchView` with iOS search bar
- Build `SettingsView`

### Phase 8: Polish
- App icon and launch screen
- Test on various iPad sizes
- Error handling edge cases

## What's Not Included

- **TopShelf extension**: tvOS only, not applicable to iOS
- **Alternate app icons**: Can add later with iOS-specific implementation
- **iPhone support**: Can add later with additional layout work
