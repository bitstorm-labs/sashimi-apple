# Sashimi Roku — Phase 2: Home Screen & Library Browsing Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the placeholder HomeScreen with a full media browsing experience — hero carousel, continue watching row, per-library recently added rows, and a library detail screen with grid browsing, pagination, sort, and filter.

**Architecture:** Extend the JellyfinApi Task with home screen and library data actions. Build reusable row/grid components using Roku's native RowList and PosterGrid nodes. Use ContentNode trees for data binding. Follow established patterns from Phase 1 (one-shot Task, ButtonGroup navigation, dark card UI).

**Tech Stack:** BrighterScript, Roku SceneGraph XML, existing Http.bs/Registry.bs utilities.

**Minimum Roku OS:** 11.0+

**Spec:** See `docs/superpowers/specs/2026-03-13-roku-port-design.md` (Phase 2 section)

**Working directory:** `/Users/mondo/Documents/git/sashimi-roku`

**Lessons from Phase 1 device testing:**
- Do NOT use `cornerRadius` on Rectangle (not supported on all devices)
- Do NOT use `TextEditBox` for inline input (use `StandardKeyboardDialog`)
- Do NOT use `BusySpinner` (use simple Label)
- Do NOT use invalid fields like `focusedColor` on Button or `textColor` on LabelList
- ButtonGroup handles D-pad navigation automatically — use it for vertical button lists
- Always restore focus with `setFocus(true)` after dialogs close
- Use one-shot Task pattern (set `functionName`, `control="stop"`, `control="RUN"`) not long-running task loops
- `autoImportComponentScript: true` — never add `<script>` tags in XML
- Add `import "pkg:/source/utils/Http.bs"` in `.bs` files that use Http namespace
- Add `import "pkg:/source/utils/Registry.bs"` in `.bs` files that use Registry namespace
- Use `focusBitmapUri` and `focusFootprintBitmapUri` on ButtonGroup for visible focus
- Background color: `#0e0e1a`, card color: `#101420`
- Test on device after each major feature, not just at the end

---

## File Structure

### Files to Create

```
components/
  screens/
    home/
      HomeScreen.xml              # Full home screen with RowList
      HomeScreen.bs               # Home screen data loading and navigation
    library/
      LibraryScreen.xml           # Library detail grid with sort/filter
      LibraryScreen.bs            # Grid data loading, pagination, sort/filter
  widgets/
    PosterRow.xml                 # Row item renderer for RowList (poster + title)
    PosterRow.bs                  # Poster row focus handling
    MediaPoster.xml               # Individual poster tile (image + title + progress bar)
    MediaPoster.bs                # Poster image loading and YouTube detection

source/
  utils/
    ImageUrl.bs                   # Helper to build Jellyfin image URLs
```

### Files to Modify

```
components/
  tasks/
    JellyfinApi.bs                # Add: getLibraryViews, getResumeItems, getNextUp, getLatestMedia, getItems
  MainScene.bs                    # Add: LibraryScreen to nav stack, handle screen transitions
  MainScene.xml                   # Add: launchArgs handling (no changes needed, already has it)
```

---

## Chunk 1: API Layer & Image URL Helper

### Task 1: Image URL Helper

**Files:**
- Create: `source/utils/ImageUrl.bs`

- [ ] **Step 1: Create source/utils/ImageUrl.bs**

```brightscript
namespace ImageUrl

    function primary(itemId as string, maxWidth as integer) as string
        return m.global.serverUrl + "/Items/" + itemId + "/Images/Primary?maxWidth=" + str(maxWidth).Trim() + "&quality=90"
    end function

    function backdrop(itemId as string, maxWidth as integer) as string
        return m.global.serverUrl + "/Items/" + itemId + "/Images/Backdrop?maxWidth=" + str(maxWidth).Trim() + "&quality=90"
    end function

    function thumb(itemId as string, maxWidth as integer) as string
        return m.global.serverUrl + "/Items/" + itemId + "/Images/Thumb?maxWidth=" + str(maxWidth).Trim() + "&quality=90"
    end function

end namespace
```

- [ ] **Step 2: Verify build**

```bash
npm run build
```

- [ ] **Step 3: Commit**

```bash
git add source/utils/ImageUrl.bs
git commit -m "feat: add ImageUrl helper for building Jellyfin image URLs"
```

---

### Task 2: Extend JellyfinApi with Home Screen Actions

**Files:**
- Modify: `components/tasks/JellyfinApi.bs`

- [ ] **Step 1: Add new actions to the executeRequest router**

Add these cases to the `if/else if` chain in `executeRequest()`:

```brightscript
    else if action = "getLibraryViews"
        doGetLibraryViews()
    else if action = "getResumeItems"
        doGetResumeItems(request)
    else if action = "getNextUp"
        doGetNextUp(request)
    else if action = "getLatestMedia"
        doGetLatestMedia(request)
```

- [ ] **Step 2: Implement doGetLibraryViews**

