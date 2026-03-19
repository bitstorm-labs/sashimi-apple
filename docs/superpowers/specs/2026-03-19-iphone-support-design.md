# iPhone Support Design Spec

> **Issue:** #111 — feat: Add iPhone support with phone-optimized views

## Goal

Add iPhone support to Sashimi with dedicated phone-specific views while reusing existing components, services, and view models. Single universal target, no separate app binary.

## Architecture

### Target Configuration

Change `TARGETED_DEVICE_FAMILY` from `"2"` (iPad only) to `"1,2"` (universal) in `project.yml`. Add iPhone-specific orientation support to `Info.plist`.

### Root View Branching

Modify `ContentView` in `SashimiMobileApp.swift` to add `@Environment(\.horizontalSizeClass)` and conditionally branch between iPad and iPhone navigation when authenticated:

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
  ├── PhoneDetailView.swift       Stacked vertical detail view (new, not reuse of MobileDetailView)
  ├── PhoneLibrariesTab.swift     Library list → browse drill-down
  └── PhoneEpisodeSheet.swift     Episode detail as bottom sheet from series view
```

### Reused Views

**No changes needed:**
- `MobileMediaPosterButton` — poster card + button
- `MobileSettingsView` — settings
- `MobilePlayerView` — AVPlayerViewController wrapper
- `DownloadsListView` — download queue/history (maxWidth: 700 already constrains on iPad)
- `DownloadButton` — single item download button

**Minor changes needed:**
- `MobileHeroSection` — add optional `height` parameter (currently hardcoded to 180pt, phone needs 250pt)
- `MobileMediaRow` — pass phone poster width when `horizontalSizeClass == .compact`
- `MobileContinueWatchingCard` — add `PhoneSizing.continueWatchingWidth` (current 280pt default is too wide for 390pt phone screens)
- `MobileLibraryBrowseView` — use `PhoneSizing.posterWidth` (110pt) as grid minimum when compact, so the adaptive grid produces 3 columns instead of 2
- `MobileSearchView` — add `NavigationLink` to `SearchResultRow` and load poster images (currently has no tap action and uses placeholder icons)

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

- Hero section — full width, 250pt tall (via `MobileHeroSection(height:)`)
- Continue Watching row — horizontal scroll with `PhoneSizing.continueWatchingWidth` cards
- Library rows (Latest Movies, Latest TV, etc.) — horizontal scroll with phone poster sizing
- Pull-to-refresh

## Phone Detail — PhoneDetailView

**This is a new view**, not a reuse of `MobileDetailView`. The iPad detail view uses a split layout with backdrop floating on the right and horizontal episode scrollers — these patterns don't translate to phone. `PhoneDetailView` handles movies, series, and episodes with a stacked vertical layout.

### Layout (top to bottom)

1. **Backdrop** — full width, ~220pt tall, gradient fade to background at bottom
2. **Title** — bold, full width
3. **Metadata row** — year, runtime, content rating, community/critic ratings
4. **Action buttons** — horizontal row:
   - Movies/Episodes: Play (borderedProminent), Watched toggle, DownloadButton
   - Series: Play next episode button, Watched toggle
5. **Overview** — full width, 3-line limit, tappable to expand
6. **Series content:**
   - Season picker — horizontal capsule tabs
   - Episode list — **vertical** cards: thumbnail (left), title + episode number + runtime (right). This differs from iPad which uses horizontal scrolling episode cards.
   - Tapping an episode presents `PhoneEpisodeSheet` as a bottom sheet (`.sheet(item:)`)
   - Download scope menu (All/Unwatched/Custom) on series
7. **Cast section** — horizontal scroll of circular headshots
8. **Media info badges** — resolution, codec, audio format

### PhoneEpisodeSheet

Bottom sheet presenting episode detail. Shows backdrop, episode title, S#:E# label, overview, Play button, Download button. Dismissable by swiping down. Presented from the series `PhoneDetailView` when tapping an episode.

### YouTube Detection

Same `isYouTubeStyle` logic via `libraryName`. Circular channel art, no season/episode numbers, cleaned titles.

## Theme Additions

Add phone-specific sizing to `MobileTheme.swift`:

```swift
enum PhoneSizing {
    static let posterWidth: CGFloat = 110
    static let posterHeight: CGFloat = 165
    static let heroHeight: CGFloat = 250
    static let continueWatchingWidth: CGFloat = 200
    static let episodeCardHeight: CGFloat = 80
}
```

No changes to `MobileColors`, `MobileTypography`, `MobileCornerRadius`, or `MobileSpacing` — existing values work on phone.

### Grid Columns

3-column poster grid on iPhone in portrait. Requires modifying `MobileLibraryBrowseView` and `MobileMediaRow` to use `PhoneSizing.posterWidth` (110pt) as the adaptive grid minimum when `horizontalSizeClass == .compact`. The current 140pt minimum produces 2 columns on a ~390pt phone screen.

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

## Required Fixes to Existing Views

These existing views need minor updates for phone compatibility:

1. **`MobileHeroSection`** — add optional `height` parameter (default 180pt for iPad, 250pt for phone)
2. **`MobileLibraryBrowseView`** — use `PhoneSizing.posterWidth` as grid minimum when compact size class
3. **`MobileMediaRow`** — same grid minimum adjustment for compact size class
4. **`MobileContinueWatchingCard`** — accept configurable width, use `PhoneSizing.continueWatchingWidth` on phone
5. **`MobileSearchView`** — add `NavigationLink` to search results and load poster images (currently no tap action, placeholder icons)

## Scope Exclusions

- No iPhone-specific app icon (uses same `AppIcon.appiconset`)
- No compact landscape layout optimization (portrait-first)
- No widget or Live Activity support
- No CarPlay support
- No play-from-downloads (tapping completed downloads to play directly — future enhancement)
- No alternate app icon picker changes for iPhone (existing Settings view handles this)
