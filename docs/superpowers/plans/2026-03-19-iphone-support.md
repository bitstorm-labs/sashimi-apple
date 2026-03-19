# iPhone Support Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add iPhone support to Sashimi with dedicated phone views, tab bar navigation, and stacked detail layouts while reusing existing components and shared services.

**Architecture:** Single universal target (`TARGETED_DEVICE_FAMILY: "1,2"`). `ContentView` branches on `horizontalSizeClass`: compact → `PhoneTabView` (new tab bar), regular → `MainNavigationView` (existing sidebar). Five new phone-specific view files, five existing views get minor parameter additions.

**Tech Stack:** SwiftUI, SwiftData, NukeUI, iOS 17+

**Spec:** `docs/superpowers/specs/2026-03-19-iphone-support-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `project.yml` | Modify | Change `TARGETED_DEVICE_FAMILY` to `"1,2"`, add iPhone orientations |
| `SashimiMobile/Theme/MobileTheme.swift` | Modify | Add `PhoneSizing` enum |
| `SashimiMobile/App/SashimiMobileApp.swift` | Modify | Add size class branching in `ContentView` |
| `SashimiMobile/Views/Components/MobileHeroSection.swift` | Modify | Add optional `height` parameter |
| `SashimiMobile/Views/Components/MobileContinueWatchingCard.swift` | No change | Already accepts `width` and `cardWidth` params |
| `SashimiMobile/Views/Components/MobileRecentlyAddedRow.swift` | Modify | Add `cardWidth` parameter for phone poster sizing |
| `SashimiMobile/Views/Library/MobileLibraryBrowseView.swift` | Modify | Size class grid minimum |
| `SashimiMobile/Views/Components/MobileMediaRow.swift` | Modify | Size class grid minimum in `MobileMediaGridView` |
| `SashimiMobile/Views/Search/MobileSearchView.swift` | Modify | Add NavigationLink + poster images to search results |
| `SashimiMobile/Views/Phone/PhoneTabView.swift` | Create | Tab bar with 5 tabs |
| `SashimiMobile/Views/Phone/PhoneLibrariesTab.swift` | Create | Library list with drill-down |
| `SashimiMobile/Views/Phone/PhoneHomeView.swift` | Create | Phone home screen |
| `SashimiMobile/Views/Phone/PhoneDetailView.swift` | Create | Stacked vertical detail view |
| `SashimiMobile/Views/Phone/PhoneEpisodeSheet.swift` | Create | Episode bottom sheet |

---

## Chunk 1: Foundation (Config + Theme + Branching)

### Task 1: Update project.yml and theme

**Files:**
- Modify: `project.yml:131`
- Modify: `SashimiMobile/Theme/MobileTheme.swift:105`

- [ ] **Step 1: Change TARGETED_DEVICE_FAMILY to universal**

In `project.yml`, change line 131:
```yaml
        TARGETED_DEVICE_FAMILY: "1,2"
```

Add iPhone orientations after the iPad orientations block (after line 121):
```yaml
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
```

- [ ] **Step 2: Add PhoneSizing to MobileTheme.swift**

Add after the `MobileSizing` enum (after line 105):
```swift
// MARK: - Phone Sizing

enum PhoneSizing {
    static let posterWidth: CGFloat = 110
    static let posterHeight: CGFloat = 165
    static let heroHeight: CGFloat = 250
    static let continueWatchingWidth: CGFloat = 200
    static let episodeCardHeight: CGFloat = 80
}
```

- [ ] **Step 3: Regenerate Xcode project and build**

Run:
```bash
xcodegen generate
xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add project.yml SashimiMobile/Theme/MobileTheme.swift
git commit -m "feat: enable universal target and add phone sizing constants

Change TARGETED_DEVICE_FAMILY to 1,2 (iPhone + iPad).
Add PhoneSizing enum with phone-appropriate dimensions.
Add iPhone orientation support to Info.plist.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: Add size class branching in ContentView

**Files:**
- Modify: `SashimiMobile/App/SashimiMobileApp.swift:41-60`

- [ ] **Step 1: Create placeholder PhoneTabView**

