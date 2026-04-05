# Sashimi Codebase Audit — April 2026

## Summary Stats

| Severity | Count |
|----------|-------|
| Critical | 1     |
| High     | 5     |
| Medium   | 8     |
| Low      | 4     |
| **Total** | **18** |

| Category     | Count |
|--------------|-------|
| Security     | 3     |
| Bug          | 6     |
| Dead code    | 1 (14 items) |
| Code quality | 2     |
| Tech debt    | 4     |
| CI/Testing   | 2     |

## Issues by Severity

### Critical
| # | Title | Effort |
|---|-------|--------|
| 135 | Parental PIN in plaintext UserDefaults | Small |

### High
| # | Title | Effort |
|---|-------|--------|
| 136 | logout() doesn't clear JellyfinClient credentials | Small |
| 137 | allowSelfSigned bypasses ALL cert validation | Small |
| 138 | Fastlane bundle ID mismatch — deploy broken | Small |
| 139 | CI never runs tests | Small |
| 140 | SwiftLint not strict, Shared/ excluded | Small |

### Medium
| # | Title | Effort |
|---|-------|--------|
| 141 | changeQuality() duplicates loadMedia() | Medium |
| 142 | SubtitleManager bypasses cert trust | Small |
| 143 | HomeView timer stacking on repeated onAppear | Small |
| 144 | Hardcoded version strings | Small |
| 145 | 14 dead code items | Small |
| 146 | Duplicated formatDate/formatRuntime across files | Small |
| 147 | Private API for icon switching | Medium |
| 148 | ServerDiscovery connection leak | Small |

### Low
| # | Title | Effort |
|---|-------|--------|
| 149 | Silent try? and empty catch blocks | Medium |
| 150 | God views (MediaDetailView 1740 lines) | Large |
| 151 | Focus highlight pattern duplicated 15+ times | Medium |
| 152 | Misc cleanup (10 items) | Small |

## Recommended Order

### Phase 1: Security & Critical (do first)
1. **#135** — Move PIN to Keychain, add persistent lockout
2. **#136** — Add `clearCredentials()` to JellyfinClient, call from logout()
3. **#137** — Check cert error code in allowSelfSigned handler

### Phase 2: CI/Build Fixes (unblocks future work)
4. **#139** — Add xcodebuild test step to ci.yml
5. **#140** — Add --strict to swiftlint, include Shared/ directory
6. **#138** — Update Fastlane bundle IDs to com.mondominator.sashimi

### Phase 3: Bug Fixes
7. **#142** — Use JellyfinClient's URLSession in SubtitleManager
8. **#143** — Fix timer stacking in HomeView
9. **#148** — Cancel NWConnections on failure
10. **#144** — Read version from Bundle.main

### Phase 4: Code Cleanup
11. **#145** — Remove 14 dead code items
12. **#146** — Extract shared date/runtime formatters
13. **#141** — Refactor changeQuality() to share code with loadMedia()
14. **#152** — Misc cleanup (stale files, deps, magic numbers)

### Phase 5: Long-term (plan separately)
15. **#147** — Research public API alternative for icon switching
16. **#149** — Add error logging to silent try? blocks
17. **#150** — Break up god views when touching them
18. **#151** — Create FocusHighlightModifier

## Quick Wins (< 5 min each)
- **#136** — Add one method call to logout()
- **#138** — Find/replace bundle IDs in 3 Fastlane files
- **#139** — Add test step to ci.yml
- **#140** — Add --strict flag and Shared/ to swiftlint config
- **#144** — Replace hardcoded strings with Bundle.main reads
- **#148** — Add connection.cancel() to 2 switch cases

## Dependency Chain
- #139 (CI tests) should be done before #141 (refactor) — tests catch regressions
- #140 (swiftlint strict) should be done before #145 (dead code) — lint may flag more
- #136 (clear credentials) before #137 (cert validation) — both touch JellyfinClient

## Estimated Effort
- **Small** (< 30 min): #135, #136, #137, #138, #139, #140, #142, #143, #144, #145, #146, #148, #152
- **Medium** (30 min - 2 hrs): #141, #147, #149, #151
- **Large** (2+ hrs): #150
