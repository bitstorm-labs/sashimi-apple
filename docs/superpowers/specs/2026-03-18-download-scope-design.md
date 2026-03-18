# Download Scope Enhancement

**Date:** 2026-03-18
**Status:** Approved
**Issue:** #112

## Problem

The series detail view only offers "Download Season" which downloads every episode in the selected season. Users want finer control — downloading only unwatched episodes or a specific number of upcoming unwatched episodes.

## Solution

Replace the "Download Season" button with a "Download" `Menu` that presents three scope options before showing the quality picker.

### Interaction Flow

1. User taps "Download" button on the series detail view (within the season context)
2. A `Menu` appears with three options:
   - **All Episodes** — every episode in the selected season
   - **Unwatched Only** — episodes where `userData?.played != true`
   - **Next N Unwatched** — user enters a number via alert with text field, then that many unwatched episodes starting from the first unwatched
3. For "Next N Unwatched": an alert appears with a text field for the user to enter a number
4. After scope selection (and N input if applicable), the existing quality confirmation dialog appears with the standard quality options
5. Download begins via the existing `DownloadManager.shared.downloadSeason(episodes:quality:)` method

### Episode Filtering Logic

```swift
// All Episodes — pass episodes array unchanged
let toDownload = episodes

// Unwatched Only
let toDownload = episodes.filter { !($0.userData?.played ?? false) }

// Next N Unwatched
let toDownload = Array(
    episodes.filter { !($0.userData?.played ?? false) }.prefix(n)
)
```

Filtering happens in `MobileDetailView` before calling `downloadSeason`. No changes to `DownloadManager`.

### UI Changes

**MobileDetailView.swift — `seriesActionButtons`:**

Replace the current "Download Season" `Button` + `confirmationDialog` with:

1. A `Menu` labeled "Download" with `arrow.down.circle` icon, styled as `.bordered`
2. Three menu items: "All Episodes", "Unwatched Only", "Next N Unwatched..."
3. Each menu item sets a `@State` scope variable and triggers the quality confirmation dialog
4. "Next N Unwatched..." sets a flag to show an alert with a `TextField` for number input; after the user enters a number and taps OK, the quality dialog appears

**New state properties:**

```swift
@State private var downloadScope: DownloadScope?
@State private var showingDownloadQuality = false
@State private var showingNextNAlert = false
@State private var nextNInput = ""
```

**DownloadScope enum** (defined locally in MobileDetailView or as a small private type):

```swift
private enum DownloadScope {
    case all
    case unwatched
    case nextN(Int)
}
```

**Computed property for filtered episodes:**

```swift
private var episodesForDownload: [BaseItemDto] {
    guard let scope = downloadScope else { return [] }
    switch scope {
    case .all:
        return episodes
    case .unwatched:
        return episodes.filter { !($0.userData?.played ?? false) }
    case .nextN(let n):
        return Array(episodes.filter { !($0.userData?.played ?? false) }.prefix(n))
    }
}
```

### Files Changed

- `SashimiMobile/Views/Detail/MobileDetailView.swift` — replace Download Season button/dialog with Menu + scope selection + alert for Next N input

### What Does NOT Change

- `DownloadManager` — no modifications, the existing `downloadSeason(episodes:quality:)` method is reused
- `DownloadButton` — not affected (per-episode download)
- `DownloadModels` — no new models
- Quality picker flow — same confirmation dialog with same quality options

### Edge Cases

- **No unwatched episodes:** If "Unwatched Only" or "Next N Unwatched" results in an empty list, don't start the download. Show an alert: "All episodes in this season are already watched."
- **N larger than unwatched count:** `.prefix(n)` handles this gracefully — returns whatever is available.
- **Non-numeric input for N:** Validate the text field input. Ignore or default if invalid.
- **N of 0 or negative:** Treat as invalid, don't start download.