Create `SashimiMobile/Views/Phone/PhoneTabView.swift`:
```swift
import SwiftUI

struct PhoneTabView: View {
    var body: some View {
        Text("Phone UI")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MobileColors.background)
    }
}
```

- [ ] **Step 2: Add size class branching to ContentView**

Replace the `ContentView` struct in `SashimiMobileApp.swift` (lines 41-60) with:
```swift
struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sessionManager.isAuthenticated {
                Group {
                    if sizeClass == .compact {
                        PhoneTabView()
                    } else {
                        MainNavigationView()
                    }
                }
                .task {
                    await DownloadManager.shared.syncPendingProgress()
                }
            } else {
                MobileAuthView()
            }
        }
        .task {
            await sessionManager.restoreSession()
        }
    }
}
```

- [ ] **Step 3: Regenerate project and build**

Run:
```bash
xcodegen generate
xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Test on iPhone simulator**

Run:
```bash
xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

Verify: Launch on iPhone simulator should show "Phone UI" placeholder after login. Launch on iPad simulator should show existing sidebar navigation.

- [ ] **Step 5: Commit**

```bash
git add SashimiMobile/App/SashimiMobileApp.swift SashimiMobile/Views/Phone/PhoneTabView.swift
git commit -m "feat: add size class branching for iPhone vs iPad navigation

ContentView now checks horizontalSizeClass: compact shows PhoneTabView
(placeholder), regular shows existing MainNavigationView.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Chunk 2: Existing View Adaptations

### Task 3: Add height parameter to MobileHeroSection

**Files:**
- Modify: `SashimiMobile/Views/Components/MobileHeroSection.swift:4,197-198`

- [ ] **Step 1: Add height parameter**

Add `height` parameter to `MobileHeroSection` struct (after line 7):
```swift
    let height: CGFloat

    init(
        items: [BaseItemDto],
        libraryNames: [String: String],
        height: CGFloat = 180,
        @ViewBuilder destination: @escaping (BaseItemDto) -> Destination
    ) {
        self.items = items
        self.libraryNames = libraryNames
        self.height = height
        self.destination = destination
    }
```

Note: The struct currently has `let items`, `let libraryNames`, `let destination` as stored properties with no explicit init. Adding an explicit `init` with a default `height: CGFloat = 180` keeps existing callers working.

- [ ] **Step 2: Use the height property**

Change line 198 from:
```swift
            .frame(height: 180)
```
to:
```swift
            .frame(height: height)
```

- [ ] **Step 3: Build to verify existing callers still compile**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add SashimiMobile/Views/Components/MobileHeroSection.swift
git commit -m "feat: add configurable height to MobileHeroSection

Adds height parameter with default of 180pt (iPad). Phone views
can pass PhoneSizing.heroHeight (250pt) for taller hero sections.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4: Add size class grid minimum to MobileLibraryBrowseView

**Files:**
- Modify: `SashimiMobile/Views/Library/MobileLibraryBrowseView.swift:29-31`

- [ ] **Step 1: Add size class and adaptive columns**

Add environment property at the top of the struct (after line 8):
```swift
    @Environment(\.horizontalSizeClass) private var sizeClass
```

Change the `columns` computed property (lines 29-31) from:
```swift
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: MobileSizing.posterWidth), spacing: MobileSpacing.md)]
    }
```
to:
```swift
    private var columns: [GridItem] {
        let minWidth = sizeClass == .compact ? PhoneSizing.posterWidth : MobileSizing.posterWidth
        return [GridItem(.adaptive(minimum: minWidth), spacing: MobileSpacing.md)]
    }
```

Also update the NavigationLink destination on line 50-51 — currently it hardcodes `MobileDetailView`. On phone it should use `PhoneDetailView`. Add a helper:

Actually, for now keep `MobileDetailView` — we'll address the detail view routing in Chunk 3 when `PhoneDetailView` exists. The library browse view will work on phone with the grid fix; detail view routing can be added later.

- [ ] **Step 2: Also update poster width in the grid cards (line 54)**

Change line 54 from:
```swift
                            width: MobileSizing.posterWidth,
