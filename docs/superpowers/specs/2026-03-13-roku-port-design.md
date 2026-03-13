# Sashimi Roku Port — Design Spec

## Overview

Port Sashimi (tvOS Jellyfin client) to Roku as a new standalone app. The Roku version will be a faithful translation of every portable feature, built natively in BrighterScript/SceneGraph, targeting the Roku Channel Store.

**Repository**: `sashimi-roku` (separate from the tvOS repo — zero shared code between Swift and BrightScript)

**Non-goals**: Alternate app icons (tvOS-only feature), parallax icon effects.

## Technology Stack

- **Language**: BrighterScript (transpiles to BrightScript) — adds classes, namespaces, and better type checking over raw BrightScript
- **UI Framework**: Roku SceneGraph XML
- **Build**: Node.js pipeline (npm scripts), BrighterScript compiler (`bsc`), output `.zip` for sideloading/submission
- **Testing**: Rooibos framework for unit tests
- **IDE**: VSCode + BrightScript Language extension (debugging, breakpoints, variable inspection)
- **Linting**: bslint

No SGDEX — custom lightweight navigation stack for full UI control.

## Project Structure

```
sashimi-roku/
  manifest                          # Channel metadata, icons, splash
  package.json                      # Build scripts (transpile, package, deploy)
  bsconfig.json                     # BrighterScript compiler config
  .vscode/launch.json               # Debug configuration

  source/
    Main.bs                         # Entry point - creates Scene, message loop
    utils/
      Registry.bs                   # 16KB registry wrapper (auth, settings)
      Http.bs                       # roUrlTransfer helpers (headers, JSON, error handling)
      DateTime.bs                   # Date/time formatting utilities
      StringUtils.bs                # String helpers

  components/
    MainScene.xml/.bs               # Root Scene - nav stack, auth routing, deep linking

    screens/
      home/
        HomeScreen.xml/.bs          # Home with hero row, continue watching, libraries
      auth/
        ServerConnectionScreen.xml/.bs  # Manual URL entry + login
        ServerDiscoveryScreen.xml/.bs   # SSDP server discovery
      library/
        LibraryScreen.xml/.bs       # Library grid with sort/filter
      detail/
        MediaDetailScreen.xml/.bs   # Universal detail (movie, series, season, episode)
      search/
        SearchScreen.xml/.bs        # Search with history
      player/
        PlayerScreen.xml/.bs        # Video player wrapper + custom overlays
      settings/
        SettingsScreen.xml/.bs      # All settings (playback, parental, SSL)

    widgets/
      PosterRow.xml/.bs             # Horizontal scrolling poster row
      MediaPosterButton.xml/.bs     # Focusable poster tile (handles YouTube detection)
      HeroCarousel.xml/.bs          # Auto-rotating hero banner
      LoadingSpinner.xml/.bs        # Certification-required loading indicator
      ErrorDialog.xml/.bs           # Certification-required error dialogs
      SkipButton.xml/.bs            # Intro/credits skip overlay
      SubtitleOverlay.xml/.bs       # Custom subtitle rendering (fallback only)
      ResumeDialog.xml/.bs          # Resume vs play from beginning
      UpNextDialog.xml/.bs          # Up Next countdown overlay

    tasks/
      JellyfinApi.xml/.bs           # All Jellyfin REST calls (runs on Task thread)
      PlaybackReporter.xml/.bs      # 5-second progress reporting loop
      SegmentTracker.xml/.bs        # Intro/credits segment detection
      ServerDiscoveryTask.xml/.bs   # SSDP discovery
      ImagePrefetcher.xml/.bs       # Pre-warm images for smooth scrolling

    data/
      ContentNodeFactory.bs         # Transforms API responses -> ContentNode trees

  images/
    mm_icon_focus_hd.png            # Channel icon (336x210)
    mm_icon_focus_sd.png            # SD channel icon (108x69)
    splash_screen_fhd.png           # Splash (1920x1080) - Sashimi branding
    splash_screen_hd.png            # HD splash (1280x720)

  locale/
    en_US/translations.ts           # Localization strings

  tests/                            # Rooibos test files
```

