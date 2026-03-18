# Download Manager Redesign — Performance & Feedback

**Date:** 2026-03-18
**Status:** Approved
**Issue:** #116
**Sub-project:** A (architecture fix) — Sub-project B (activity indicator #115) follows separately

## Problem

`DownloadManager` is `@MainActor`, forcing all SwiftData operations, URLSession delegate handling, and state updates onto the main thread. During bulk downloads this freezes the UI. Progress callbacks fire per-chunk per-download, each creating a new `ModelContext` and saving — flooding the main actor. Users see no feedback when downloads start and can't tell when the server is transcoding.

## Solution

### 1. Serial Download Queue

- `DownloadManager` maintains a download queue — an array of `(item, quality)` pairs
- `downloadSeason(episodes:quality:)` adds all episodes to the queue as SwiftData records with status `.queued` (batched in a single save), then starts the first item
- When a download completes (`didFinishDownloadingTo`), the manager dequeues the next item and starts it
- `startDownload` is split into two paths: `enqueueDownload` (creates SwiftData record with `.queued` status) and `startNextDownload` (takes the next queued item, checks disk space, builds URL, creates directory, starts background task)
- All downloads go through the queue — both bulk and single-episode. Single-episode downloads are simply a queue of one. This avoids unbounded concurrency if a user taps download on several individual episodes.
- Asset downloads (images, subtitles) for queued items can be fetched in the background as long as it doesn't cause UI issues — fall back to serial if needed

### 2. Architecture: @MainActor + Background Helper

Keep `DownloadManager` as `@MainActor ObservableObject` so `@Published` properties and SwiftUI observation work unchanged. Move the heavy work into a background helper:

**`DownloadPersistence`** — a new non-isolated class that owns a dedicated serial `DispatchQueue` and a single `ModelContext` for all SwiftData operations. All database reads/writes go through this helper instead of creating a new `ModelContext` per operation on the main actor. (Not a Swift `actor` — `ModelContext` is not `Sendable`, so a plain class with a serial queue is the pragmatic choice.)

**Progress throttling:**
- URLSession delegate callbacks (`didWriteData`) update a plain `[String: Double]` dict via `Task { @MainActor in }` — but only update `pendingProgress`, not `@Published activeDownloads`
- A `Timer.scheduledTimer` (RunLoop-based, 0.5s interval) publishes `pendingProgress` to `activeDownloads` on the main actor, limiting SwiftUI re-renders to 2x/second
- Timer starts when the first download begins, stops when the last download completes or is cancelled — no overhead when idle
- SwiftData progress writes happen via `DownloadPersistence` every 5 seconds per item (tracked with a `lastProgressSave` dict)

**URLSession delegate** stays as-is — the delegate methods are already `nonisolated` and dispatch to the main actor via `Task { @MainActor in }`. The only change is that SwiftData writes inside those callbacks go through `DownloadPersistence` instead of creating a `ModelContext` inline.

**Upgrade path for existing downloads:** `reconnectTasks()` already handles multiple in-flight background URLSession tasks. On upgrade, any concurrent downloads from the old code will continue to completion normally. The serial queue only applies to newly queued downloads.

### 3. User Feedback

**Bulk download confirmation toast:**
- When a bulk download starts, show a banner at the top of the screen: "Downloading N episodes..."
- Auto-dismisses after 3 seconds
- Tappable to navigate to Downloads screen
- `DownloadManager` publishes a `@Published var toastMessage: String?` one-shot event
- `MainNavigationView` in `SidebarView.swift` observes the event and shows the toast overlay
- Toast tap sets `selection = .downloads` to navigate — `MainNavigationView` handles this internally so `DownloadManager` doesn't know about navigation

**Download status labels on rows:**

| Status | Label | Visual |
|--------|-------|--------|
| `queued` | "Waiting..." | No progress bar (keeps existing label) |
| `preparing` | "Preparing..." | No progress bar (server transcoding) |
| `downloading` | "Downloading X%" | Progress bar |
| `paused` | "Paused" | No progress bar |
| `completed` | File size | Checkmark |
| `failed` | Error message | Warning icon |

The `preparing` state is detected when a download task has been started (`.resume()` called) but `totalBytesExpectedToWrite` is still 0 or unknown. The 0.5s progress timer checks for this: if an item has status `.downloading` but no progress after the task started, update its display state to `preparing`.

**Preparing timeout:** Tracked in the 0.5s progress timer. Each item records when its download task was resumed. If 60 seconds pass with 0 bytes received, mark as failed with "Server took too long to respond." If bytes start flowing at any point, the timeout is cleared.

## Files Changed

| File | Change |
|------|--------|
| `SashimiMobile/Downloads/Services/DownloadManager.swift` | Add serial download queue, throttle progress via timer + `pendingProgress` dict, delegate SwiftData writes to `DownloadPersistence`, add `toastMessage` published property, add queue management |
| `SashimiMobile/Downloads/Services/DownloadPersistence.swift` | **New file.** Non-isolated helper with dedicated serial `DispatchQueue` and single `ModelContext`. Methods: batch insert queued records, update status, update progress, delete record, fetch record |
| `SashimiMobile/Downloads/Models/DownloadModels.swift` | Add `preparing` case to `DownloadStatus` enum |
| `SashimiMobile/Downloads/Views/DownloadsListView.swift` | Add "Preparing..." status label, handle preparing state in `statusLabel(for:)` |
| `SashimiMobile/Downloads/Views/DownloadButton.swift` | Handle `preparing` status case in `refreshState()` and `DownloadButtonState` |
| `SashimiMobile/Views/Detail/MobileDetailView.swift` | Minor: `downloadSeason` may change to non-async (queue returns immediately) |
| `SashimiMobile/Views/Navigation/SidebarView.swift` | Add toast overlay on `MainNavigationView`, observe `downloadManager.toastMessage` |

## What Does NOT Change

- `DownloadFileManager` — file system operations unchanged
- `DownloadURLBuilder` — URL construction unchanged
- `DownloadedItem` / `DownloadedSubtitle` models — unchanged (except new status case)
- `OfflineIndicator.swift` — `isDownloaded` check unchanged (reads from SwiftData, not affected)
- `MobilePlayerView.swift` — `localVideoURL`, `offlinePlaybackPosition`, `savePlaybackPosition` are synchronous and stay on main actor
- `MobileSettingsView.swift` — `deleteAllDownloads` stays async on main actor
- `SashimiMobileApp.swift` — `setModelContainer`, `setBackgroundCompletionHandler`, `syncPendingProgress` stay synchronous/async on main actor

## Edge Cases

- **Queue cancellation:** If user cancels a queued (not yet downloading) item, remove it from the queue and delete its SwiftData record. If user cancels the active download, start the next queued item.
- **App termination during queue:** Background URLSession handles the active download. Queued items persist in SwiftData with `.queued` status. On relaunch, `reconnectTasks()` reconnects the active download and `downloadSeason` is not re-triggered — the queue picks up from the SwiftData state.
- **Concurrent legacy downloads on upgrade:** `reconnectTasks()` handles multiple in-flight tasks from the old code. They run to completion normally. The serial queue only applies to new downloads.
- **Empty queue:** When the last item finishes or is cancelled, the queue is idle. Progress timer stops. No overhead when nothing is downloading.
- **Preparing timeout:** Tracked in the progress timer. If 60 seconds pass since task.resume() with 0 bytes received, mark as failed. Timer resets if any bytes arrive.
