# Sashimi Roku — Phase 3: Detail Screen & Search Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add MediaDetailScreen (movie, series, season, episode with actions), SearchScreen with debounced search and history, and wire item selection from HomeScreen/LibraryScreen to the detail view.

**Architecture:** MediaDetailScreen adapts layout by item type. Uses ButtonGroup for actions (Play, Resume, Watched, Favorite). SearchScreen uses StandardKeyboardDialog for input with Timer-based debounce. All API calls through existing JellyfinApi task loop.

**Tech Stack:** BrighterScript, Roku SceneGraph XML, existing utilities.

**Working directory:** `/Users/mondo/Documents/git/sashimi-roku`

**Deploy command:** `npm run package && curl --user rokudev:1234 --digest -F "mysubmit=Install" -F "archive=@sashimi.zip" "http://192.168.86.30/plugin_install"`

**Roku constraints (from Phase 1/2 testing):**
- No `cornerRadius`, no `BusySpinner`, no `TextEditBox`
- Use `StandardKeyboardDialog` for text input, `ButtonGroup` for navigation
- Long-running task loop pattern (not one-shot)
- `autoImportComponentScript: true` — no `<script>` tags in XML
- Add imports for namespaces used in .bs files
- Always `setFocus(true)` after dialog close
- Background: `#0e0e1a`, cards: `#101420`
- Start tasks with `m.apiTask.control = "RUN"`

---

## File Structure

### Files to Create

```
components/
  screens/
    detail/
      MediaDetailScreen.xml       # Universal detail screen layout
      MediaDetailScreen.bs        # Detail screen logic — adapts by item type
    search/
      SearchScreen.xml            # Search screen layout
      SearchScreen.bs             # Search logic with debounce and history
```

### Files to Modify

```
components/
  tasks/JellyfinApi.bs            # Add: getItem, getSeasons, getEpisodes, search, markPlayed, markUnplayed, markFavorite, removeFavorite
  MainScene.bs                    # Wire detail screen navigation, add search, handle back from detail
```

---

## Chunk 1: API Extensions

### Task 1: Add Detail & Search API Actions

Add to `components/tasks/JellyfinApi.bs`:

**New actions to route:**
- `getItem` — fetch single item with full details
- `getSeasons` — fetch seasons for a series
- `getEpisodes` — fetch episodes for a series/season
- `search` — search for movies and series
- `markPlayed` / `markUnplayed` — toggle watched
- `markFavorite` / `removeFavorite` — toggle favorite

**API implementations:**

```brightscript
sub doGetItem(request as object)
    itemId = request.itemId
    print "[API] Getting item: " + itemId
    url = Http.apiUrl("/Users/" + m.global.userId + "/Items/" + itemId)
    url += "?Fields=Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,People,UserData,Chapters,ParentBackdropImageTags"
    url += "&EnableImageTypes=Primary,Backdrop,Thumb"
    result = Http.getJson(url)
    if result <> invalid and result.Id <> invalid
        m.top.response = { success: true, action: "getItem", item: result }
    else
        m.top.response = { success: false, action: "getItem", error: "Could not load item." }
    end if
end sub

sub doGetSeasons(request as object)
    seriesId = request.seriesId
    print "[API] Getting seasons for: " + seriesId
    url = Http.apiUrl("/Shows/" + seriesId + "/Seasons")
    url += "?UserId=" + m.global.userId
    url += "&Fields=Overview,PrimaryImageAspectRatio"
    result = Http.getJson(url)
    if result <> invalid and result.Items <> invalid
        m.top.response = { success: true, action: "getSeasons", items: result.Items, seriesId: seriesId }
    else
        m.top.response = { success: true, action: "getSeasons", items: [], seriesId: seriesId }
    end if
end sub

sub doGetEpisodes(request as object)
    seriesId = request.seriesId
    seasonId = ""
    if request.seasonId <> invalid then seasonId = request.seasonId
    print "[API] Getting episodes for series: " + seriesId
    url = Http.apiUrl("/Shows/" + seriesId + "/Episodes")
    url += "?UserId=" + m.global.userId
    url += "&Fields=Overview,PrimaryImageAspectRatio,CommunityRating,ImageTags,UserData"
    url += "&EnableImageTypes=Primary,Thumb"
    if seasonId <> "" then url += "&SeasonId=" + seasonId
    result = Http.getJson(url)
    if result <> invalid and result.Items <> invalid
        m.top.response = { success: true, action: "getEpisodes", items: result.Items, seriesId: seriesId, seasonId: seasonId }
    else
        m.top.response = { success: true, action: "getEpisodes", items: [], seriesId: seriesId, seasonId: seasonId }
    end if
end sub

sub doSearch(request as object)
    query = request.query
    limit = 50
    if request.limit <> invalid then limit = request.limit
    print "[API] Searching: " + query
    url = Http.apiUrl("/Users/" + m.global.userId + "/Items")
    url += "?SearchTerm=" + query
    url += "&Limit=" + str(limit).Trim()
    url += "&Fields=Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,UserData"
    url += "&EnableImageTypes=Primary,Backdrop,Thumb"
    url += "&IncludeItemTypes=Movie,Series"
    url += "&Recursive=true"
    result = Http.getJson(url)
    if result <> invalid and result.Items <> invalid
        m.top.response = { success: true, action: "search", items: result.Items, query: query }
    else
        m.top.response = { success: true, action: "search", items: [], query: query }
    end if
end sub

sub doMarkPlayed(request as object)
    itemId = request.itemId
    print "[API] Marking played: " + itemId
    url = Http.apiUrl("/Users/" + m.global.userId + "/PlayedItems/" + itemId)
    Http.postJson(url, invalid)
    m.top.response = { success: true, action: "markPlayed", itemId: itemId }
end sub

sub doMarkUnplayed(request as object)
    itemId = request.itemId
    print "[API] Marking unplayed: " + itemId
    url = Http.apiUrl("/Users/" + m.global.userId + "/PlayedItems/" + itemId)
    Http.deleteRequest(url)
    m.top.response = { success: true, action: "markUnplayed", itemId: itemId }
end sub

sub doMarkFavorite(request as object)
    itemId = request.itemId
    print "[API] Marking favorite: " + itemId
    url = Http.apiUrl("/Users/" + m.global.userId + "/FavoriteItems/" + itemId)
    Http.postJson(url, invalid)
    m.top.response = { success: true, action: "markFavorite", itemId: itemId }
end sub

sub doRemoveFavorite(request as object)
    itemId = request.itemId
    print "[API] Removing favorite: " + itemId
    url = Http.apiUrl("/Users/" + m.global.userId + "/FavoriteItems/" + itemId)
    Http.deleteRequest(url)
    m.top.response = { success: true, action: "removeFavorite", itemId: itemId }
end sub
```