```
to:
```swift
                            width: sizeClass == .compact ? PhoneSizing.posterWidth : MobileSizing.posterWidth,
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add SashimiMobile/Views/Library/MobileLibraryBrowseView.swift
git commit -m "feat: adaptive grid columns for iPhone (3-col) vs iPad (varies)

Use PhoneSizing.posterWidth (110pt) as grid minimum on compact size
class, producing 3 columns on ~390pt iPhone screens.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 5: Update MobileMediaGridView grid minimum

**Files:**
- Modify: `SashimiMobile/Views/Components/MobileMediaRow.swift:152-204`

- [ ] **Step 1: Add size class to MobileMediaGridView**

Add environment property to `MobileMediaGridView` (after line 157):
```swift
    @Environment(\.horizontalSizeClass) private var sizeClass
```

Update the `columns` computed property (lines 201-203) from:
```swift
    private var columns: [GridItem] {
        let minWidth = isYouTubeLibrary && !isCircularStyle ? MobileSizing.landscapeCardWidth : MobileSizing.posterWidth
        return [GridItem(.adaptive(minimum: minWidth), spacing: MobileSpacing.md)]
    }
```
to:
```swift
    private var columns: [GridItem] {
        let defaultWidth = sizeClass == .compact ? PhoneSizing.posterWidth : MobileSizing.posterWidth
        let minWidth = isYouTubeLibrary && !isCircularStyle ? MobileSizing.landscapeCardWidth : defaultWidth
        return [GridItem(.adaptive(minimum: minWidth), spacing: MobileSpacing.md)]
    }
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add SashimiMobile/Views/Components/MobileMediaRow.swift
git commit -m "feat: adaptive grid minimum in MobileMediaGridView for phone

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 5b: Add cardWidth parameter to MobileRecentlyAddedRow

**Files:**
- Modify: `SashimiMobile/Views/Components/MobileRecentlyAddedRow.swift:58-62,144`

- [ ] **Step 1: Add cardWidth parameter**

Add `cardWidth` to the stored properties (after line 62):
```swift
    let cardWidth: CGFloat
```

Add an explicit init with default value:
```swift
    init(
        libraryId: String,
        libraryName: String,
        collectionType: String?,
        cardWidth: CGFloat = MobileSizing.posterWidth,
        @ViewBuilder destination: @escaping (BaseItemDto) -> Destination
    ) {
        self.libraryId = libraryId
        self.libraryName = libraryName
        self.collectionType = collectionType
        self.cardWidth = cardWidth
        self.destination = destination
    }
```

- [ ] **Step 2: Use cardWidth in posterCard**

Change line 144 from:
```swift
            width: MobileSizing.posterWidth,
```
to:
```swift
            width: cardWidth,
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add SashimiMobile/Views/Components/MobileRecentlyAddedRow.swift
git commit -m "feat: add cardWidth parameter to MobileRecentlyAddedRow

Default remains MobileSizing.posterWidth for iPad. Phone views
can pass PhoneSizing.posterWidth for smaller cards.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 6: Fix MobileSearchView — add NavigationLink + poster images

**Files:**
- Modify: `SashimiMobile/Views/Search/MobileSearchView.swift:29-31,61-95`

- [ ] **Step 1: Add NukeUI import and wrap results in NavigationLink**

Add `import NukeUI` at line 2.

Change the ForEach in the search results (line 29-31) from:
```swift
                ForEach(searchResults, id: \.id) { item in
                    SearchResultRow(item: item)
                }
```
to:
```swift
                ForEach(searchResults, id: \.id) { item in
                    NavigationLink {
                        MobileDetailView(item: item)
                    } label: {
                        SearchResultRow(item: item)
                    }
                }
```

- [ ] **Step 2: Add poster images to SearchResultRow**