```brightscript
sub doGetLibraryViews()
    print "[API] Getting library views"
    url = Http.apiUrl("/Users/" + m.global.userId + "/Views")
    result = Http.getJson(url)

    if result <> invalid and result.Items <> invalid
        print "[API] Found " + str(result.Items.count()) + " libraries"
        m.top.response = {
            success: true
            action: "getLibraryViews"
            items: result.Items
        }
    else
        print "[API] Failed to get library views"
        m.top.response = {
            success: false
            action: "getLibraryViews"
            error: "Could not load libraries."
        }
    end if
end sub
```

- [ ] **Step 3: Implement doGetResumeItems**

```brightscript
sub doGetResumeItems(request as object)
    limit = 20
    if request.limit <> invalid then limit = request.limit
    print "[API] Getting resume items (limit=" + str(limit) + ")"

    url = Http.apiUrl("/Users/" + m.global.userId + "/Items/Resume")
    url += "?Limit=" + str(limit).Trim()
    url += "&Fields=Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,UserData,ParentBackdropImageTags,Path"
    url += "&EnableImageTypes=Primary,Backdrop,Thumb"
    url += "&Recursive=true"

    result = Http.getJson(url)

    if result <> invalid and result.Items <> invalid
        print "[API] Found " + str(result.Items.count()) + " resume items"
        m.top.response = {
            success: true
            action: "getResumeItems"
            items: result.Items
        }
    else
        m.top.response = {
            success: true
            action: "getResumeItems"
            items: []
        }
    end if
end sub
```

- [ ] **Step 4: Implement doGetNextUp**

```brightscript
sub doGetNextUp(request as object)
    limit = 50
    if request.limit <> invalid then limit = request.limit
    print "[API] Getting next up (limit=" + str(limit) + ")"

    url = Http.apiUrl("/Shows/NextUp")
    url += "?UserId=" + m.global.userId
    url += "&Limit=" + str(limit).Trim()
    url += "&Fields=Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,UserData,ParentBackdropImageTags,Path"
    url += "&EnableImageTypes=Primary,Backdrop,Thumb"
    url += "&EnableRewatching=false"
    url += "&DisableFirstEpisode=false"

    result = Http.getJson(url)

    if result <> invalid and result.Items <> invalid
        print "[API] Found " + str(result.Items.count()) + " next up items"
        m.top.response = {
            success: true
            action: "getNextUp"
            items: result.Items
        }
    else
        m.top.response = {
            success: true
            action: "getNextUp"
            items: []
        }
    end if
end sub
```

- [ ] **Step 5: Implement doGetLatestMedia**

```brightscript
sub doGetLatestMedia(request as object)
    limit = 16
    if request.limit <> invalid then limit = request.limit
    parentId = ""
    if request.parentId <> invalid then parentId = request.parentId
    print "[API] Getting latest media (parentId=" + parentId + ", limit=" + str(limit) + ")"

    url = Http.apiUrl("/Users/" + m.global.userId + "/Items/Latest")
    url += "?Limit=" + str(limit).Trim()
    url += "&Fields=Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,UserData"
    url += "&EnableImageTypes=Primary,Backdrop,Thumb"

    if parentId <> ""
        url += "&ParentId=" + parentId
    end if

    result = Http.getJson(url)

    if result <> invalid
        ' /Items/Latest returns an array directly, not wrapped in Items
        items = result
        if type(result) = "roAssociativeArray" and result.Items <> invalid
            items = result.Items
        end if
        print "[API] Found " + str(items.count()) + " latest items"
        m.top.response = {
            success: true
            action: "getLatestMedia"
            items: items
            parentId: parentId
        }
    else
        m.top.response = {
            success: true
            action: "getLatestMedia"
            items: []
            parentId: parentId
        }
    end if
end sub
```

- [ ] **Step 6: Verify build**

```bash
npm run build
```

- [ ] **Step 7: Commit**

```bash
git add components/tasks/JellyfinApi.bs
git commit -m "feat: add home screen API actions (libraries, resume, nextUp, latestMedia)"
```

---

### Task 3: Add getItems Action for Library Browsing

**Files:**
- Modify: `components/tasks/JellyfinApi.bs`

- [ ] **Step 1: Add getItems case to executeRequest router**

```brightscript
    else if action = "getItems"
        doGetItems(request)
```

- [ ] **Step 2: Implement doGetItems**

