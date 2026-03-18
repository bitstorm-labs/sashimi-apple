# iPad Button Text Color Fix Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix blue button text across the iPad app to use white/custom accent colors instead of iOS default blue.

**Architecture:** Set a global `.tint()` at the app root to propagate the custom accent color to all bordered button styles. Add explicit `.foregroundStyle(.white)` to player overlay buttons that sit on translucent/dark backgrounds. Delete unused `MobileLibraryView.swift`.

**Tech Stack:** SwiftUI, tvOS/iOS shared codebase

**Spec:** `docs/superpowers/specs/2026-03-18-ipad-button-fix-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `SashimiMobile/App/SashimiMobileApp.swift` | Modify (line 34) | Add `.tint(MobileColors.accent)` to root ContentView |
| `SashimiMobile/Views/Player/MobilePlayerView.swift` | Modify (lines 279, 357-360) | Add `.foregroundStyle(.white)` to skip button label and dismiss button |
| `SashimiMobile/Views/Library/MobileLibraryView.swift` | Delete | Dead code — unused view and LibraryCard struct |

---

## Chunk 1: Implementation

### Task 1: Set global tint on app root

**Files:**
- Modify: `SashimiMobile/App/SashimiMobileApp.swift:34`

- [ ] **Step 1: Add `.tint(MobileColors.accent)` to ContentView**

Change line 34 from:
```swift
            ContentView()
                .environmentObject(sessionManager)
```
to:
```swift
            ContentView()
                .environmentObject(sessionManager)
                .tint(MobileColors.accent)
```

- [ ] **Step 2: Build to verify no compilation errors**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add SashimiMobile/App/SashimiMobileApp.swift
git commit -m "fix: set global tint to custom accent color on iPad app

Fixes blue button text across the app by propagating MobileColors.accent
as the global tint. Affects all .borderedProminent and .bordered buttons."
```

### Task 2: Fix player overlay button colors

**Files:**
- Modify: `SashimiMobile/Views/Player/MobilePlayerView.swift:279,357-360`

- [ ] **Step 1: Add `.foregroundStyle(.white)` to skip button label**

Change the skip button label (line 279) from:
```swift
                    Label(skipLabel(for: segment.type), systemImage: "forward.fill")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
```
to:
```swift
                    Label(skipLabel(for: segment.type), systemImage: "forward.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
```

- [ ] **Step 2: Add `.foregroundStyle(.white)` to dismiss button**

Change the dismiss button (lines 357-360) from:
```swift
                    Button("Dismiss") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
```
to:
```swift
                    Button("Dismiss") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.white)
```

- [ ] **Step 3: Build to verify no compilation errors**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add SashimiMobile/Views/Player/MobilePlayerView.swift
git commit -m "fix: set white text on player skip and dismiss buttons

These buttons overlay dark/translucent backgrounds and don't inherit
from the global tint, so they need explicit white foreground."
```

### Task 3: Delete dead code

**Files:**
- Delete: `SashimiMobile/Views/Library/MobileLibraryView.swift`

- [ ] **Step 1: Delete the unused file**

```bash
rm SashimiMobile/Views/Library/MobileLibraryView.swift
```

- [ ] **Step 2: Build to verify nothing breaks**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add SashimiMobile/Views/Library/MobileLibraryView.swift
git commit -m "chore: remove unused MobileLibraryView

MobileLibraryView and LibraryCard are never referenced — the sidebar
navigates directly to MobileLibraryBrowseView for each library."
```