Replace the `SearchResultRow` struct (lines 61-95) with:
```swift
private struct SearchResultRow: View {
    let item: BaseItemDto

    private var posterURL: URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: "\(serverURL)/Items/\(item.id)/Images/Primary?maxWidth=200")
    }

    var body: some View {
        HStack(spacing: 12) {
            LazyImage(url: posterURL) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(MobileColors.cardBackground)
                        .overlay {
                            Image(systemName: iconForType)
                                .foregroundStyle(MobileColors.textTertiary)
                        }
                }
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name ?? "Unknown")
                    .font(MobileTypography.title)
                    .foregroundStyle(MobileColors.textPrimary)

                if let year = item.productionYear {
                    Text(String(year))
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textSecondary)
                }

                if let type = item.type {
                    Text(type.rawValue.capitalized)
                        .font(MobileTypography.captionSmall)
                        .foregroundStyle(MobileColors.textTertiary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var iconForType: String {
        switch item.type {
        case .movie: return "film"
        case .series: return "tv"
        case .episode: return "play.rectangle"
        default: return "photo"
        }
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add SashimiMobile/Views/Search/MobileSearchView.swift
git commit -m "fix: add navigation and poster images to search results

SearchResultRow now shows poster images from server and wraps in
NavigationLink to MobileDetailView. Previously had no tap action
and used placeholder icons.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Chunk 3: Phone Navigation

### Task 7: Build PhoneTabView with 5 tabs

**Files:**
- Modify: `SashimiMobile/Views/Phone/PhoneTabView.swift` (replace placeholder)

- [ ] **Step 1: Implement PhoneTabView**

Replace the placeholder `PhoneTabView.swift` with:
```swift
import SwiftUI

struct PhoneTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                PhoneHomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }

            NavigationStack {
                PhoneLibrariesTab()
            }
            .tabItem {
                Label("Libraries", systemImage: "folder")
            }

            NavigationStack {
                MobileSearchView()
            }
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
            }

            NavigationStack {
                DownloadsListView()
                    .navigationTitle("Downloads")
            }
            .tabItem {
                Label("Downloads", systemImage: "arrow.down.circle")
            }

            NavigationStack {
                MobileSettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .tint(MobileColors.accent)
    }
}
```

Note: `PhoneHomeView` and `PhoneLibrariesTab` don't exist yet — create stubs.

- [ ] **Step 2: Create PhoneHomeView stub**

Create `SashimiMobile/Views/Phone/PhoneHomeView.swift`:
```swift
import SwiftUI

struct PhoneHomeView: View {
    var body: some View {
        Text("Home")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MobileColors.background)
            .navigationTitle("Home")
    }
}
```

- [ ] **Step 3: Create PhoneLibrariesTab**

Create `SashimiMobile/Views/Phone/PhoneLibrariesTab.swift`:
```swift
import SwiftUI

struct PhoneLibrariesTab: View {
    @State private var libraries: [JellyfinLibrary] = []

    var body: some View {
        List(libraries) { library in
            NavigationLink {
                MobileLibraryBrowseView(
                    libraryId: library.id,
                    libraryName: library.name,
                    collectionType: library.collectionType
                )
                .navigationTitle(library.name)
            } label: {
                Label(library.name, systemImage: iconFor(library.collectionType))
            }
            .listRowBackground(MobileColors.cardBackground)
        }
        .listStyle(.plain)
        .navigationTitle("Libraries")
        .task {
            do {
                libraries = try await JellyfinClient.shared.getLibraryViews()
            } catch {
                // Silently fail
            }
        }
    }

    private func iconFor(_ collectionType: String?) -> String {
        switch collectionType {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        default: return "folder"
        }
    }
}
```

- [ ] **Step 4: Regenerate project and build**

Run:
```bash
xcodegen generate
xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add SashimiMobile/Views/Phone/
git commit -m "feat: add PhoneTabView with 5-tab navigation and libraries

Tab bar: Home (stub), Libraries, Search, Downloads, Settings.
PhoneLibrariesTab shows library list with drill-down to
MobileLibraryBrowseView. Reuses Search, Downloads, Settings views.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Chunk 4: Phone Home

### Task 8: Build PhoneHomeView

**Files:**
- Modify: `SashimiMobile/Views/Phone/PhoneHomeView.swift` (replace stub)

- [ ] **Step 1: Implement PhoneHomeView**