```brightscript
sub doGetItems(request as object)
    parentId = ""
    if request.parentId <> invalid then parentId = request.parentId
    sortBy = "SortName"
    if request.sortBy <> invalid then sortBy = request.sortBy
    sortOrder = "Ascending"
    if request.sortOrder <> invalid then sortOrder = request.sortOrder
    limit = 50
    if request.limit <> invalid then limit = request.limit
    startIndex = 0
    if request.startIndex <> invalid then startIndex = request.startIndex

    print "[API] Getting items (parentId=" + parentId + ", sort=" + sortBy + ", start=" + str(startIndex) + ")"

    url = Http.apiUrl("/Users/" + m.global.userId + "/Items")
    url += "?SortBy=" + sortBy
    url += "&SortOrder=" + sortOrder
    url += "&Recursive=true"
    url += "&Fields=Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,UserData"
    url += "&EnableImageTypes=Primary,Backdrop,Thumb"
    url += "&Limit=" + str(limit).Trim()
    url += "&StartIndex=" + str(startIndex).Trim()

    if parentId <> ""
        url += "&ParentId=" + parentId
    end if

    if request.includeTypes <> invalid and request.includeTypes <> ""
        url += "&IncludeItemTypes=" + request.includeTypes
    end if

    if request.isPlayed <> invalid
        url += "&IsPlayed=" + LCase(str(request.isPlayed))
    end if

    if request.isFavorite <> invalid
        url += "&IsFavorite=" + LCase(str(request.isFavorite))
    end if

    if request.isResumable <> invalid
        url += "&IsResumable=" + LCase(str(request.isResumable))
    end if

    if request.nameStartsWith <> invalid and request.nameStartsWith <> ""
        url += "&NameStartsWith=" + request.nameStartsWith
    end if

    result = Http.getJson(url)

    if result <> invalid and result.Items <> invalid
        print "[API] Found " + str(result.Items.count()) + " of " + str(result.TotalRecordCount) + " total items"
        m.top.response = {
            success: true
            action: "getItems"
            items: result.Items
            totalRecordCount: result.TotalRecordCount
            startIndex: startIndex
        }
    else
        m.top.response = {
            success: false
            action: "getItems"
            error: "Could not load items."
            items: []
            totalRecordCount: 0
            startIndex: startIndex
        }
    end if
end sub
```

- [ ] **Step 3: Verify build**

```bash
npm run build
```

- [ ] **Step 4: Commit**

```bash
git add components/tasks/JellyfinApi.bs
git commit -m "feat: add getItems API action with sort, filter, and pagination"
```

---

## Chunk 2: Home Screen Components

### Task 4: MediaPoster Widget

**Files:**
- Create: `components/widgets/MediaPoster.xml`
- Create: `components/widgets/MediaPoster.bs`

This is the individual poster tile used in rows. It shows a poster image with title text below and an optional progress bar overlay.

- [ ] **Step 1: Create components/widgets/MediaPoster.xml**

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<component name="MediaPoster" extends="Group">
    <interface>
        <field id="itemData" type="assocarray" onChange="onItemDataChanged" />
        <field id="posterSize" type="string" value="standard" />
    </interface>
    <children>
        <!-- Poster image -->
        <Poster
            id="posterImage"
            width="210"
            height="315"
            loadWidth="210"
            loadHeight="315"
            loadDisplayMode="scaleToZoom"
        />
        <!-- Focus highlight border -->
        <Rectangle
            id="focusBorder"
            width="214"
            height="319"
            translation="[-2, -2]"
            color="#4a4a8a"
            visible="false"
        />
        <!-- Title below poster -->
        <Label
            id="titleLabel"
            text=""
            font="font:SmallestSystemFont"
            color="#CCCCCC"
            width="210"
            translation="[0, 320]"
            maxLines="2"
            ellipsizeOnBoundary="true"
        />
        <!-- Progress bar (for resume items) -->
        <Rectangle
            id="progressBg"
            translation="[0, 308]"
            width="210"
            height="6"
            color="#333333"
            visible="false"
        />
        <Rectangle
            id="progressBar"
            translation="[0, 308]"
            width="0"
            height="6"
            color="#00CC66"
            visible="false"
        />
    </children>
</component>
```

- [ ] **Step 2: Create components/widgets/MediaPoster.bs**

```brightscript
import "pkg:/source/utils/ImageUrl.bs"

sub init()
    m.posterImage = m.top.findNode("posterImage")
    m.focusBorder = m.top.findNode("focusBorder")
    m.titleLabel = m.top.findNode("titleLabel")
    m.progressBg = m.top.findNode("progressBg")
    m.progressBar = m.top.findNode("progressBar")
end sub

sub onItemDataChanged()
    item = m.top.itemData
    if item = invalid then return

    ' Set title
    title = ""
    if item.Name <> invalid then title = item.Name
    if item.SeriesName <> invalid and item.SeriesName <> ""
        title = item.SeriesName + " - " + title
    end if
    m.titleLabel.text = title

    ' Set poster image
    itemId = item.Id
    if itemId <> invalid and itemId <> ""
        ' Check if item has its own primary image
        if item.ImageTags <> invalid and item.ImageTags.Primary <> invalid
            m.posterImage.uri = ImageUrl.primary(itemId, 210)
        else if item.SeriesId <> invalid and item.SeriesId <> ""
            ' Fall back to series poster
            m.posterImage.uri = ImageUrl.primary(item.SeriesId, 210)
        end if
    end if

    ' Show progress bar if item has resume progress
    if item.UserData <> invalid and item.UserData.PlayedPercentage <> invalid
        percentage = item.UserData.PlayedPercentage
        if percentage > 0 and percentage < 100
            m.progressBg.visible = true
            m.progressBar.visible = true
            m.progressBar.width = 210 * (percentage / 100)
        end if
    end if
