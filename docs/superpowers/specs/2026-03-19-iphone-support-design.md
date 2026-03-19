# iPhone Support Design Spec

> **Issue:** #111 — feat: Add iPhone support with phone-optimized views

## Goal

Add iPhone support to Sashimi with dedicated phone-specific views while reusing existing components, services, and view models. Single universal target, no separate app binary.

## Architecture

### Target Configuration

Change `TARGETED_DEVICE_FAMILY` from `"2"` (iPad only) to `"1,2"` (universal) in `project.yml`. Add iPhone-specific orientation support to `Info.plist`.

### Root View Branching

`ContentView` uses `@Environment(\.horizontalSizeClass)` to swap navigation:

```
ContentView
  ├── if !authenticated → MobileAuthView (shared)
  ├── if compact (iPhone) → PhoneTabView (new)
  └── if regular (iPad) → MainNavigationView (existing)
```

### File Structure

New phone views in `SashimiMobile/Views/Phone/`:

```
SashimiMobile/Views/Phone/
  ├── PhoneTabView.swift          Tab bar navigation (5 tabs)
  ├── PhoneHomeView.swift         Home screen for phone
  ├── PhoneDetailView.swift       Stacked vertical detail view
  ├── PhoneLibrariesTab.swift     Library list → browse drill-down
  └── PhoneEpisodeSheet.swift     Episode detail presented as sheet
```

### Reused Views (no changes needed)

- `MobileMediaRow` — horizontal scrolling row + grid
- `MobileMediaPosterButton` — poster card + button
- `MobileHeroSection` — auto-advancing hero carousel
- `MobileContinueWatchingCard` — continue watching row
- `MobileSearchView` — search interface
- `MobileSettingsView` — settings
- `MobileLibraryBrowseView` — library grid/browse
- `MobilePlayerView` — AVPlayerViewController wrapper
- `DownloadsListView` — download queue/history
- `DownloadButton` — single item download button

### Shared Layer (unchanged)

All models, view models, and services in `Shared/` remain untouched:
- `JellyfinClient`, `SessionManager`, `HomeViewModel`, `PlayerViewModel`, etc.

## Phone Navigation — PhoneTabView

Standard iOS `TabView` with 5 tabs:

| Tab | Icon | View |
|-----|------|------|
| Home | `house` | `PhoneHomeView` |
| Libraries | `folder` | `PhoneLibrariesTab` |
| Search | `magnifyingglass` | `MobileSearchView` |
| Downloads | `arrow.down.circle` | `DownloadsListView` |
| Settings | `gearshape` | `MobileSettingsView` |

Each tab wraps its content in a `NavigationStack` for independent drill-down navigation (e.g. library → browse → detail).

### PhoneLibrariesTab

Simple list of user's Jellyfin libraries with icons. Fetched from `JellyfinClient.shared.getLibraryViews()`. Tapping a library pushes `MobileLibraryBrowseView` onto the navigation stack.

Icon mapping (same as sidebar):
- `movies` → `film`
- `tvshows` → `tv`
- `music` → `music.note`
- default → `folder`

## Phone Home — PhoneHomeView

Same data source as `MobileHomeView` (uses `HomeViewModel`), laid out for phone width:

- Hero section — full width, ~250pt tall
- Continue Watching row — horizontal scroll
- Library rows (Latest Movies, Latest TV, etc.) — horizontal scroll with 3-column poster sizing
- Pull-to-refresh

## Phone Detail — PhoneDetailView

Handles movies, series, and episodes in one view (same as iPad's `MobileDetailView`). Stacked vertical layout in a `ScrollView`.

### Layout (top to bottom)

1. **Backdrop** — full width, ~220pt tall, gradient fade to background at bottom
2. **Title** — bold, full width
3. **Metadata row** — year, runtime, content rating, community/critic ratings
4. **Action buttons** — horizontal row:
   - Movies/Episodes: Play (borderedProminent), Watched toggle, DownloadButton
   - Series: Play next episode button, Watched toggle
5. **Overview** — 3-line limit, tappable to expand
6. **Series content:**
   - Season picker — horizontal capsule tabs (same pattern as iPad)
   - Episode list — vertical cards: thumbnail (left), title + episode number + runtime (right)
   - Tapping episode pushes `PhoneEpisodeSheet` or navigates to episode detail
   - Download scope menu (All/Unwatched/Custom) on series
7. **Cast section** — horizontal scroll of circular headshots
8. **Media info badges** — resolution, codec, audio format

### YouTube Detection

Same `isYouTubeStyle` logic via `libraryName`. Circular channel art, no season/episode numbers, cleaned titles.

## Theme Additions

Add phone-specific sizing to `MobileTheme.swift`:

```swift
enum PhoneSizing {
    static let posterWidth: CGFloat = 110
    static let posterHeight: CGFloat = 165
    static let heroHeight: CGFloat = 250
    static let episodeCardHeight: CGFloat = 80
}
```

No changes to `MobileColors`, `MobileTypography`, `MobileCornerRadius`, or `MobileSpacing` — existing values work on phone.

### Grid Columns

3-column poster grid on iPhone in portrait. The existing adaptive grid in `MobileLibraryBrowseView` and `MobileMediaRow` handles this naturally with the smaller poster width. Minor adjustment to use `PhoneSizing.posterWidth` when `horizontalSizeClass == .compact`.

### Downloads

`DownloadsListView` already has `maxWidth: 700` constraint. On phone it fills the screen naturally. No changes needed.

## project.yml Changes

```yaml
TARGETED_DEVICE_FAMILY: "1,2"
```

Add iPhone orientation support to Info.plist properties:
```yaml
UISupportedInterfaceOrientations:
  - UIInterfaceOrientationPortrait
  - UIInterfaceOrientationLandscapeLeft
  - UIInterfaceOrientationLandscapeRight
```

## Scope Exclusions

- No iPhone-specific app icon (uses same `AppIcon.appiconset`)
- No compact landscape layout optimization (portrait-first)
- No widget or Live Activity support
- No CarPlay support