Replace the stub with:
```swift
import SwiftUI

struct PhoneHomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var rowSettings = HomeRowSettings.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileSpacing.lg) {
                if viewModel.isLoading && viewModel.continueWatchingItems.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    contentView
                }
            }
            .padding(.vertical, MobileSpacing.sm)
        }
        .background(MobileColors.background)
        .navigationTitle("Home")
        .refreshable {
            await viewModel.loadContent()
        }
        .task {
            await viewModel.loadContent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidStop)) { _ in
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                await viewModel.loadContent()
            }
        }
        .onChange(of: viewModel.libraries) { _, libraries in
            rowSettings.updateLibraries(libraries)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        ForEach(rowSettings.rows.filter { $0.isEnabled }) { row in
            rowView(for: row)
        }

        if viewModel.continueWatchingItems.isEmpty && viewModel.libraries.isEmpty {
            ContentUnavailableView(
                "No Content",
                systemImage: "tv",
                description: Text("Start watching something to see it here.")
            )
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    @ViewBuilder
    private func rowView(for row: HomeRowConfig) -> some View {
        switch row.type {
        case .builtIn(.continueWatching):
            if !viewModel.continueWatchingItems.isEmpty {
                let libNames = viewModel.continueWatchingLibraryNames
                MobileContinueWatchingRow(
                    items: viewModel.continueWatchingItems,
                    libraryNames: libNames,
                    cardWidth: PhoneSizing.continueWatchingWidth
                ) { item in
                    PhoneDetailView(item: item, libraryName: libNames[item.id])
                }
            }

        case .library(let libraryId, let libraryName):
            let library = viewModel.libraries.first(where: { $0.id == libraryId })
            MobileRecentlyAddedRow(
                libraryId: libraryId,
                libraryName: libraryName,
                collectionType: library?.collectionType,
                cardWidth: PhoneSizing.posterWidth
            ) { item in
                PhoneDetailView(item: item, libraryName: libraryName)
            }
        }
    }
}
```

Note: This references `PhoneDetailView` which doesn't exist yet — create a stub. `MobileRecentlyAddedRow` accepts `cardWidth` (added in Task 5b).

- [ ] **Step 2: Create PhoneDetailView stub**

Create `SashimiMobile/Views/Phone/PhoneDetailView.swift`:
```swift
import SwiftUI

struct PhoneDetailView: View {
    let item: BaseItemDto
    var libraryName: String?

    var body: some View {
        Text(item.name ?? "Unknown")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MobileColors.background)
    }
}
```

- [ ] **Step 3: Build to verify**

Run:
```bash
xcodegen generate
xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add SashimiMobile/Views/Phone/PhoneHomeView.swift SashimiMobile/Views/Phone/PhoneDetailView.swift
git commit -m "feat: add PhoneHomeView with continue watching and library rows

Uses HomeViewModel (shared), passes PhoneSizing.continueWatchingWidth
for smaller cards. Routes to PhoneDetailView (stub) for detail.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Chunk 5: Phone Detail View

### Task 9: Build PhoneDetailView

**Files:**
- Modify: `SashimiMobile/Views/Phone/PhoneDetailView.swift` (replace stub)

This is the largest new view. It handles movies, series, and episodes with a stacked vertical layout. The data loading logic is identical to `MobileDetailView` — copy those methods verbatim. The layout is completely different.

- [ ] **Step 1: Copy state variables and data loading from MobileDetailView**

Replace the stub. Start with:
- All `@State` properties from `MobileDetailView` (lines 10-28): `playingItem`, `seasons`, `episodes`, `selectedSeason`, `nextEpisodeToPlay`, `isLoadingEpisodes`, `isWatched`, `hasProgress`, `seriesCommunityRating`, `seriesCriticRating`, `showingEpisodeDetail`, `mediaInfo`, `navigateToSeriesItem`, `downloadScope`, `showingDownloadQuality`, `showingNextNAlert`, `showingNoUnwatchedAlert`, `nextNInput`
- `@ObservedObject private var downloadManager = DownloadManager.shared`
- Computed properties: `isSeries`, `isEpisode`, `isMovie`, `isYouTubeStyle`, `isYouTubeSeriesStyle`, `isYouTubeChannelEpisode`
- `DownloadScope` enum and `episodesForDownload` computed property
- `@State private var overviewExpanded = false` (new — for expandable overview)

Copy ALL data loading methods verbatim from `MobileDetailView`:
- `loadContent()` (line 775)
- `loadMediaInfo()` (line 793)
- `loadSeriesContent()` (line 802)
- `loadEpisodeContent()` (line 821) — this populates `seriesCommunityRating`/`seriesCriticRating`
- `loadEpisodesForSeason(seriesId:season:)` (line 837)
- `findNextEpisodeToPlay()` (line 847)
- `refreshPlaybackState()` (line 866)
- `toggleWatched()` (line 876)
- `formatRuntime(_:)` (line 934)
- `formatPremiereDate(_:)` (line 941)

- [ ] **Step 2: Implement backdrop section**

The backdrop URL logic must handle all content types. Copy `backdropImageURL` from `MobileDetailView` (lines 895-920):

```swift
    private var backdropImageURL: URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        if isEpisode {
            return URL(string: "\(serverURL)/Items/\(item.id)/Images/Primary?maxWidth=800")
        }
        if isYouTubeSeriesStyle {
            return URL(string: "\(serverURL)/Items/\(item.id)/Images/Banner?maxWidth=800")
        }
        let imageId: String
        if item.backdropImageTags?.isEmpty == false {
            imageId = item.id
        } else if item.parentBackdropImageTags?.isEmpty == false, let seriesId = item.seriesId {
            imageId = seriesId
        } else {
            return URL(string: "\(serverURL)/Items/\(item.id)/Images/Primary?maxWidth=800")
        }
        return URL(string: "\(serverURL)/Items/\(imageId)/Images/Backdrop?maxWidth=800")
    }