end sub
```

- [ ] **Step 3: Verify build**

```bash
npm run build
```

- [ ] **Step 4: Commit**

```bash
git add components/widgets/MediaPoster.xml components/widgets/MediaPoster.bs
git commit -m "feat: add MediaPoster widget with image loading and progress bar"
```

---

### Task 5: Full HomeScreen Implementation

**Files:**
- Rewrite: `components/screens/home/HomeScreen.xml`
- Rewrite: `components/screens/home/HomeScreen.bs`

The HomeScreen uses a RowList to display horizontal scrolling rows of media posters. Each row represents a category: Continue Watching, Recently Added per library.

- [ ] **Step 1: Create components/screens/home/HomeScreen.xml**

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<component name="HomeScreen" extends="Group">
    <interface>
        <field id="signOut" type="boolean" value="false" alwaysNotify="true" />
        <field id="selectedItem" type="assocarray" alwaysNotify="true" />
        <field id="selectedLibrary" type="assocarray" alwaysNotify="true" />
    </interface>
    <children>
        <!-- Background -->
        <Rectangle width="1920" height="1080" color="#0e0e1a" />

        <!-- Header bar -->
        <Rectangle
            id="headerBg"
            width="1920"
            height="80"
            color="#101420"
            opacity="0.9"
        />
        <Label
            id="headerTitle"
            text="Sashimi"
            font="font:MediumBoldSystemFont"
            color="#FFFFFF"
            translation="[192, 20]"
        />
        <Label
            id="headerUser"
            text=""
            font="font:SmallSystemFont"
            color="#888888"
            horizAlign="right"
            width="1536"
            translation="[192, 25]"
        />

        <!-- Main content: RowList for all media rows -->
        <RowList
            id="rowList"
            translation="[130, 100]"
            itemSize="[1660, 400]"
            numRows="4"
            itemSpacing="[0, 20]"
            focusBitmapUri=""
            focusFootprintBitmapUri=""
            rowItemSize="[[230, 380]]"
            rowItemSpacing="[[20, 0]]"
            showRowLabel="[true]"
            showRowCounter="[false]"
            rowLabelFont="font:MediumBoldSystemFont"
            rowLabelColor="#FFFFFF"
            rowFocusAnimationStyle="fixedFocusWrap"
        />

        <!-- Loading indicator -->
        <Label
            id="loadingLabel"
            text="Loading..."
            font="font:MediumSystemFont"
            color="#CCCCCC"
            horizAlign="center"
            width="1920"
            translation="[0, 500]"
            visible="true"
        />

        <!-- Empty state -->
        <Label
            id="emptyLabel"
            text=""
            font="font:MediumSystemFont"
            color="#888888"
            horizAlign="center"
            width="1920"
            translation="[0, 500]"
            visible="false"
        />

        <!-- API Task -->
        <JellyfinApi id="apiTask" />

        <!-- Toast Overlay -->
        <ToastOverlay id="toast" />
    </children>
</component>
```

- [ ] **Step 2: Create components/screens/home/HomeScreen.bs**

