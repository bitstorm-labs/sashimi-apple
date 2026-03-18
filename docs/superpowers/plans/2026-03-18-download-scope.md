# Download Scope Enhancement Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the "Download Season" button with a "Download" menu offering three scope options: All Episodes, Unwatched Only, and Next N Unwatched.

**Architecture:** All changes are in `MobileDetailView.swift`. The existing `DownloadManager.downloadSeason(episodes:quality:)` is reused unchanged — episode filtering happens in the view before calling the manager. The current button + confirmation dialog is replaced with a Menu → scope selection → quality dialog flow.

**Tech Stack:** SwiftUI, iOS 17+

**Spec:** `docs/superpowers/specs/2026-03-18-download-scope-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `SashimiMobile/Views/Detail/MobileDetailView.swift` | Modify (lines 10-23 state vars, lines 511-530 download button) | Replace download button with scoped menu |

---

## Chunk 1: Implementation

### Task 1: Add download scope enum and new state properties

**Files:**
- Modify: `SashimiMobile/Views/Detail/MobileDetailView.swift:23` (add state vars), after line 44 (add enum + computed property)

- [ ] **Step 1: Add new state properties alongside existing `showingSeasonDownload`**

After line 23 (`@State private var showingSeasonDownload = false`), add the new state properties:

```swift
    @State private var downloadScope: DownloadScope?
    @State private var showingDownloadQuality = false
    @State private var showingNextNAlert = false
    @State private var showingNoUnwatchedAlert = false
    @State private var nextNInput = ""
```

Note: Keep `showingSeasonDownload` for now — it's still referenced by the existing button code. It will be removed in Task 2.

- [ ] **Step 2: Add DownloadScope enum**

Add this private enum inside `MobileDetailView`, just after the existing computed properties (after line 44, before `var body`):

```swift
    private enum DownloadScope {
        case all
        case unwatched
        case nextN(Int)
    }
```

- [ ] **Step 3: Add computed property for filtered episodes**

Add after the `DownloadScope` enum:

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

- [ ] **Step 4: Build to verify no compilation errors**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Note: The new state variables and enum will be unused until Task 2 — warnings are expected.

- [ ] **Step 5: Commit**

```bash
git add SashimiMobile/Views/Detail/MobileDetailView.swift
git commit -m "feat: add download scope enum and state for scoped downloads

Adds DownloadScope enum (all, unwatched, nextN), new state properties,
and episodesForDownload computed property that filters episodes by scope.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: Replace Download Season button with scoped Menu

**Files:**
- Modify: `SashimiMobile/Views/Detail/MobileDetailView.swift:23` (remove old state), lines 511-530 (replace button with menu)

- [ ] **Step 1: Remove the old `showingSeasonDownload` state variable**

Delete line 23:
```swift
    @State private var showingSeasonDownload = false
```

- [ ] **Step 2: Replace the download button and confirmation dialog**

Replace lines 511-530 (the entire `// Download season button` block):

```swift
            // Download season button (downloads all episodes in selected season)
            if !episodes.isEmpty {
                Button {
                    showingSeasonDownload = true
                } label: {
                    Label("Download Season", systemImage: "arrow.down.circle")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .confirmationDialog("Download Season", isPresented: $showingSeasonDownload) {
                    ForEach(DownloadQuality.allCases) { quality in
                        Button("\(quality.displayName) — \(quality.subtitle)") {
                            Task {
                                await DownloadManager.shared.downloadSeason(episodes: episodes, quality: quality)
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
```

with:

```swift
            // Download menu with scope options
            if !episodes.isEmpty {
                Menu {
                    Button("All Episodes") {
                        downloadScope = .all
                        showingDownloadQuality = true
                    }
                    Button("Unwatched Only") {
                        let unwatched = episodes.filter { !($0.userData?.played ?? false) }
                        if unwatched.isEmpty {
                            showingNoUnwatchedAlert = true
                        } else {
                            downloadScope = .unwatched
                            showingDownloadQuality = true
                        }
                    }
                    Button("Next N Unwatched...") {
                        let unwatched = episodes.filter { !($0.userData?.played ?? false) }
                        if unwatched.isEmpty {
                            showingNoUnwatchedAlert = true
                        } else {
                            nextNInput = ""
                            showingNextNAlert = true
                        }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .confirmationDialog("Select Quality", isPresented: $showingDownloadQuality) {
                    ForEach(DownloadQuality.allCases) { quality in
                        Button("\(quality.displayName) — \(quality.subtitle)") {
                            Task {
                                await DownloadManager.shared.downloadSeason(
                                    episodes: episodesForDownload, quality: quality
                                )
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        downloadScope = nil
                    }
                }
                .alert("Download Next N Unwatched", isPresented: $showingNextNAlert) {
                    TextField("Number of episodes", text: $nextNInput)
                        .keyboardType(.numberPad)
                    Button("OK") {
                        if let n = Int(nextNInput), n > 0 {
                            downloadScope = .nextN(n)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                showingDownloadQuality = true
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("How many unwatched episodes would you like to download?")
                }
                .alert("No Unwatched Episodes", isPresented: $showingNoUnwatchedAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("All episodes in this season are already watched.")
                }
            }
```

- [ ] **Step 3: Build to verify no compilation errors**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add SashimiMobile/Views/Detail/MobileDetailView.swift
git commit -m "feat: replace Download Season button with scoped download menu

Adds three download scope options:
- All Episodes (previous behavior)
- Unwatched Only (filters out watched episodes)
- Next N Unwatched (user enters a number, downloads that many)

Shows 'no unwatched episodes' alert when applicable.
Reuses existing DownloadManager.downloadSeason() with filtered arrays.

Fixes #112

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