### Key structural differences from tvOS

- **Tasks directory**: All networking must happen on Task threads (Roku requirement). Each major API concern gets its own Task node.
- **No ViewModel layer**: SceneGraph's observer pattern replaces MVVM. Screen components observe fields on Task nodes directly.
- **ContentNodeFactory**: Roku lists/grids consume ContentNode trees, so a translation layer converts JSON API responses to ContentNodes.
- **16KB registry budget**: Only essential data stored locally — auth token, server URL, user ID, settings. All playback history stays server-side.
- **SSDP instead of mDNS/Bonjour**: Roku doesn't support Bonjour, but Jellyfin broadcasts via SSDP.

## Architecture & Data Flow

### Navigation Stack

MainScene owns a simple array-based nav stack:

```
MainScene
  ├── m.navStack = []           # Array of screen references
  ├── m.currentScreen           # Top of stack, has focus
  └── onKeyEvent("back")        # Pop stack or exit channel
```

- Push: create node, append to children, push to stack, set focus
- Pop: remove from children, pop from stack, restore focus to new top
- Auth state determines initial screen (ServerConnectionScreen vs HomeScreen)

### Data Flow Pattern

Where tvOS uses `ViewModel -> JellyfinClient.shared -> @Published -> SwiftUI`, Roku uses:

```
Screen sets fields on Task node
  -> Task node runs on background thread
  -> Task calls Jellyfin API via roUrlTransfer
  -> Task parses JSON, builds ContentNode tree
  -> Task sets result on output field
  -> Screen observes output field, updates UI
```

Example — loading the home screen:

1. `HomeScreen` creates `JellyfinApi` Task node
2. Sets `task.request = { action: "getHomeData" }`
3. Task thread fetches resume items, next up, latest media, libraries
4. Task builds ContentNode trees and sets `task.homeData = result`
5. HomeScreen's observer fires, populates RowList with the ContentNode trees

### Authentication Flow

```
App Launch
  -> Registry.read("auth") for saved token/server
  -> If found: validate with getLibraryViews() call
    -> Success: show HomeScreen
    -> 401/fail: clear registry, show ServerConnectionScreen
  -> If not found: show ServerConnectionScreen

Login
  -> ServerDiscovery (SSDP) or manual URL entry
  -> POST /Users/AuthenticateByName
  -> Store token + serverUrl + userId in Registry (Flush!)
  -> Navigate to HomeScreen
```

### Deep Linking (Certification Required)

```
main(args) receives contentId + mediaType
  -> Store in m.global.deepLink
  -> After auth resolves:
    -> Fetch item by contentId
    -> If mediaType = "movie"/"episode": auto-play
    -> If mediaType = "series"/"season": navigate to detail
    -> If invalid contentId: fall back to home screen
```

### Global State

Roku's `m.global` (GlobalNode) replaces environment objects:

- `m.global.serverUrl` — current server
- `m.global.authToken` — access token
- `m.global.userId` — current user ID
- `m.global.deviceId` — persistent device UUID (generated once, stored in registry)
- `m.global.playbackSettings` — user preferences (max bitrate, auto-play, skip settings)

## Screen-by-Screen Feature Mapping

### Home Screen

| tvOS Feature | Roku Implementation |
|---|---|
| Hero carousel with autoplay timer | `HeroCarousel` widget — RowList with oversized row at top, Timer node for auto-rotation (8s). Background Poster for backdrop. |
| Continue Watching row | Dedicated `PosterRow` — merge resume items + NextUp in Task, deduplicate by series ID, sort by last played. Green progress bar via Rectangle overlay on poster. |
| Recently Added row | `PosterRow` populated by getLatestMedia call |
| Library rows | One `PosterRow` per library, lazy-loaded as user scrolls down |
| Home row customization | Settings stored in Registry as JSON. Row visibility + order read on HomeScreen init. |
| Pull to refresh | Options (*) button triggers refresh, or auto-refresh on screen focus return |
| AppHeader with profile avatar | Top-aligned Label (app name) + Poster (user avatar) |