```brightscript
import "pkg:/source/utils/Registry.bs"
import "pkg:/source/utils/ImageUrl.bs"

sub init()
    m.rowList = m.top.findNode("rowList")
    m.loadingLabel = m.top.findNode("loadingLabel")
    m.emptyLabel = m.top.findNode("emptyLabel")
    m.headerUser = m.top.findNode("headerUser")
    m.apiTask = m.top.findNode("apiTask")
    m.toast = m.top.findNode("toast")

    m.apiTask.observeFieldScoped("response", "onApiResponse")

    ' State
    m.libraries = []
    m.continueWatchingItems = []
    m.rowContent = invalid
    m.pendingRequests = 0

    ' Set header
    m.headerUser.text = Registry.getUserName()

    ' Observe row selection for navigation
    m.rowList.observeFieldScoped("rowItemSelected", "onRowItemSelected")

    ' Start loading data
    loadHomeData()
end sub

sub loadHomeData()
    m.loadingLabel.visible = true
    m.rowList.visible = false

    ' First fetch libraries, then other data
    m.apiTask.request = { action: "getLibraryViews" }
end sub

sub onApiResponse()
    response = m.apiTask.response
    if response = invalid then return

    action = response.action

    if action = "getLibraryViews"
        onLibrariesLoaded(response)
    else if action = "getResumeItems"
        onResumeItemsLoaded(response)
    else if action = "getNextUp"
        onNextUpLoaded(response)
    else if action = "getLatestMedia"
        onLatestMediaLoaded(response)
    end if
end sub

sub onLibrariesLoaded(response as object)
    if not response.success then return

    ' Filter to media libraries only
    m.libraries = []
    for each lib in response.items
        collectionType = ""
        if lib.CollectionType <> invalid then collectionType = LCase(lib.CollectionType)
        if collectionType = "movies" or collectionType = "tvshows" or collectionType = "music" or collectionType = ""
            m.libraries.push(lib)
        end if
    end for

    print "[Home] Loaded " + str(m.libraries.count()) + " libraries"

    ' Now fetch continue watching items
    m.apiTask.request = { action: "getResumeItems", limit: 20 }
end sub

sub onResumeItemsLoaded(response as object)
    if response.success and response.items <> invalid
        m.continueWatchingItems = response.items
        print "[Home] Loaded " + str(response.items.count()) + " resume items"
    end if

    ' Fetch next up
    m.apiTask.request = { action: "getNextUp", limit: 20 }
end sub

sub onNextUpLoaded(response as object)
    ' Merge nextUp with continueWatching, dedup by series
    if response.success and response.items <> invalid
        print "[Home] Loaded " + str(response.items.count()) + " next up items"
        seenSeries = {}
        for each item in m.continueWatchingItems
            if item.SeriesId <> invalid
                seenSeries[item.SeriesId] = true
            end if
        end for
        for each item in response.items
            seriesId = ""
            if item.SeriesId <> invalid then seriesId = item.SeriesId
            if seriesId = "" or not seenSeries.DoesExist(seriesId)
                m.continueWatchingItems.push(item)
                if seriesId <> "" then seenSeries[seriesId] = true
            end if
        end for
    end if

    ' Start building the row content and fetch latest media per library
    m.rowContent = CreateObject("roSGNode", "ContentNode")
    m.pendingLatestRequests = m.libraries.count()

    ' Add continue watching row if there are items
    if m.continueWatchingItems.count() > 0
        addRow("Continue Watching", m.continueWatchingItems)
    end if

    ' Fetch latest media for each library
    if m.libraries.count() > 0
        lib = m.libraries[0]
        m.currentLibraryIndex = 0
        m.apiTask.request = {
            action: "getLatestMedia"
            parentId: lib.Id
            limit: 16
        }
    else
        showRows()
    end if
end sub

sub onLatestMediaLoaded(response as object)
    if response.success and response.items <> invalid and response.items.count() > 0
        ' Find the library name for this parentId
        libName = "Recently Added"
        for each lib in m.libraries
            if lib.Id = response.parentId
                libName = lib.Name
                exit for
            end if
        end for
        addRow(libName, response.items)
    end if

    ' Fetch next library's latest media
    m.currentLibraryIndex = m.currentLibraryIndex + 1
    if m.currentLibraryIndex < m.libraries.count()
        lib = m.libraries[m.currentLibraryIndex]
        m.apiTask.request = {
            action: "getLatestMedia"
            parentId: lib.Id
            limit: 16
        }
    else
        ' All data loaded
        showRows()
    end if
end sub

sub addRow(title as string, items as object)
    if m.rowContent = invalid then return

    row = m.rowContent.createChild("ContentNode")
    row.title = title

    for each item in items
        child = row.createChild("ContentNode")
        child.title = ""
        if item.Name <> invalid then child.title = item.Name

        ' Store full item data as description JSON for later use
        child.addFields({ itemId: "" })
        if item.Id <> invalid
            child.itemId = item.Id
        end if

        ' Set poster image URL
        itemId = ""
        if item.Id <> invalid then itemId = item.Id
        if itemId <> "" and item.ImageTags <> invalid and item.ImageTags.Primary <> invalid
            child.HDPosterUrl = ImageUrl.primary(itemId, 210)
        else if item.SeriesId <> invalid and item.SeriesId <> ""
            child.HDPosterUrl = ImageUrl.primary(item.SeriesId, 210)
        end if

        ' Add subtitle (series name, year, etc.)
        description = ""
        if item.SeriesName <> invalid and item.SeriesName <> ""
            description = item.SeriesName
        else if item.ProductionYear <> invalid
            description = str(item.ProductionYear).Trim()
        end if
        child.description = description

        ' Store item data for selection
        child.addFields({ itemJson: "" })
        child.itemJson = FormatJSON(item)
    end for
end sub

sub showRows()
    m.loadingLabel.visible = false

    if m.rowContent = invalid or m.rowContent.getChildCount() = 0
        m.emptyLabel.text = "No content found on this server."
        m.emptyLabel.visible = true
        return
    end if

    m.rowList.content = m.rowContent
    m.rowList.visible = true
    m.rowList.setFocus(true)
end sub

sub onRowItemSelected()
    selectedIndex = m.rowList.rowItemSelected
    if selectedIndex = invalid or selectedIndex.count() < 2 then return

    rowIndex = selectedIndex[0]
    itemIndex = selectedIndex[1]

    row = m.rowContent.getChild(rowIndex)
    if row = invalid then return
    item = row.getChild(itemIndex)
    if item = invalid then return

    ' Parse stored item JSON
    if item.itemJson <> invalid and item.itemJson <> ""
        itemData = ParseJSON(item.itemJson)
        if itemData <> invalid
            m.top.selectedItem = itemData
        end if
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if press
        if key = "options"
            ' Options button — show sign out / refresh
            showOptionsDialog()
            return true
        end if
    end if
    return false
end function

sub showOptionsDialog()
    dialog = createObject("roSGNode", "StandardMessageDialog")
    dialog.title = "Options"
    dialog.message = [""]
    dialog.buttons = ["Refresh", "Sign Out", "Cancel"]
    dialog.observeFieldScoped("buttonSelected", "onOptionsButton")
    m.top.getScene().dialog = dialog
end sub

sub onOptionsButton()
    dialog = m.top.getScene().dialog
    if dialog = invalid then return
    index = dialog.buttonSelected
    dialog.close = true

    if index = 0
        ' Refresh
        loadHomeData()
    else if index = 1
        ' Sign Out
        Registry.clearAuth()
        m.global.serverUrl = ""
        m.global.authToken = ""
        m.global.userId = ""
        m.top.signOut = true
    end if

    m.rowList.setFocus(true)
end sub
```

