# iPad Button Text Color Fix

**Date:** 2026-03-18
**Status:** Approved

## Problem

Many buttons in the iPad (SashimiMobile) app display blue text — the iOS default accent color — instead of white. This affects buttons in library/detail views and the skip intro/credits button in the player.

## Root Cause

The app defines a custom accent color (`MobileColors.accent`) but never sets it as the global `.tint()` for the app. SwiftUI's `.borderedProminent` and `.bordered` button styles inherit the system accent color (blue) by default.

Player overlay buttons (skip intro/credits, dismiss) lack explicit `.foregroundStyle()`, so their labels also render in system blue against the dark translucent background.

## Solution

### 1. Set global tint on root ContentView

In `SashimiMobile/App/SashimiMobileApp.swift`, add `.tint(MobileColors.accent)` to the root `ContentView`. This makes:
- `.borderedProminent` buttons use `MobileColors.accent` as background with white text
- `.bordered` buttons use `MobileColors.accent` for their text/border

### 2. Fix skip button foreground color

In `MobilePlayerView.swift`, add `.foregroundStyle(.white)` to the skip button label. The skip button uses `.ultraThinMaterial` background (not a bordered button style), so the global tint doesn't apply to its text.

### 3. Fix dismiss button on error screen

In `MobilePlayerView.swift`, add `.foregroundStyle(.white)` to the "Dismiss" button in the error view. This button uses `.buttonStyle(.bordered)` over a black background, but explicit white ensures visibility.

### 4. Delete dead code

Delete `SashimiMobile/Views/Library/MobileLibraryView.swift` — it defines a `MobileLibraryView` and `LibraryCard` that are never referenced. The sidebar navigates directly to `MobileLibraryBrowseView`.

## Files Changed

- `SashimiMobile/App/SashimiMobileApp.swift` — add `.tint(MobileColors.accent)`
- `SashimiMobile/Views/Player/MobilePlayerView.swift` — add `.foregroundStyle(.white)` to skip button and dismiss button
- `SashimiMobile/Views/Library/MobileLibraryView.swift` — delete (dead code)

## Affected Buttons

| Location | Button | Current | After Fix |
|----------|--------|---------|-----------|
| Series detail | Play S1:E1 | Blue bg, white text | Accent bg, white text |
| Series detail | Download Season | Blue text | Accent text |
| Episode/Movie detail | Play / Resume | Blue bg, white text | Accent bg, white text |
| Episode detail | Series link | Blue text | Accent text |
| Detail views | Watched toggle | Blue border | Accent border |
| Player | Skip Intro/Credits | Blue text | White text |
| Player error | Dismiss | Blue text | White text |