```

Build the backdrop view:
```swift
    private var backdropSection: some View {
        ZStack(alignment: .bottom) {
            LazyImage(url: backdropImageURL) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(MobileColors.cardBackground)
                }
            }
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(
                colors: [.clear, MobileColors.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
        }
    }
```

- [ ] **Step 3: Implement body with stacked layout**

```swift
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                backdropSection

                VStack(alignment: .leading, spacing: MobileSpacing.md) {
                    titleSection
                    metadataRow
                    actionButtons
                    overviewSection

                    if isSeries {
                        seasonsSection
                    }

                    if let people = item.people, people.contains(where: { $0.type == "Actor" }) {
                        castSection(people)
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
                .padding(.top, MobileSpacing.sm)
            }
        }
        .background(MobileColors.background)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenPlayer(item: $playingItem)
        .sheet(item: $showingEpisodeDetail) { episode in
            PhoneEpisodeSheet(episode: episode, libraryName: libraryName)
        }
        .task { /* same task block as MobileDetailView: fetch fresh item, loadContent */ }
        .onChange(of: playingItem) { /* same: refresh on dismiss */ }
    }
```

- [ ] **Step 4: Implement title, metadata, action buttons, overview sections**

Each section as a separate computed property. Key differences from iPad:

- `titleSection`: Full-width bold title (no logo images like iPad)
- `metadataRow`: `HStack` with year, runtime, rating badge, community/critic ratings — same as iPad's but inline (copy `ratingsRow` and `mediaInfoBadges` patterns)
- `actionButtons`: `HStack` with Play/Resume button, watched toggle, DownloadButton. For series: play next episode + download scope menu (copy the Menu + confirmationDialog + alerts from `MobileDetailView.seriesActionButtons`)
- `overviewSection`: Full-width text, 3-line limit with tap-to-expand:
```swift
    @ViewBuilder
    private var overviewSection: some View {
        if let overview = item.overview, !overview.isEmpty {
            Text(overview)
                .font(MobileTypography.body)
                .foregroundStyle(MobileColors.textSecondary)
                .lineLimit(overviewExpanded ? nil : 3)
                .onTapGesture { overviewExpanded.toggle() }
        }
    }