- [ ] **Step 3: Verify build**

```bash
npm run build
```

- [ ] **Step 4: Deploy and test on device**

```bash
npm run package && curl --user rokudev:1234 --digest -F "mysubmit=Install" -F "archive=@sashimi.zip" "http://192.168.86.30/plugin_install"
```

Expected: HomeScreen shows rows of media posters from Jellyfin. Continue Watching row at top, followed by per-library rows. D-pad navigates between items and rows.

- [ ] **Step 5: Commit**

```bash
git add components/screens/home/HomeScreen.xml components/screens/home/HomeScreen.bs
git commit -m "feat: full HomeScreen with continue watching and library rows"
```

---

## Chunk 3: Library Browsing Screen

### Task 6: LibraryScreen with Grid Browsing

**Files:**
- Create: `components/screens/library/LibraryScreen.xml`
- Create: `components/screens/library/LibraryScreen.bs`

- [ ] **Step 1: Create components/screens/library/LibraryScreen.xml**

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<component name="LibraryScreen" extends="Group">
    <interface>
        <field id="libraryData" type="assocarray" onChange="onLibraryDataChanged" />
        <field id="selectedItem" type="assocarray" alwaysNotify="true" />
    </interface>
    <children>
        <!-- Background -->
        <Rectangle width="1920" height="1080" color="#0e0e1a" />

        <!-- Header -->
        <Rectangle width="1920" height="80" color="#101420" opacity="0.9" />
        <Label
            id="headerTitle"
            text=""
            font="font:MediumBoldSystemFont"
            color="#FFFFFF"
            translation="[192, 20]"
        />

        <!-- Sort/Filter info -->
        <Label
            id="filterLabel"
            text="Sort: Name | Press * for options"
            font="font:SmallestSystemFont"
            color="#666666"
            horizAlign="right"
            width="1536"
            translation="[192, 30]"
        />

        <!-- Poster grid -->
        <PosterGrid
            id="posterGrid"
            translation="[192, 100]"
            basePosterSize="[210, 315]"
            itemSpacing="[30, 60]"
            numColumns="7"
            numRows="3"
            caption1NumLines="2"
            caption1Font="font:SmallestSystemFont"
            caption1Color="#CCCCCC"
            caption2Font="font:SmallestSystemFont"
            caption2Color="#888888"
        />

        <!-- Loading -->
        <Label
            id="loadingLabel"
            text="Loading..."
            font="font:MediumSystemFont"
            color="#CCCCCC"
            horizAlign="center"
            width="1920"
            translation="[0, 500]"
            visible="false"
        />

        <!-- Alphabet bar -->
        <LabelList
            id="alphaBar"
            translation="[1780, 100]"
            itemSize="[80, 32]"
            numRows="26"
            visible="false"
        />

        <!-- API Task -->
        <JellyfinApi id="apiTask" />
    </children>
</component>
```

- [ ] **Step 2: Create components/screens/library/LibraryScreen.bs**

```brightscript
import "pkg:/source/utils/ImageUrl.bs"