### Authentication

| tvOS Feature | Roku Implementation |
|---|---|
| Manual server URL entry | TextEditBox node (Roku's native keyboard). Validate with test API call. |
| mDNS/Bonjour discovery | SSDP discovery via UDP broadcast on Task thread. Present discovered servers in LabelList. |
| Password auth | POST `/Users/AuthenticateByName`. Store token in Registry. |
| Session restore | Read Registry on launch, validate token with lightweight API call. |

### Library Browsing

| tvOS Feature | Roku Implementation |
|---|---|
| Grid view with posters | MarkupGrid or PosterGrid node. Paginated — 50 items per batch, append ContentNodes on scroll. |
| Sort options | Options (*) button opens dialog with sort choices (Name, Date, Rating, Play Count). Re-fetch with new sort param. |
| Filters (watched, favorites, resumable) | Same Options dialog, separate filter section. |
| Lazy loading / pagination | Track `itemFocused` on grid — trigger next page fetch at 80% of loaded items. |

### Media Detail

| tvOS Feature | Roku Implementation |
|---|---|
| Universal detail screen | Single `MediaDetailScreen` adapts layout by item type. Top area: backdrop Poster + metadata Labels. |
| Movie detail | Backdrop, title, overview, runtime, rating, genres, cast row |
| Series detail | Poster, metadata, season picker (LabelList), episode list for selected season |
| Episode detail | Episode thumbnail (or series backdrop), title, overview, air date, file info |
| YouTube/Pinchflat handling | Detect via `libraryName` containing "youtube". Circular mask on channel posters, landscape episode thumbnails, date-based episode ordering. |
| Play / Resume button | Focused Button. If resume position > threshold, show ResumeDialog. |
| Mark watched/unwatched | Button triggers Task API call. Toggle icon on completion. |
| Favorites | Same pattern as watched toggle. |
| Cast & crew | Horizontal PosterRow with person images + name Labels. |
| File info | Dialog showing codec, resolution, audio, subtitle info. |
| Item deletion / metadata refresh | Admin actions behind Options (*) menu with confirmation dialog. |

### Search

| tvOS Feature | Roku Implementation |
|---|---|
| Text search with keyboard | Roku's built-in Keyboard node |
| Debounced query-as-you-type | Timer node with 500ms delay. Reset on keystroke, fire search Task on completion. |
| Results grid | MarkupGrid split into Movies + Series sections |
| Search history | Last 10 queries in Registry as JSON array. Show as LabelList. |

### Settings

| tvOS Feature | Roku Implementation |
|---|---|
| Playback quality | RadioButtonList — Auto, 1080p, 720p, 480p. Maps to maxBitrate in Registry. |
| Auto-play next episode | Toggle |
| Skip intro/credits | Toggle for auto-skip. Manual skip button always available. |
| Resume threshold | Selection list (15s, 30s, 60s, 120s) |
| Parental controls | PIN entry dialog -> content rating filter in Registry |
| SSL certificate trust | Toggle for self-signed/expired cert trust |
| Sign out | Clear Registry auth section, navigate to ServerConnectionScreen |

## Video Playback Architecture

### Stream Resolution Strategy

```
1. Request PlaybackInfo with device profile:
   - DirectPlay: mp4/mkv, h264/hevc video, aac/ac3/eac3 audio
   - Transcoding: HLS with h264 video + aac audio

2. Select source by priority:
   - Transcoding URL (HLS) -> most reliable on Roku
   - Direct stream URL -> server-side remux
   - Direct play URL -> native container playback

3. Build ContentNode with:
   - url = selected stream URL
   - streamFormat = "hls" or "mp4"
   - title, description, releaseDate
```

Quality selection is server-side: tell Jellyfin to transcode at a specific max bitrate. Roku's adaptive engine handles the rest for HLS.

### Playback Progress Reporting

PlaybackReporter (Task node with repeating Timer):
- On media load: POST `/Sessions/Playing` (start)
- Every 5 seconds: POST `/Sessions/Playing/Progress` (position, isPaused)
- On stop/exit: POST `/Sessions/Playing/Stopped`
- Quick-exit protection: if played < 10 seconds, report original resume position

### Subtitle Handling

Two paths:

1. **In-stream (HLS)**: Roku handles WebVTT in HLS manifests natively. User selects via Options (*) button -> built-in caption picker. Preferred path.
2. **Sideloaded (external)**: Populate `SubtitleTracks` on ContentNode with URLs pointing to `/Videos/{id}/Subtitles/{index}/Stream.srt`. Request SRT format (Roku doesn't support sideloaded WebVTT, only SRT and TTML).

### Audio Track Selection

Let the server handle audio track selection (Roku's audio track API is unreliable). When user picks a different audio track: re-request PlaybackInfo with preferred audio stream index, get new transcoding URL, reload player at saved position.

### Intro/Credits Skip

SegmentTracker (Task node):
- Fetch `/Episode/{id}/IntroSkipperSegments` on media load
- Observe Video node position every 0.5s
- When position enters segment range: show SkipButton overlay on PlayerScreen
- Auto-skip if enabled in settings, otherwise user presses OK to skip

### Chapter Markers

No native Roku chapter API. Custom chapter overlay:
- Fetch chapters from item metadata
- Options (*) or dedicated button shows chapter list
- Selecting a chapter seeks to `chapterStartSeconds`

### Trick Play (Certification Required)

Required for VOD content. Two options:
1. Jellyfin trickplay images served as BIF format or HLS I-Frame playlists
2. Fallback: the existing Jellyfin Roku client has trickplay support — follow that approach

Set `HDBIFSURL`/`SDBIFSURL` on ContentNode for BIF, or use HLS I-Frame playlists (Roku OS 9.3+).

### Up Next / Auto-Play

When `Video.state = "finished"`:
- If autoPlayNextEpisode enabled: show UpNextDialog with 10-second countdown
- Shows next episode title + thumbnail
- User can cancel (Back) or confirm (OK)
- On countdown complete or OK: load next episode
- Next episode resolution: sequential indexNumber for TV, first higher index for YouTube (date-based)

### Resume Dialog

On media load, if `playbackPositionTicks > resumeThreshold`:
- Show ResumeDialog: "Resume from XX:XX" / "Play from Beginning"
- Resume: `Video.seek = savedPositionSeconds` after playback starts
- Play from beginning: start normally

## Performance & Low-End Device Strategy

### Texture Memory Budget

Low-end Roku devices have ~95MB texture memory. Images stored as RGBA (w x h x 4 bytes).

**Strategy:**
- Right-size all images: request from Jellyfin at display size, never larger. Set `loadWidth`/`loadHeight` on every Poster node.
- Hero images: 960x540 on screens with other content. Full resolution only for detail backdrops.
- Poster sizes: 210x315 for grid items, 160x240 for row items.
- YouTube circular avatars: 160x160.
- Limit visible rows: load 3-4 rows initially on home, load more on scroll. Release off-screen image references.

### ContentNode Creation

All ContentNode construction happens in Task threads (never on the render thread).
- 50 items per batch for grids
- Pre-fetch next page when focus reaches 80% of loaded items
- Debounce rapid scrolling

### Screen Lifecycle

When a screen is buried in the nav stack:
- Pause Timer nodes (hero carousel, progress reporter)
- On return: re-check if data needs refresh

### Launch Time (Certification: < 20 seconds)

```
Main.bs
  -> Create Scene (instant)
  -> Fire AppLaunchComplete beacon
  -> Check Registry for saved auth
  -> Show first screen shell immediately (with spinner)
  -> Kick off API calls in parallel Tasks
  -> Populate rows as data arrives (progressive rendering)
```

Fire `signalBeacon("AppLaunchComplete")` as soon as the first screen renders, even if data is still loading. Spinner satisfies certification while Tasks fetch content.

### General Performance Rules

- Use built-in RowList/PosterGrid/MarkupGrid nodes everywhere (native C++, much faster than BrightScript-driven layouts)
- Avoid custom-drawn components where built-in nodes suffice
- Keep component tree shallow
- Test on lowest-end device regularly

## Certification Compliance

### Mandatory Requirements

| Requirement | Implementation |
|---|---|
| AppLaunchComplete beacon | Fire in MainScene.init() after first screen renders. < 20s from launch. |
| Loading spinners | LoadingSpinner widget shown during all Task fetches. No blank/frozen screens. |
| Error dialogs | ErrorDialog widget for: network failures, auth failures, playback errors, invalid URLs. |
| Deep linking | `main(args)` captures `contentId` + `mediaType`. Route after auth. Invalid -> home. |
| Trick play thumbnails | BIF files or HLS I-Frame playlists during scrubbing. Required for VOD. |
| Back button behavior | Every screen handles Back. Home Back -> exits. Player Back -> stops, returns to detail. |
| Accessibility / TTS | Built-in SceneGraph nodes (TTS-aware by default). Custom widgets set `role`, `name`, `description`. |
| Screensaver suppression | Video node handles automatically during playback. |

### Submission Checklist

- Channel icon correct dimensions (336x210 HD, 108x69 SD)
- Splash screen correct dimensions (1920x1080 FHD, 1280x720 HD)
- All manifest fields present
- No `stop` or `print` statements in production (strip via build script)
- Deep linking test cases documented
- Support contact info valid

## Development Workflow

### Local Development

- VSCode + BrightScript Language extension
- Enable Developer Mode on Roku (Home 3x, Up 2x, Right Left Right Left Right)
- Deploy: build -> zip -> HTTP upload to `http://<roku-ip>`
- Debug: telnet port 8085 (BrightScript console), port 8080 (SceneGraph inspector)

### CI (GitHub Actions)

```
On push / PR:
  1. Lint (bslint)
  2. Transpile (bsc) — verify compilation
  3. Run Rooibos tests
  4. Package — produce sashimi.zip artifact
```

Device testing is manual (no Roku simulator in CI). Same as tvOS: CI builds, deploy to hardware, test before merge.

### Branch Protection

Same rules as tvOS repo: main branch protected, all changes via PRs, CI checks required, manual testing before merge.

## Implementation Phases

### Phase 1 — Foundation & Auth
- Project scaffolding, manifest, splash screen
- Registry helpers, HTTP utilities, JellyfinApi Task
- ServerConnectionScreen (manual URL + login)
- Session persistence and restore
- MainScene with nav stack

### Phase 2 — Home & Browsing
- HomeScreen with library rows, continue watching, recently added
- Hero carousel
- LibraryScreen with grid, pagination, sort/filter
- MediaPosterButton widget with YouTube detection

### Phase 3 — Detail & Search
- MediaDetailScreen (movie, series, season, episode, YouTube)
- Cast/crew display
- Watched/favorite/delete actions
- SearchScreen with history and debounce

### Phase 4 — Video Player
- PlayerScreen with Video node
- Stream resolution (direct play vs transcode)
- Playback progress reporting
- Resume dialog
- Subtitle + audio track handling

### Phase 5 — Player Extras
- Intro/credits skip (SegmentTracker)
- Chapter list overlay
- Up Next / auto-play
- Trick play thumbnails
- Quality selection

### Phase 6 — Settings & Polish
- SettingsScreen (all preferences)
- Parental controls with PIN
- SSL certificate trust
- Deep linking
- Accessibility pass
- Low-end device optimization
- SSDP server discovery

### Phase 7 — Certification Prep
- Certification checklist audit
- Performance benchmarking (launch time)
- Error handling sweep
- Submission to Roku Channel Store