```

- [ ] **Step 5: Implement vertical episode list for series**

This is the key layout difference from iPad. Build a vertical episode card:

```swift
    private func episodeCard(_ episode: BaseItemDto) -> some View {
        Button {
            showingEpisodeDetail = episode
        } label: {
            HStack(spacing: MobileSpacing.sm) {
                // Thumbnail
                LazyImage(url: episodeThumbnailURL(episode)) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(MobileColors.cardBackground)
                    }
                }
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))

                VStack(alignment: .leading, spacing: 4) {
                    if !isYouTubeStyle, let ep = episode.indexNumber {
                        Text("E\(ep)")
                            .font(MobileTypography.captionSmall)
                            .foregroundStyle(MobileColors.accent)
                    }
                    Text(episode.name ?? "Episode")
                        .font(MobileTypography.titleSmall)
                        .foregroundStyle(MobileColors.textPrimary)
                        .lineLimit(2)
                    if let runtime = episode.runTimeTicks {
                        Text(formatRuntime(runtime))
                            .font(MobileTypography.captionSmall)
                            .foregroundStyle(MobileColors.textTertiary)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func episodeThumbnailURL(_ episode: BaseItemDto) -> URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: "\(serverURL)/Items/\(episode.id)/Images/Primary?maxWidth=300")
    }
```

The season picker + episode list section:
```swift
    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.md) {
            // Season picker (horizontal capsule tabs — same pattern as iPad)
            if !seasons.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MobileSpacing.sm) {
                        ForEach(seasons) { season in
                            Button {
                                selectedSeason = season
                                Task { await loadEpisodesForSeason(seriesId: item.id, season: season) }
                            } label: {
                                Text(season.name ?? "Season")
                                    .font(.system(size: 14, weight: selectedSeason?.id == season.id ? .bold : .medium))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(selectedSeason?.id == season.id ? MobileColors.accent : MobileColors.cardBackground)
                                    .foregroundStyle(selectedSeason?.id == season.id ? .black : .white)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }

            // Vertical episode list
            if isLoadingEpisodes {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: MobileSpacing.sm) {
                    ForEach(episodes) { episode in
                        episodeCard(episode)
                    }
                }
            }
        }
    }
```

- [ ] **Step 6: Implement cast section**

Copy the `castSection` and `MobileCastCard` patterns from `MobileDetailView` (horizontal scroll of circular headshots). These are identical on phone and iPad.

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add SashimiMobile/Views/Phone/PhoneDetailView.swift
git commit -m "feat: add PhoneDetailView with stacked vertical layout

Handles movies, series, and episodes on iPhone:
- Full-width backdrop with gradient fade
- Stacked title, metadata, action buttons, overview
- Vertical episode list for series (vs horizontal on iPad)
- Season picker, download scope menu, cast section
- YouTube content detection

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 10: Build PhoneEpisodeSheet

**Files:**
- Create: `SashimiMobile/Views/Phone/PhoneEpisodeSheet.swift`

- [ ] **Step 1: Implement PhoneEpisodeSheet**

```swift
import SwiftUI
import NukeUI

struct PhoneEpisodeSheet: View {
    let episode: BaseItemDto
    var libraryName: String?
    @State private var playingItem: BaseItemDto?
    @State private var isWatched: Bool = false
    @Environment(\.dismiss) private var dismiss