sub init()
    m.headerTitle = m.top.findNode("headerTitle")
    m.filterLabel = m.top.findNode("filterLabel")
    m.posterGrid = m.top.findNode("posterGrid")
    m.loadingLabel = m.top.findNode("loadingLabel")
    m.alphaBar = m.top.findNode("alphaBar")
    m.apiTask = m.top.findNode("apiTask")

    m.apiTask.observeFieldScoped("response", "onApiResponse")

    ' Grid state
    m.libraryId = ""
    m.libraryName = ""
    m.sortBy = "SortName"
    m.sortOrder = "Ascending"
    m.filterPlayed = invalid
    m.filterFavorite = invalid
    m.totalItems = 0
    m.loadedItems = 0
    m.isLoading = false

    ' Observe grid for pagination and selection
    m.posterGrid.observeFieldScoped("itemSelected", "onItemSelected")
    m.posterGrid.observeFieldScoped("itemFocused", "onItemFocused")

    ' Build alphabet bar content
    alphaContent = CreateObject("roSGNode", "ContentNode")
    for i = 65 to 90 ' A-Z
        letter = CreateObject("roSGNode", "ContentNode")
        letter.title = Chr(i)
        alphaContent.appendChild(letter)
    end for
    m.alphaBar.content = alphaContent
    m.alphaBar.observeFieldScoped("itemSelected", "onAlphaSelected")
end sub

sub onLibraryDataChanged()
    data = m.top.libraryData
    if data = invalid then return

    m.libraryId = data.id
    m.libraryName = data.name
    m.headerTitle.text = m.libraryName

    loadItems(0)
end sub

sub loadItems(startIndex as integer)
    m.isLoading = true
    if startIndex = 0
        m.loadingLabel.visible = true
        m.posterGrid.visible = false
    end if

    updateFilterLabel()

    m.apiTask.request = {
        action: "getItems"
        parentId: m.libraryId
        sortBy: m.sortBy
        sortOrder: m.sortOrder
        limit: 50
        startIndex: startIndex
        isPlayed: m.filterPlayed
        isFavorite: m.filterFavorite
    }
end sub

sub onApiResponse()
    response = m.apiTask.response
    if response = invalid then return

    if response.action = "getItems"
        onItemsLoaded(response)
    end if
end sub

sub onItemsLoaded(response as object)
    m.isLoading = false
    m.loadingLabel.visible = false

    if not response.success then return

    m.totalItems = response.totalRecordCount

    ' Build or append content
    if response.startIndex = 0
        m.gridContent = CreateObject("roSGNode", "ContentNode")
    end if

    for each item in response.items
        child = m.gridContent.createChild("ContentNode")

        ' Caption 1: title
        title = ""
        if item.Name <> invalid then title = item.Name
        child.shortDescriptionLine1 = title

        ' Caption 2: year or series
        subtitle = ""
        if item.ProductionYear <> invalid
            subtitle = str(item.ProductionYear).Trim()
        end if
        child.shortDescriptionLine2 = subtitle

        ' Poster image
        itemId = ""
        if item.Id <> invalid then itemId = item.Id
        if itemId <> "" and item.ImageTags <> invalid and item.ImageTags.Primary <> invalid
            child.HDPosterUrl = ImageUrl.primary(itemId, 210)
        end if

        ' Store item JSON for selection
        child.addFields({ itemJson: "" })
        child.itemJson = FormatJSON(item)
    end for

    m.loadedItems = m.gridContent.getChildCount()
    m.posterGrid.content = m.gridContent
    m.posterGrid.visible = true

    if response.startIndex = 0
        m.posterGrid.setFocus(true)
    end if
end sub

sub onItemFocused()
    ' Pagination: load more when approaching end
    focusIndex = m.posterGrid.itemFocused
    if focusIndex > m.loadedItems - 15 and m.loadedItems < m.totalItems and not m.isLoading
        print "[Library] Loading more items at " + str(m.loadedItems)
        loadItems(m.loadedItems)
    end if
end sub

sub onItemSelected()
    index = m.posterGrid.itemSelected
    if index < 0 then return

    child = m.gridContent.getChild(index)
    if child = invalid then return

    if child.itemJson <> invalid and child.itemJson <> ""
        itemData = ParseJSON(child.itemJson)
        if itemData <> invalid
            m.top.selectedItem = itemData
        end if
    end if
end sub

sub onAlphaSelected()
    index = m.alphaBar.itemSelected
    if index < 0 then return

    letter = Chr(65 + index) ' A=65
    m.apiTask.request = {
        action: "getItems"
        parentId: m.libraryId
        sortBy: "SortName"
        sortOrder: "Ascending"
        limit: 50
        startIndex: 0
        nameStartsWith: letter
    }
end sub

sub updateFilterLabel()
    sortLabel = "Name"
    if m.sortBy = "DateCreated" then sortLabel = "Date Added"
    else if m.sortBy = "CommunityRating" then sortLabel = "Rating"
    else if m.sortBy = "PlayCount" then sortLabel = "Play Count"

    filterLabel = ""
    if m.filterPlayed = true then filterLabel = " | Watched"
    else if m.filterPlayed = false then filterLabel = " | Unwatched"
    if m.filterFavorite = true then filterLabel += " | Favorites"

    m.filterLabel.text = "Sort: " + sortLabel + filterLabel + " | Press * for options"
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if press
        if key = "options"
            showSortFilterDialog()
            return true
        else if key = "right" and m.posterGrid.hasFocus()
            ' Show alphabet bar
            m.alphaBar.visible = true
            m.alphaBar.setFocus(true)
            return true
        else if key = "left" and m.alphaBar.hasFocus()
            m.alphaBar.visible = false
            m.posterGrid.setFocus(true)
            return true
        end if
    end if
    return false