Verify build, commit: `git commit -m "feat: add detail and search API actions (getItem, seasons, episodes, search, played, favorite)"`

---

## Chunk 2: MediaDetailScreen

### Task 2: MediaDetailScreen

**Files:**
- Create: `components/screens/detail/MediaDetailScreen.xml`
- Create: `components/screens/detail/MediaDetailScreen.bs`

The detail screen adapts based on item type:
- **Movie**: Backdrop + poster + title + overview + metadata + action buttons
- **Series**: Backdrop + title + overview + seasons list + episodes list
- **Episode**: Backdrop + title + series info + overview + action buttons

Layout: Left side has backdrop/poster area, right side has metadata and action buttons. Below that, a RowList for related content (seasons/episodes for series, cast for movies).

**MediaDetailScreen.xml** — Declares the layout with:
- Background Rectangle
- Backdrop Poster (full width, semi-transparent)
- Poster image (left side, 300x450)
- Title, subtitle, overview labels
- Metadata labels (year, runtime, rating, genres)
- ButtonGroup for actions (Play/Resume, Watched, Favorite, etc.)
- RowList for related content (seasons, episodes, cast)
- JellyfinApi task
- Loading label

**MediaDetailScreen.bs** — Core logic:
- `onItemDataChanged()` — receives item data, determines type, fetches full item details via getItem
- `onItemLoaded()` — populates UI fields, sets up action buttons based on item state
- `buildActionButtons()` — creates button list based on: hasProgress (Resume/Start Over), isPlayed (Mark Watched/Unwatched), isFavorite (Add/Remove Favorite)
- `onActionButton()` — handles Play, Resume, Watched toggle, Favorite toggle
- For Series: fetches seasons, then episodes for selected season
- For Episode: shows series info, fetches adjacent episodes for "More Episodes" row
- `onKeyEvent()` — handle back button, options for admin actions

Commit: `git commit -m "feat: add MediaDetailScreen with movie, series, and episode layouts"`

---

## Chunk 3: SearchScreen & Navigation Wiring

### Task 3: SearchScreen

**Files:**
- Create: `components/screens/search/SearchScreen.xml`
- Create: `components/screens/search/SearchScreen.bs`

Search uses StandardKeyboardDialog for input (triggered by a "Search..." button). Results display in a PosterGrid. Search history stored in Registry (max 10 items).

**SearchScreen.xml** — Layout:
- Header with title
- ButtonGroup with "Search..." button + recent search buttons
- PosterGrid for results
- Loading/empty labels
- JellyfinApi task

**SearchScreen.bs** — Logic:
- `onSearchPressed()` — opens StandardKeyboardDialog
- `onKeyboardDone()` — saves to history, fires API search
- `onSearchResults()` — populates PosterGrid with results
- `loadHistory()` — reads search history from Registry
- `saveToHistory()` — prepends query, trims to 10, saves to Registry

Commit: `git commit -m "feat: add SearchScreen with keyboard dialog, results grid, and search history"`

### Task 4: Wire Navigation

**Modify:** `components/MainScene.bs`

- `onItemSelected()` — push MediaDetailScreen, set itemData
- Add "Search" to HomeScreen options dialog
- HomeScreen `onKeyEvent` — map a button (e.g., left on top row) to search
- Wire MediaDetailScreen observers (selectedItem for series→episode navigation)
- Handle back from detail/search screens via existing popScreen()

Commit: `git commit -m "feat: wire detail and search screen navigation"`

---

## Phase 3 Deliverable

1. MediaDetailScreen showing movie/series/episode details with backdrop and poster images
2. Action buttons: Play (placeholder), Mark Watched/Unwatched, Add/Remove Favorite
3. Series detail shows seasons and episodes
4. SearchScreen with keyboard input, debounced results, and search history
5. Full navigation: Home → Detail, Home → Search, Library → Detail
6. Back button returns to previous screen at all levels