    private var imageURL: URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: "\(serverURL)/Items/\(episode.id)/Images/Primary?maxWidth=800")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileSpacing.md) {
                    // Episode thumbnail
                    LazyImage(url: imageURL) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(MobileColors.cardBackground)
                        }
                    }
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipped()

                    VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                        // Episode label
                        if let season = episode.parentIndexNumber, let ep = episode.indexNumber {
                            Text("S\(season):E\(ep)")
                                .font(MobileTypography.caption)
                                .foregroundStyle(MobileColors.accent)
                        }

                        // Title
                        Text(episode.name ?? "Unknown")
                            .font(MobileTypography.headline)
                            .foregroundStyle(MobileColors.textPrimary)

                        // Runtime
                        if let runtime = episode.runTimeTicks {
                            Text(formatRuntime(runtime))
                                .font(MobileTypography.caption)
                                .foregroundStyle(MobileColors.textSecondary)
                        }

                        // Action buttons
                        HStack(spacing: MobileSpacing.md) {
                            Button {
                                playingItem = episode
                            } label: {
                                Label(
                                    (episode.userData?.playbackPositionTicks ?? 0) > 0 ? "Resume" : "Play",
                                    systemImage: "play.fill"
                                )
                                .font(.system(size: 14, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)

                            DownloadButton(item: episode, quality: nil)

                            Spacer()
                        }

                        // Overview
                        if let overview = episode.overview, !overview.isEmpty {
                            Text(overview)
                                .font(MobileTypography.body)
                                .foregroundStyle(MobileColors.textSecondary)
                        }
                    }
                    .padding(.horizontal, MobileSpacing.md)
                }
            }
            .background(MobileColors.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fullScreenPlayer(item: $playingItem)
        .task {
            isWatched = episode.userData?.played ?? false
        }
    }

    private func formatRuntime(_ ticks: Int64) -> String {
        let seconds = ticks / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run SwiftLint on all new files**

Run: `swiftlint lint SashimiMobile/Views/Phone/`
Fix any warnings (CI runs strict mode).

- [ ] **Step 4: Commit**

```bash
git add SashimiMobile/Views/Phone/PhoneEpisodeSheet.swift
git commit -m "feat: add PhoneEpisodeSheet for episode detail bottom sheet

Shows episode thumbnail, S#:E# label, title, runtime, play button,
download button, and overview. Presented as sheet from series detail.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 11: Update detail view routing in library browse and search

**Files:**
- Modify: `SashimiMobile/Views/Library/MobileLibraryBrowseView.swift:49-51`
- Modify: `SashimiMobile/Views/Search/MobileSearchView.swift:30-34`

Currently `MobileLibraryBrowseView` and `MobileSearchView` route to `MobileDetailView`. On iPhone they should route to `PhoneDetailView`.

- [ ] **Step 1: Add size class routing helper**

The cleanest approach: add a `@ViewBuilder` function or use `@Environment(\.horizontalSizeClass)` inline. Since multiple views need this, create a small helper view:

Add to the bottom of `PhoneDetailView.swift`:
```swift
struct AdaptiveDetailView: View {
    let item: BaseItemDto
    var libraryName: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .compact {
            PhoneDetailView(item: item, libraryName: libraryName)
        } else {
            MobileDetailView(item: item, libraryName: libraryName)
        }
    }
}
```

- [ ] **Step 2: Update MobileLibraryBrowseView to use AdaptiveDetailView**

Change line 50-51 from:
```swift
                            NavigationLink {
                                MobileDetailView(item: item, libraryName: libraryName)
```
to:
```swift
                            NavigationLink {
                                AdaptiveDetailView(item: item, libraryName: libraryName)
```

- [ ] **Step 3: Update MobileSearchView to use AdaptiveDetailView**

Change the NavigationLink destination from:
```swift
                    NavigationLink {
                        MobileDetailView(item: item)
```
to:
```swift
                    NavigationLink {
                        AdaptiveDetailView(item: item)
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add SashimiMobile/Views/Phone/PhoneDetailView.swift SashimiMobile/Views/Library/MobileLibraryBrowseView.swift SashimiMobile/Views/Search/MobileSearchView.swift
git commit -m "feat: adaptive detail view routing for iPhone vs iPad

AdaptiveDetailView checks horizontalSizeClass and routes to
PhoneDetailView (compact) or MobileDetailView (regular).
Updated library browse and search to use it.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 12: Final verification and cleanup

- [ ] **Step 1: Run full build for both platforms**

```bash
xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```
Both expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Run SwiftLint**

```bash
swiftlint lint
```
Fix any warnings in modified/new files.

- [ ] **Step 3: Test on iPhone device if available**

Build and install on connected iPhone, verify:
- Tab bar navigation works
- Libraries list loads and drills down
- Search shows poster images and navigates to detail
- Home shows continue watching and library rows
- Detail view shows stacked layout for movies/series/episodes
- Episode sheet presents and dismisses
- Downloads view works
- Settings view works
- Player works from detail view

- [ ] **Step 4: Test iPad isn't broken**

Build and install on iPad, verify existing sidebar navigation still works correctly.

- [ ] **Step 5: Commit any final fixes**

```bash
git add -A
git commit -m "fix: final cleanup for iPhone support

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