end function

sub showSortFilterDialog()
    dialog = createObject("roSGNode", "StandardMessageDialog")
    dialog.title = "Sort & Filter"
    dialog.message = [""]
    dialog.buttons = [
        "Sort: Name",
        "Sort: Date Added",
        "Sort: Rating",
        "Filter: All",
        "Filter: Unwatched",
        "Filter: Favorites",
        "Cancel"
    ]
    dialog.observeFieldScoped("buttonSelected", "onSortFilterButton")
    m.top.getScene().dialog = dialog
end sub

sub onSortFilterButton()
    dialog = m.top.getScene().dialog
    if dialog = invalid then return
    index = dialog.buttonSelected
    dialog.close = true

    if index = 0
        m.sortBy = "SortName"
        m.sortOrder = "Ascending"
    else if index = 1
        m.sortBy = "DateCreated"
        m.sortOrder = "Descending"
    else if index = 2
        m.sortBy = "CommunityRating"
        m.sortOrder = "Descending"
    else if index = 3
        m.filterPlayed = invalid
        m.filterFavorite = invalid
    else if index = 4
        m.filterPlayed = false
        m.filterFavorite = invalid
    else if index = 5
        m.filterFavorite = true
        m.filterPlayed = invalid
    else
        m.posterGrid.setFocus(true)
        return
    end if

    if index < 6
        loadItems(0)
    end if

    m.posterGrid.setFocus(true)
end sub
```

- [ ] **Step 3: Verify build**

```bash
npm run build
```

- [ ] **Step 4: Commit**

```bash
git add components/screens/library/LibraryScreen.xml components/screens/library/LibraryScreen.bs
git commit -m "feat: add LibraryScreen with poster grid, sort/filter, pagination, and alphabet nav"
```

---

### Task 7: Wire Navigation Between Home and Library Screens

**Files:**
- Modify: `components/MainScene.bs`

- [ ] **Step 1: Update showScreen to wire LibraryScreen observers**

Add this case to the screen observer wiring in `showScreen()`:

```brightscript
    else if screenName = "LibraryScreen"
        screen.observeFieldScoped("selectedItem", "onItemSelected")
    end if
```

- [ ] **Step 2: Add HomeScreen library navigation**

Update the HomeScreen observer wiring to handle both `signOut` and `selectedLibrary`:

```brightscript
    else if screenName = "HomeScreen"
        screen.observeFieldScoped("signOut", "onSignOut")
        screen.observeFieldScoped("selectedItem", "onItemSelected")
    end if
```

- [ ] **Step 3: Add item selection handler**

For now, this is a placeholder — Phase 3 will add the MediaDetailScreen. For Phase 2, selecting an item just shows a toast with the item name:

```brightscript
sub onItemSelected()
    ' Find the screen that triggered this
    if m.currentScreen <> invalid
        item = m.currentScreen.selectedItem
        if item <> invalid and item.Name <> invalid
            ' TODO: Phase 3 will navigate to MediaDetailScreen
            print "[Nav] Item selected: " + item.Name
        end if
    end if
end sub
```

- [ ] **Step 4: Verify build**

```bash
npm run build
```

- [ ] **Step 5: Deploy and test on device**

```bash
npm run package && curl --user rokudev:1234 --digest -F "mysubmit=Install" -F "archive=@sashimi.zip" "http://192.168.86.30/plugin_install"
```

Expected: Home screen loads with rows of media. Options (*) button shows Refresh/Sign Out. Navigation works between rows and items.

- [ ] **Step 6: Commit**

```bash
git add components/MainScene.bs
git commit -m "feat: wire HomeScreen and LibraryScreen navigation in MainScene"
```

---

## Phase 2 Deliverable

At the end of Phase 2, the Sashimi Roku channel:

1. Shows a proper HomeScreen with header bar (app name + username)
2. Displays Continue Watching row (merged resume + next up, deduplicated by series)
3. Shows per-library Recently Added rows with poster images
4. Poster images load from Jellyfin with proper fallbacks (item → series)
5. Progress bars on resume items
6. RowList navigation with D-pad (left/right between items, up/down between rows)
7. Options (*) button for Refresh and Sign Out
8. LibraryScreen with PosterGrid for browsing a library's items
9. Sort options (Name, Date Added, Rating) via Options dialog
10. Filter options (All, Unwatched, Favorites) via Options dialog
11. Infinite scroll pagination (loads more items as user scrolls)
12. Alphabet fast-scroll bar (press Right from grid to show A-Z)
13. Item selection fires events (ready for Phase 3 MediaDetailScreen)

**Next:** Phase 3 will add MediaDetailScreen, cast/crew, trailers, watched/favorite actions, and SearchScreen.
