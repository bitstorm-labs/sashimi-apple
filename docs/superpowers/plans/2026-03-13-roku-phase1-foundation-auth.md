# Sashimi Roku — Phase 1: Foundation & Auth Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a new `sashimi-roku` repository with project scaffolding, build toolchain, utility modules, navigation stack, authentication flow (manual URL entry + SSDP discovery + login), session persistence, and toast overlay — resulting in a deployable Roku channel that can connect to a Jellyfin server and show a placeholder home screen.

**Architecture:** BrighterScript/SceneGraph app with Task nodes for all networking, Registry for persistence, array-based navigation stack in MainScene, and observer-based data flow between screens and tasks.

**Tech Stack:** BrighterScript, Roku SceneGraph XML, Node.js build pipeline (bsc + roku-deploy), Rooibos for testing.

**Minimum Roku OS:** 11.0+ (required for `cornerRadius` on Rectangle, `playbackSpeed` on Video node, and other modern SceneGraph features).

**Spec:** See `docs/superpowers/specs/2026-03-13-roku-port-design.md`

---

## File Structure

### Files to Create

```
sashimi-roku/
  manifest                              # Roku channel metadata
  package.json                          # npm build/deploy scripts
  bsconfig.json                         # BrighterScript compiler config
  .gitignore                            # Node modules, build output, Roku zips
  .vscode/launch.json                   # Roku debug config

  source/
    Main.bs                             # Entry point — creates roSGScreen, message loop
    utils/
      Registry.bs                       # Registry wrapper — read/write/delete with section management
      Http.bs                           # roUrlTransfer helpers — GET/POST with headers, JSON, error handling

  components/
    MainScene.xml                       # Root Scene XML — declares interface fields
    MainScene.bs                        # Root Scene logic — nav stack, auth check, deep link capture
    widgets/
      LoadingSpinner.xml                # Certification-required spinner component
      LoadingSpinner.bs                 # Spinner animation logic
      ErrorDialog.xml                   # User-friendly error dialog component
      ErrorDialog.bs                    # Error dialog logic
      ToastOverlay.xml                  # Transient toast notification component
      ToastOverlay.bs                   # Toast auto-dismiss logic
    screens/
      auth/
        ServerConnectionScreen.xml      # Auth screen layout — URL field, username, password, buttons
        ServerConnectionScreen.bs       # Auth screen logic — validation, login, discovery toggle
      home/
        HomeScreen.xml                  # Placeholder home screen layout
        HomeScreen.bs                   # Placeholder home screen logic (just shows "Welcome" + sign out)
    tasks/
      JellyfinApi.xml                   # API task XML — declares request/response interface fields
      JellyfinApi.bs                    # API task logic — routes actions to handler functions
      ServerDiscoveryTask.xml           # SSDP discovery task XML
      ServerDiscoveryTask.bs            # SSDP discovery task logic

  images/
    splash_screen_fhd.png              # 1920x1080 splash (Sashimi branding)
    splash_screen_hd.png               # 1280x720 splash
    mm_icon_focus_hd.png               # 336x210 channel icon
    mm_icon_focus_sd.png               # 108x69 SD channel icon

  locale/
    en_US/translations.tr              # Localization strings (Roku XML format, placeholder for now)
```

---

## Chunk 1: Project Scaffolding & Build Pipeline

### Task 1: Create Repository and Project Structure

**Files:**
- Create: `sashimi-roku/manifest`
- Create: `sashimi-roku/package.json`
- Create: `sashimi-roku/bsconfig.json`
- Create: `sashimi-roku/.gitignore`
- Create: `sashimi-roku/.vscode/launch.json`

- [ ] **Step 1: Create the GitHub repository**

```bash
cd /Users/mondo/Documents/git
gh repo create mondominator/sashimi-roku --private --description "Sashimi - Jellyfin client for Roku" --clone
cd sashimi-roku
```

- [ ] **Step 2: Create the manifest file**

Create `manifest` in the repo root. This is required by Roku and defines the channel metadata.

```ini
title=Sashimi
subtitle=Jellyfin Client for Roku
major_version=0
minor_version=1
build_version=0
mm_icon_focus_hd=pkg:/images/mm_icon_focus_hd.png
mm_icon_focus_sd=pkg:/images/mm_icon_focus_sd.png
splash_screen_fhd=pkg:/images/splash_screen_fhd.png
splash_screen_hd=pkg:/images/splash_screen_hd.png
splash_color=#1a1a2e
ui_resolutions=fhd
confirm_partner_button=1
bs_const=DEBUG=true
```

- [ ] **Step 3: Create package.json with build scripts**

```json
{
  "name": "sashimi-roku",
  "version": "0.1.0",
  "description": "Sashimi - Jellyfin client for Roku",
  "scripts": {
    "build": "bsc",
    "package": "bsc && cd out && zip -r ../sashimi.zip . && cd ..",
    "deploy": "roku-deploy --host $ROKU_DEV_TARGET --password $ROKU_DEV_PASSWORD",
    "dev": "npm run package && npm run deploy",
    "lint": "bsc --lint-only",
    "test": "echo 'Rooibos tests - run via device sideload'"
  },
  "devDependencies": {
    "brighterscript": "^0.67.0",
    "roku-deploy": "^3.12.0"
  }
}
```

- [ ] **Step 4: Create bsconfig.json**

```json
{
  "rootDir": ".",
  "stagingDir": "out",
  "files": [
    "manifest",
    "source/**/*",
    "components/**/*",
    "images/**/*",
    "locale/**/*"
  ],
  "autoImportComponentScript": true,
  "sourceMap": true,
  "diagnosticFilters": [
    { "src": "tests/**/*" }
  ]
}
```

- [ ] **Step 5: Create .gitignore**

```
node_modules/
out/
*.zip
.roku-deploy-staging/
.env
```

- [ ] **Step 6: Create .vscode/launch.json**

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "brightscript",
      "request": "launch",
      "name": "Sashimi (Roku)",
      "rootDir": "${workspaceFolder}",
      "host": "${env:ROKU_DEV_TARGET}",
      "password": "${env:ROKU_DEV_PASSWORD}",
      "stopOnEntry": false
    }
  ]
}
```

- [ ] **Step 7: Create placeholder image files**

Create the `images/` directory. Generate placeholder images using ImageMagick (matching Sashimi branding colors):

```bash
mkdir -p images

# Splash screen FHD (1920x1080)
magick -size 1920x1080 xc:'#1a1a2e' -gravity center \
  -fill white -pointsize 120 -annotate +0-50 'Sashimi' \
  -fill '#888888' -pointsize 40 -annotate +0+60 'Jellyfin Client' \
  images/splash_screen_fhd.png

# Splash screen HD (1280x720)
magick -size 1280x720 xc:'#1a1a2e' -gravity center \
  -fill white -pointsize 80 -annotate +0-30 'Sashimi' \
  -fill '#888888' -pointsize 28 -annotate +0+40 'Jellyfin Client' \
  images/splash_screen_hd.png

# Channel icon HD (336x210)
magick -size 336x210 xc:'#1a1a2e' -gravity center \
  -fill white -pointsize 36 -annotate +0+0 'Sashimi' \
  images/mm_icon_focus_hd.png

# Channel icon SD (108x69)
magick -size 108x69 xc:'#1a1a2e' -gravity center \
  -fill white -pointsize 12 -annotate +0+0 'Sashimi' \
  images/mm_icon_focus_sd.png
```

- [ ] **Step 8: Create locale placeholder**

```bash
mkdir -p locale/en_US
```

Create `locale/en_US/translations.tr`:

```xml
<?xml version="1.0" encoding="utf-8" ?>
<TS>
    <context>
        <name>default</name>
        <message>
            <source>Sashimi</source>
            <translation>Sashimi</translation>
        </message>
    </context>
</TS>
```

- [ ] **Step 9: Install dependencies and verify build**

```bash
npm install
npm run build
```

Expected: BrighterScript compiles with no errors (no source files yet, so it should just create the staging dir).

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: initial project scaffolding with manifest, build pipeline, and placeholder images"
```

---

### Task 2: Create Entry Point and Main Scene Shell

**Files:**
- Create: `source/Main.bs`
- Create: `components/MainScene.xml`
- Create: `components/MainScene.bs`

- [ ] **Step 1: Create source/Main.bs**

This is the required Roku entry point. It creates the SceneGraph screen and enters the message loop.

```brightscript
' source/Main.bs
sub main(args as dynamic)
    screen = CreateObject("roSGScreen")
    m.port = CreateObject("roMessagePort")
    screen.setMessagePort(m.port)

    scene = screen.createScene("MainScene")

    ' Pass launch args for deep linking
    if args <> invalid
        scene.launchArgs = args
    end if

    screen.show()

    ' Signal that the app has launched (certification requirement)
    scene.signalBeacon("AppLaunchComplete")

    ' Main message loop
    while true
        msg = wait(0, m.port)
        msgType = type(msg)

        if msgType = "roSGScreenEvent"
            if msg.isScreenClosed()
                return
            end if
        end if
    end while
end sub
```

- [ ] **Step 2: Create components/MainScene.xml**

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<component name="MainScene" extends="Scene">
    <interface>
        <field id="launchArgs" type="assocarray" />
    </interface>
    <script type="text/brightscript" uri="MainScene.bs" />
    <children>
        <!-- Screens are added/removed dynamically by the nav stack -->
    </children>
</component>
```

- [ ] **Step 3: Create components/MainScene.bs**

```brightscript
' components/MainScene.bs
sub init()
    m.navStack = []
    m.currentScreen = invalid

    ' Set up global state
    m.global.addFields({
        serverUrl: ""
        authToken: ""
        userId: ""
        deviceId: ""
    })

    ' Initialize device ID (generate once, persist in registry)
    initDeviceId()

    ' Check for saved session
    if hasSavedSession()
        showScreen("HomeScreen")
    else
        showScreen("ServerConnectionScreen")
    end if
end sub

sub initDeviceId()
    sec = CreateObject("roRegistrySection", "device")
    deviceId = sec.Read("deviceId")
    if deviceId = ""
        deviceId = CreateObject("roDeviceInfo").GetChannelClientId()
        sec.Write("deviceId", deviceId)
        sec.Flush()
    end if
    m.global.deviceId = deviceId
end sub

function hasSavedSession() as boolean
    sec = CreateObject("roRegistrySection", "auth")
    serverUrl = sec.Read("serverUrl")
    authToken = sec.Read("authToken")
    userId = sec.Read("userId")
    return serverUrl <> "" and authToken <> "" and userId <> ""
end function

sub showScreen(screenName as string)
    screen = createObject("roSGNode", screenName)
    if screen = invalid
        print "ERROR: Could not create screen: " + screenName
        return
    end if

    ' Hide current screen
    if m.currentScreen <> invalid
        m.currentScreen.visible = false
    end if

    ' Add and show new screen
    m.top.appendChild(screen)
    m.navStack.push(screen)
    m.currentScreen = screen
    screen.setFocus(true)
end sub

sub popScreen()
    if m.navStack.count() <= 1
        ' At root screen — let back exit the channel
        return
    end if

    ' Remove current screen
    currentScreen = m.navStack.pop()
    m.top.removeChild(currentScreen)

    ' Show previous screen
    m.currentScreen = m.navStack.peek()
    m.currentScreen.visible = true
    m.currentScreen.setFocus(true)
end sub

sub navigateToHome()
    ' Clear the nav stack and show home
    while m.navStack.count() > 0
        screen = m.navStack.pop()
        m.top.removeChild(screen)
    end while
    m.currentScreen = invalid
    showScreen("HomeScreen")
end sub

sub navigateToAuth()
    while m.navStack.count() > 0
        screen = m.navStack.pop()
        m.top.removeChild(screen)
    end while
    m.currentScreen = invalid
    showScreen("ServerConnectionScreen")
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if press and key = "back"
        if m.navStack.count() > 1
            popScreen()
            return true
        end if
        ' At root — return false to let Roku OS handle exit
    end if
    return false
end function
```

- [ ] **Step 4: Verify the build compiles**

```bash
npm run build
```

Expected: Compiles with no errors. Output in `out/` directory.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add entry point (Main.bs) and MainScene with navigation stack"
```

---

### Task 3: Registry Utility Module

**Files:**
- Create: `source/utils/Registry.bs`
- Create: `tests/source/utils/RegistryTests.bs`

- [ ] **Step 1: Create source/utils/Registry.bs**

Wrapper around roRegistrySection that handles sections, JSON serialization, and flush calls.

```brightscript
' source/utils/Registry.bs
namespace Registry

    function read(section as string, key as string) as string
        sec = CreateObject("roRegistrySection", section)
        if sec = invalid then return ""
        return sec.Read(key)
    end function

    sub write(section as string, key as string, value as string)
        sec = CreateObject("roRegistrySection", section)
        if sec = invalid then return
        sec.Write(key, value)
        sec.Flush()
    end sub

    sub delete(section as string, key as string)
        sec = CreateObject("roRegistrySection", section)
        if sec = invalid then return
        sec.Delete(key)
        sec.Flush()
    end sub

    sub deleteSection(section as string)
        sec = CreateObject("roRegistrySection", section)
        if sec = invalid then return
        keys = sec.GetKeyList()
        for each key in keys
            sec.Delete(key)
        end for
        sec.Flush()
    end sub

    function readJson(section as string, key as string) as dynamic
        raw = read(section, key)
        if raw = "" then return invalid
        return ParseJSON(raw)
    end function

    sub writeJson(section as string, key as string, value as dynamic)
        raw = FormatJSON(value)
        write(section, key, raw)
    end sub

    ' Auth-specific helpers

    function getAuthToken() as string
        return read("auth", "authToken")
    end function

    function getServerUrl() as string
        return read("auth", "serverUrl")
    end function

    function getUserId() as string
        return read("auth", "userId")
    end function

    function getUserName() as string
        return read("auth", "userName")
    end function

    sub saveAuth(serverUrl as string, authToken as string, userId as string, userName as string)
        sec = CreateObject("roRegistrySection", "auth")
        if sec = invalid then return
        sec.Write("serverUrl", serverUrl)
        sec.Write("authToken", authToken)
        sec.Write("userId", userId)
        sec.Write("userName", userName)
        sec.Flush()
    end sub

    sub clearAuth()
        deleteSection("auth")
    end sub

    function hasAuth() as boolean
        return getServerUrl() <> "" and getAuthToken() <> "" and getUserId() <> ""
    end function

end namespace
```

- [ ] **Step 2: Verify build compiles**

```bash
npm run build
```

Expected: Compiles with no errors.

- [ ] **Step 3: Commit**

```bash
git add source/utils/Registry.bs
git commit -m "feat: add Registry utility module for persistent key-value storage"
```

---

### Task 4: HTTP Utility Module

**Files:**
- Create: `source/utils/Http.bs`

- [ ] **Step 1: Create source/utils/Http.bs**

Helper functions for building roUrlTransfer requests with Jellyfin auth headers. These are called from within Task nodes only.

```brightscript
' source/utils/Http.bs
namespace Http

    ' Build the MediaBrowser authorization header value
    function authHeader() as string
        parts = []
        parts.push("MediaBrowser Client=""Sashimi""")
        parts.push("Device=""Sashimi Roku""")
        parts.push("DeviceId=""" + m.global.deviceId + """")
        parts.push("Version=""0.1.0""")
        token = m.global.authToken
        if token <> "" and token <> invalid
            parts.push("Token=""" + token + """")
        end if

        result = ""
        for i = 0 to parts.count() - 1
            if i > 0 then result += ", "
            result += parts[i]
        end for
        return result
    end function

    ' Perform a GET request and return parsed JSON (or invalid on error)
    ' Must be called from a Task node thread.
    function getJson(url as string) as dynamic
        request = CreateObject("roUrlTransfer")
        port = CreateObject("roMessagePort")
        request.SetMessagePort(port)
        request.SetCertificatesFile("common:/certs/ca-bundle.crt")
        request.InitClientCertificates()
        request.EnableHostVerification(false)
        request.EnablePeerVerification(false)
        request.SetUrl(url)
        request.AddHeader("Authorization", authHeader())
        request.AddHeader("Accept", "application/json")
        request.RetainBodyOnError(true)

        if request.AsyncGetToString()
            msg = wait(30000, port)
            if msg <> invalid and type(msg) = "roUrlEvent"
                code = msg.GetResponseCode()
                if code >= 200 and code < 300
                    return ParseJSON(msg.GetString())
                else
                    print "HTTP GET error: " + str(code) + " for " + url
                    return invalid
                end if
            else
                print "HTTP GET timeout for " + url
                return invalid
            end if
        end if
        return invalid
    end function

    ' Perform a POST request with JSON body and return parsed JSON (or invalid on error)
    ' Must be called from a Task node thread.
    function postJson(url as string, body as dynamic) as dynamic
        request = CreateObject("roUrlTransfer")
        port = CreateObject("roMessagePort")
        request.SetMessagePort(port)
        request.SetCertificatesFile("common:/certs/ca-bundle.crt")
        request.InitClientCertificates()
        request.EnableHostVerification(false)
        request.EnablePeerVerification(false)
        request.SetUrl(url)
        request.AddHeader("Authorization", authHeader())
        request.AddHeader("Content-Type", "application/json")
        request.AddHeader("Accept", "application/json")
        request.RetainBodyOnError(true)

        bodyStr = ""
        if body <> invalid
            bodyStr = FormatJSON(body)
        end if

        if request.AsyncPostFromString(bodyStr)
            msg = wait(30000, port)
            if msg <> invalid and type(msg) = "roUrlEvent"
                code = msg.GetResponseCode()
                if code >= 200 and code < 300
                    responseStr = msg.GetString()
                    if responseStr <> "" and responseStr <> invalid
                        return ParseJSON(responseStr)
                    end if
                    return { _statusCode: code }
                else
                    print "HTTP POST error: " + str(code) + " for " + url
                    return invalid
                end if
            else
                print "HTTP POST timeout for " + url
                return invalid
            end if
        end if
        return invalid
    end function

    ' Perform a DELETE request and return the status code (or -1 on error)
    ' Must be called from a Task node thread.
    function deleteRequest(url as string) as integer
        request = CreateObject("roUrlTransfer")
        port = CreateObject("roMessagePort")
        request.SetMessagePort(port)
        request.SetCertificatesFile("common:/certs/ca-bundle.crt")
        request.InitClientCertificates()
        request.EnableHostVerification(false)
        request.EnablePeerVerification(false)
        request.SetUrl(url)
        request.AddHeader("Authorization", authHeader())
        request.SetRequest("DELETE")
        request.RetainBodyOnError(true)

        if request.AsyncPostFromString("")
            msg = wait(30000, port)
            if msg <> invalid and type(msg) = "roUrlEvent"
                return msg.GetResponseCode()
            end if
        end if
        return -1
    end function

    ' Build a full API URL from a path
    function apiUrl(path as string) as string
        serverUrl = m.global.serverUrl
        ' Ensure no double slash
        if Right(serverUrl, 1) = "/"
            serverUrl = Left(serverUrl, Len(serverUrl) - 1)
        end if
        if Left(path, 1) <> "/"
            path = "/" + path
        end if
        return serverUrl + path
    end function

end namespace
```

- [ ] **Step 2: Verify build compiles**

```bash
npm run build
```

Expected: Compiles with no errors.

- [ ] **Step 3: Commit**

```bash
git add source/utils/Http.bs
git commit -m "feat: add HTTP utility module with GET/POST/DELETE and Jellyfin auth headers"
```

---

## Chunk 2: Core Widgets & JellyfinApi Task

### Task 5: Loading Spinner Widget

**Files:**
- Create: `components/widgets/LoadingSpinner.xml`
- Create: `components/widgets/LoadingSpinner.bs`

- [ ] **Step 1: Create components/widgets/LoadingSpinner.xml**

Certification requires a visible loading indicator during all network operations.

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<component name="LoadingSpinner" extends="Group">
    <interface>
        <field id="message" type="string" value="Loading..." />
    </interface>
    <script type="text/brightscript" uri="LoadingSpinner.bs" />
    <children>
        <LayoutGroup
            id="spinnerGroup"
            layoutDirection="vert"
            horizAlignment="center"
            vertAlignment="center"
            itemSpacings="[20]"
            translation="[960, 540]"
        >
            <BusySpinner
                id="spinner"
                poster="pkg:/images/spinner.png"
                visible="true"
            />
            <Label
                id="messageLabel"
                text="Loading..."
                font="font:MediumSystemFont"
                color="#CCCCCC"
                horizAlign="center"
            />
        </LayoutGroup>
    </children>
</component>
```

Note: Roku's BusySpinner requires a poster image. We'll create a simple one.

- [ ] **Step 2: Create the spinner image**

```bash
# Create a 100x100 spinner ring image
magick -size 100x100 xc:none \
  -stroke '#FFFFFF' -strokewidth 4 -fill none \
  -draw "arc 10,10 90,90 0,270" \
  images/spinner.png
```

- [ ] **Step 3: Create components/widgets/LoadingSpinner.bs**

```brightscript
' components/widgets/LoadingSpinner.bs
sub init()
    m.messageLabel = m.top.findNode("messageLabel")
    m.top.observeField("message", "onMessageChanged")
end sub

sub onMessageChanged()
    m.messageLabel.text = m.top.message
end sub
```

- [ ] **Step 4: Verify build compiles**

```bash
npm run build
```

- [ ] **Step 5: Commit**

```bash
git add components/widgets/LoadingSpinner.xml components/widgets/LoadingSpinner.bs images/spinner.png
git commit -m "feat: add LoadingSpinner widget for certification compliance"
```

---

### Task 6: Error Dialog Widget

**Files:**
- Create: `components/widgets/ErrorDialog.xml`
- Create: `components/widgets/ErrorDialog.bs`

- [ ] **Step 1: Create components/widgets/ErrorDialog.xml**

Uses Roku's built-in StandardMessageDialog for certification-compliant error display.

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<component name="ErrorDialog" extends="Group">
    <interface>
        <field id="showError" type="assocarray" alwaysNotify="true" />
        <!-- showError expects: { title: "string", message: "string" } -->
    </interface>
    <script type="text/brightscript" uri="ErrorDialog.bs" />
</component>
```

- [ ] **Step 2: Create components/widgets/ErrorDialog.bs**

```brightscript
' components/widgets/ErrorDialog.bs
sub init()
    m.top.observeField("showError", "onShowError")
end sub

sub onShowError()
    errorInfo = m.top.showError
    if errorInfo = invalid then return

    dialog = createObject("roSGNode", "StandardMessageDialog")
    dialog.title = errorInfo.title
    dialog.message = [errorInfo.message]
    dialog.buttons = ["OK"]
    dialog.observeFieldScoped("buttonSelected", "onDialogButton")

    m.top.getScene().dialog = dialog
end sub

sub onDialogButton()
    m.top.getScene().dialog.close = true
end sub
```

- [ ] **Step 3: Verify build compiles**

```bash
npm run build
```

- [ ] **Step 4: Commit**

```bash
git add components/widgets/ErrorDialog.xml components/widgets/ErrorDialog.bs
git commit -m "feat: add ErrorDialog widget for user-friendly error display"
```

---

### Task 7: Toast Overlay Widget

**Files:**
- Create: `components/widgets/ToastOverlay.xml`
- Create: `components/widgets/ToastOverlay.bs`

- [ ] **Step 1: Create components/widgets/ToastOverlay.xml**

A transient notification that appears briefly and auto-dismisses.

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<component name="ToastOverlay" extends="Group">
    <interface>
        <field id="showToast" type="assocarray" alwaysNotify="true" />
        <!-- showToast expects: { message: "string", duration: float (seconds, default 3) } -->
    </interface>
    <script type="text/brightscript" uri="ToastOverlay.bs" />
    <children>
        <Rectangle
            id="toastBg"
            visible="false"
            color="#333333"
            opacity="0.9"
            width="600"
            height="80"
            translation="[660, 50]"
            cornerRadius="12"
        >
            <Label
                id="toastLabel"
                text=""
                font="font:SmallSystemFont"
                color="#FFFFFF"
                width="560"
                height="80"
                horizAlign="center"
                vertAlign="center"
                translation="[20, 0]"
            />
        </Rectangle>
        <Timer id="dismissTimer" repeat="false" duration="3" />
    </children>
</component>
```

- [ ] **Step 2: Create components/widgets/ToastOverlay.bs**

```brightscript
' components/widgets/ToastOverlay.bs
sub init()
    m.toastBg = m.top.findNode("toastBg")
    m.toastLabel = m.top.findNode("toastLabel")
    m.dismissTimer = m.top.findNode("dismissTimer")

    m.top.observeField("showToast", "onShowToast")
    m.dismissTimer.observeField("fire", "onDismiss")
end sub

sub onShowToast()
    toastInfo = m.top.showToast
    if toastInfo = invalid then return

    m.toastLabel.text = toastInfo.message

    duration = 3
    if toastInfo.duration <> invalid
        duration = toastInfo.duration
    end if

    m.dismissTimer.duration = duration
    m.dismissTimer.control = "stop"
    m.toastBg.visible = true
    m.dismissTimer.control = "start"
end sub

sub onDismiss()
    m.toastBg.visible = false
end sub
```

- [ ] **Step 3: Verify build compiles**

```bash
npm run build
```

- [ ] **Step 4: Commit**

```bash
git add components/widgets/ToastOverlay.xml components/widgets/ToastOverlay.bs
git commit -m "feat: add ToastOverlay widget for transient feedback messages"
```

---

### Task 8: JellyfinApi Task Node

**Files:**
- Create: `components/tasks/JellyfinApi.xml`
- Create: `components/tasks/JellyfinApi.bs`

- [ ] **Step 1: Create components/tasks/JellyfinApi.xml**

The central API task that handles all Jellyfin REST calls on a background thread.

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<component name="JellyfinApi" extends="Task">
    <interface>
        <!-- Input: set this to trigger an API call -->
        <field id="request" type="assocarray" alwaysNotify="true" />
        <!-- Output: result of the API call -->
        <field id="response" type="assocarray" alwaysNotify="true" />
    </interface>
    <script type="text/brightscript" uri="JellyfinApi.bs" />
</component>
```

- [ ] **Step 2: Create components/tasks/JellyfinApi.bs**

For Phase 1, we implement: `authenticate`, `validateSession` (getLibraryViews), and `getPublicInfo` (to validate server URL before login).

```brightscript
' components/tasks/JellyfinApi.bs
sub init()
    m.top.functionName = "taskLoop"
end sub

sub taskLoop()
    ' Keep the task alive to handle multiple requests
    port = CreateObject("roMessagePort")
    m.top.observeFieldScoped("request", port)

    while true
        msg = wait(0, port)
        if msg <> invalid
            processRequest()
        end if
    end while
end sub

sub processRequest()
    request = m.top.request
    if request = invalid then return

    action = request.action
    if action = invalid or action = ""
        m.top.response = { success: false, error: "No action specified", action: "" }
        return
    end if

    if action = "authenticate"
        doAuthenticate(request)
    else if action = "validateSession"
        doValidateSession()
    else if action = "getPublicInfo"
        doGetPublicInfo(request)
    else
        m.top.response = { success: false, error: "Unknown action: " + action, action: action }
    end if
end sub

sub doAuthenticate(request as object)
    serverUrl = request.serverUrl
    username = request.username
    password = request.password

    ' Temporarily set serverUrl for this request
    m.global.serverUrl = serverUrl

    url = Http.apiUrl("/Users/AuthenticateByName")
    body = { Username: username, Pw: password }
    result = Http.postJson(url, body)

    if result <> invalid and result.AccessToken <> invalid
        m.top.response = {
            success: true
            action: "authenticate"
            accessToken: result.AccessToken
            userId: result.User.Id
            userName: result.User.Name
            serverUrl: serverUrl
        }
    else
        m.top.response = {
            success: false
            action: "authenticate"
            error: "Authentication failed. Check your username and password."
        }
    end if
end sub

sub doValidateSession()
    url = Http.apiUrl("/Users/" + m.global.userId + "/Views")
    result = Http.getJson(url)

    if result <> invalid and result.Items <> invalid
        m.top.response = {
            success: true
            action: "validateSession"
        }
    else
        m.top.response = {
            success: false
            action: "validateSession"
            error: "Session is no longer valid."
        }
    end if
end sub

sub doGetPublicInfo(request as object)
    serverUrl = request.serverUrl

    ' Build URL manually since global serverUrl may not be set yet
    url = serverUrl
    if Right(url, 1) = "/" then url = Left(url, Len(url) - 1)
    url = url + "/System/Info/Public"

    ' Use a raw request since we don't have auth yet
    transfer = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    transfer.SetMessagePort(port)
    transfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    transfer.InitClientCertificates()
    transfer.EnableHostVerification(false)
    transfer.EnablePeerVerification(false)
    transfer.SetUrl(url)
    transfer.AddHeader("Accept", "application/json")
    transfer.RetainBodyOnError(true)

    if transfer.AsyncGetToString()
        msg = wait(10000, port)
        if msg <> invalid and type(msg) = "roUrlEvent"
            code = msg.GetResponseCode()
            if code >= 200 and code < 300
                info = ParseJSON(msg.GetString())
                if info <> invalid and info.ServerName <> invalid
                    m.top.response = {
                        success: true
                        action: "getPublicInfo"
                        serverName: info.ServerName
                        version: info.Version
                        serverUrl: serverUrl
                    }
                    return
                end if
            end if
        end if
    end if

    m.top.response = {
        success: false
        action: "getPublicInfo"
        error: "Could not connect to server. Check the URL and try again."
    }
end sub
```

- [ ] **Step 3: Verify build compiles**

```bash
npm run build
```

- [ ] **Step 4: Commit**

```bash
git add components/tasks/JellyfinApi.xml components/tasks/JellyfinApi.bs
git commit -m "feat: add JellyfinApi Task node with authenticate, validateSession, and getPublicInfo"
```

---

## Chunk 3: Authentication Screens

### Task 9: SSDP Server Discovery Task

**Files:**
- Create: `components/tasks/ServerDiscoveryTask.xml`
- Create: `components/tasks/ServerDiscoveryTask.bs`

- [ ] **Step 1: Create components/tasks/ServerDiscoveryTask.xml**

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<component name="ServerDiscoveryTask" extends="Task">
    <interface>
        <field id="startDiscovery" type="boolean" alwaysNotify="true" />
        <field id="servers" type="array" />
        <!-- servers is an array of: { serverUrl: "string", serverName: "string" } -->
    </interface>
    <script type="text/brightscript" uri="ServerDiscoveryTask.bs" />
</component>
```

- [ ] **Step 2: Create components/tasks/ServerDiscoveryTask.bs**

Jellyfin servers respond to SSDP M-SEARCH requests. We broadcast and collect responses.

```brightscript
' components/tasks/ServerDiscoveryTask.bs
sub init()
    m.top.functionName = "discover"
end sub

sub discover()
    servers = []
    seenUrls = {}

    ' Jellyfin-specific discovery via UDP broadcast
    ' Jellyfin listens on port 7359 for "Who is JellyfinServer?" messages
    socket = CreateObject("roDatagramSocket")
    port = CreateObject("roMessagePort")
    socket.SetMessagePort(port)
    socket.SetBroadcast(true)
    socket.SetSendToAddress("255.255.255.255")
    socket.SetSendToPort(7359)

    ' Send discovery message
    byteArray = CreateObject("roByteArray")
    byteArray.FromAsciiString("Who is JellyfinServer?")
    socket.Send(byteArray)

    ' Wait for responses (up to 3 seconds)
    timeout = 3000
    timer = CreateObject("roTimespan")
    timer.Mark()

    while true
        remaining = timeout - timer.TotalMilliseconds()
        if remaining <= 0 then exit while

        msg = wait(remaining, port)
        if msg = invalid then exit while

        if type(msg) = "roDatagramEvent"
            response = msg.GetString()
            parsed = ParseJSON(response)
            if parsed <> invalid and parsed.Address <> invalid
                serverUrl = parsed.Address
                serverName = "Jellyfin Server"
                if parsed.Name <> invalid then serverName = parsed.Name

                ' Deduplicate by URL
                if not seenUrls.DoesExist(serverUrl)
                    seenUrls[serverUrl] = true
                    servers.push({
                        serverUrl: serverUrl
                        serverName: serverName
                    })
                end if
            end if
        end if
    end while

    socket.Close()
    m.top.servers = servers
end sub
```

- [ ] **Step 3: Verify build compiles**

```bash
npm run build
```

- [ ] **Step 4: Commit**

```bash
git add components/tasks/ServerDiscoveryTask.xml components/tasks/ServerDiscoveryTask.bs
git commit -m "feat: add SSDP server discovery task for finding Jellyfin servers on LAN"
```

---

### Task 10: Server Connection Screen

**Files:**
- Create: `components/screens/auth/ServerConnectionScreen.xml`
- Create: `components/screens/auth/ServerConnectionScreen.bs`

- [ ] **Step 1: Create components/screens/auth/ServerConnectionScreen.xml**

The login screen with server URL, username, password fields and a discovered servers list.

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<component name="ServerConnectionScreen" extends="Group">
    <interface>
        <field id="loginSuccess" type="boolean" value="false" alwaysNotify="true" />
    </interface>
    <script type="text/brightscript" uri="ServerConnectionScreen.bs" />
    <children>
        <!-- Background -->
        <Rectangle width="1920" height="1080" color="#1a1a2e" />

        <!-- Title -->
        <LayoutGroup
            id="titleGroup"
            layoutDirection="vert"
            horizAlignment="center"
            translation="[960, 80]"
            itemSpacings="[8]"
        >
            <Label
                id="titleLabel"
                text="Sashimi"
                font="font:LargeSystemFont"
                color="#FFFFFF"
                horizAlign="center"
            />
            <Label
                id="subtitleLabel"
                text="Jellyfin Client"
                font="font:SmallSystemFont"
                color="#888888"
                horizAlign="center"
            />
        </LayoutGroup>

        <!-- Login Form -->
        <LayoutGroup
            id="formGroup"
            layoutDirection="vert"
            horizAlignment="center"
            translation="[560, 250]"
            itemSpacings="[20]"
        >
            <!-- Server URL -->
            <Label text="Server Address" font="font:SmallSystemFont" color="#AAAAAA" />
            <TextEditBox
                id="serverUrlField"
                width="800"
                hintText="http://192.168.1.100:8096"
                maxTextLength="200"
            />

            <!-- Username -->
            <Label text="Username" font="font:SmallSystemFont" color="#AAAAAA" />
            <TextEditBox
                id="usernameField"
                width="800"
                hintText="Username"
                maxTextLength="100"
            />

            <!-- Password -->
            <Label text="Password" font="font:SmallSystemFont" color="#AAAAAA" />
            <TextEditBox
                id="passwordField"
                width="800"
                hintText="Password"
                maxTextLength="100"
                secureMode="true"
            />

            <!-- Connect Button -->
            <Button
                id="connectButton"
                text="Connect"
                minWidth="300"
                focusedColor="#4a90d9"
            />

            <!-- Discover Servers Button -->
            <Button
                id="discoverButton"
                text="Discover Servers"
                minWidth="300"
            />
        </LayoutGroup>

        <!-- Discovered Servers List (hidden by default) -->
        <LayoutGroup
            id="discoveryGroup"
            layoutDirection="vert"
            translation="[1400, 250]"
            itemSpacings="[10]"
            visible="false"
        >
            <Label text="Discovered Servers" font="font:SmallSystemFont" color="#AAAAAA" />
            <LabelList
                id="serverList"
                itemSize="[400, 48]"
                numRows="5"
                textColor="#FFFFFF"
                focusedTextColor="#FFFFFF"
                color="#333333"
                focusedColor="#4a90d9"
            />
        </LayoutGroup>

        <!-- Status / Error Label -->
        <Label
            id="statusLabel"
            text=""
            font="font:SmallSystemFont"
            color="#FF6666"
            translation="[960, 900]"
            horizAlign="center"
            width="1000"
        />

        <!-- Loading Spinner -->
        <LoadingSpinner id="spinner" visible="false" />

        <!-- Error Dialog -->
        <ErrorDialog id="errorDialog" />

        <!-- API Task (created dynamically) -->
        <JellyfinApi id="apiTask" />

        <!-- Server Discovery Task -->
        <ServerDiscoveryTask id="discoveryTask" />
    </children>
</component>
```

- [ ] **Step 2: Create components/screens/auth/ServerConnectionScreen.bs**

```brightscript
' components/screens/auth/ServerConnectionScreen.bs
sub init()
    m.serverUrlField = m.top.findNode("serverUrlField")
    m.usernameField = m.top.findNode("usernameField")
    m.passwordField = m.top.findNode("passwordField")
    m.connectButton = m.top.findNode("connectButton")
    m.discoverButton = m.top.findNode("discoverButton")
    m.serverList = m.top.findNode("serverList")
    m.discoveryGroup = m.top.findNode("discoveryGroup")
    m.statusLabel = m.top.findNode("statusLabel")
    m.spinner = m.top.findNode("spinner")
    m.errorDialog = m.top.findNode("errorDialog")
    m.apiTask = m.top.findNode("apiTask")
    m.discoveryTask = m.top.findNode("discoveryTask")

    m.isLoading = false

    ' Observe button presses
    m.connectButton.observeFieldScoped("buttonSelected", "onConnectPressed")
    m.discoverButton.observeFieldScoped("buttonSelected", "onDiscoverPressed")

    ' Observe API responses
    m.apiTask.observeFieldScoped("response", "onApiResponse")
    m.apiTask.control = "RUN"

    ' Observe discovery results
    m.discoveryTask.observeFieldScoped("servers", "onServersDiscovered")

    ' Observe server list selection
    m.serverList.observeFieldScoped("itemSelected", "onServerSelected")

    ' Initial focus
    m.serverUrlField.setFocus(true)
end sub

sub onConnectPressed()
    if m.isLoading then return

    serverUrl = m.serverUrlField.text.Trim()
    username = m.usernameField.text.Trim()
    password = m.passwordField.text

    ' Basic validation
    if serverUrl = ""
        showStatus("Please enter a server address.")
        m.serverUrlField.setFocus(true)
        return
    end if

    if username = ""
        showStatus("Please enter a username.")
        m.usernameField.setFocus(true)
        return
    end if

    ' Normalize URL
    serverUrl = normalizeUrl(serverUrl)

    showLoading(true)
    showStatus("")

    ' First validate the server, then authenticate
    m.pendingUsername = username
    m.pendingPassword = password
    m.apiTask.request = {
        action: "getPublicInfo"
        serverUrl: serverUrl
    }
end sub

sub onDiscoverPressed()
    showStatus("Searching for Jellyfin servers...")
    m.discoveryTask.control = "stop"
    m.discoveryTask.control = "RUN"
end sub

sub onServersDiscovered()
    servers = m.discoveryTask.servers
    showStatus("")

    if servers = invalid or servers.count() = 0
        showStatus("No servers found on your network.")
        return
    end if

    ' Populate the server list
    content = CreateObject("roSGNode", "ContentNode")
    for each server in servers
        item = content.createChild("ContentNode")
        item.title = server.serverName + " (" + server.serverUrl + ")"
        item.description = server.serverUrl
    end for
    m.serverList.content = content
    m.discoveryGroup.visible = true
    m.serverList.setFocus(true)
end sub

sub onServerSelected()
    index = m.serverList.itemSelected
    if index < 0 then return

    content = m.serverList.content
    if content = invalid then return

    item = content.getChild(index)
    if item = invalid then return

    ' Fill in the server URL field
    m.serverUrlField.text = item.description
    m.discoveryGroup.visible = false
    m.usernameField.setFocus(true)
end sub

sub onApiResponse()
    response = m.apiTask.response
    if response = invalid then return

    action = response.action

    if action = "getPublicInfo"
        if response.success
            ' Server is valid — now authenticate
            m.apiTask.request = {
                action: "authenticate"
                serverUrl: response.serverUrl
                username: m.pendingUsername
                password: m.pendingPassword
            }
        else
            showLoading(false)
            showStatus(response.error)
        end if
    else if action = "authenticate"
        showLoading(false)
        if response.success
            ' Save auth to registry
            Registry.saveAuth(
                response.serverUrl,
                response.accessToken,
                response.userId,
                response.userName
            )

            ' Update global state
            m.global.serverUrl = response.serverUrl
            m.global.authToken = response.accessToken
            m.global.userId = response.userId

            ' Signal success — MainScene handles navigation
            m.top.loginSuccess = true
        else
            showStatus(response.error)
        end if
    end if
end sub

sub showLoading(loading as boolean)
    m.isLoading = loading
    m.spinner.visible = loading
end sub

sub showStatus(message as string)
    m.statusLabel.text = message
end sub

function normalizeUrl(url as string) as string
    ' Add http:// if no scheme
    urlLower = LCase(url)
    if Left(urlLower, 7) <> "http://" and Left(urlLower, 8) <> "https://"
        url = "http://" + url
    end if
    ' Remove trailing slash
    if Right(url, 1) = "/"
        url = Left(url, Len(url) - 1)
    end if
    return url
end function

function onKeyEvent(key as string, press as boolean) as boolean
    if press
        if key = "back"
            ' If discovery list is showing, hide it
            if m.discoveryGroup.visible
                m.discoveryGroup.visible = false
                m.connectButton.setFocus(true)
                return true
            end if
        end if
    end if
    return false
end function
```

- [ ] **Step 3: Verify build compiles**

```bash
npm run build
```

- [ ] **Step 4: Commit**

```bash
git add components/screens/auth/ServerConnectionScreen.xml components/screens/auth/ServerConnectionScreen.bs
git commit -m "feat: add ServerConnectionScreen with URL entry, login, and SSDP discovery"
```

---

### Task 11: Placeholder Home Screen

**Files:**
- Create: `components/screens/home/HomeScreen.xml`
- Create: `components/screens/home/HomeScreen.bs`

- [ ] **Step 1: Create components/screens/home/HomeScreen.xml**

A minimal placeholder that shows "Welcome" and the user's name, with a sign out option. This will be replaced in Phase 2 with the full home screen.

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<component name="HomeScreen" extends="Group">
    <interface>
        <field id="signOut" type="boolean" value="false" alwaysNotify="true" />
    </interface>
    <script type="text/brightscript" uri="HomeScreen.bs" />
    <children>
        <!-- Background -->
        <Rectangle width="1920" height="1080" color="#1a1a2e" />

        <LayoutGroup
            id="contentGroup"
            layoutDirection="vert"
            horizAlignment="center"
            vertAlignment="center"
            translation="[960, 400]"
            itemSpacings="[20]"
        >
            <Label
                id="welcomeLabel"
                text="Welcome to Sashimi"
                font="font:LargeSystemFont"
                color="#FFFFFF"
                horizAlign="center"
            />
            <Label
                id="userLabel"
                text=""
                font="font:MediumSystemFont"
                color="#888888"
                horizAlign="center"
            />
            <Label
                id="serverLabel"
                text=""
                font="font:SmallSystemFont"
                color="#666666"
                horizAlign="center"
            />
            <Button
                id="signOutButton"
                text="Sign Out"
                minWidth="200"
            />
        </LayoutGroup>

        <!-- Loading Spinner for session validation -->
        <LoadingSpinner id="spinner" visible="false" message="Validating session..." />

        <!-- API Task -->
        <JellyfinApi id="apiTask" />

        <!-- Toast Overlay -->
        <ToastOverlay id="toast" />
    </children>
</component>
```

- [ ] **Step 2: Create components/screens/home/HomeScreen.bs**

```brightscript
' components/screens/home/HomeScreen.bs
sub init()
    m.welcomeLabel = m.top.findNode("welcomeLabel")
    m.userLabel = m.top.findNode("userLabel")
    m.serverLabel = m.top.findNode("serverLabel")
    m.signOutButton = m.top.findNode("signOutButton")
    m.spinner = m.top.findNode("spinner")
    m.apiTask = m.top.findNode("apiTask")
    m.toast = m.top.findNode("toast")

    ' Observe
    m.signOutButton.observeFieldScoped("buttonSelected", "onSignOut")
    m.apiTask.observeFieldScoped("response", "onApiResponse")
    m.apiTask.control = "RUN"

    ' Display user info from globals
    userName = Registry.getUserName()
    serverUrl = m.global.serverUrl
    m.userLabel.text = "Logged in as: " + userName
    m.serverLabel.text = "Server: " + serverUrl

    ' Validate session on load
    restoreSession()

    m.signOutButton.setFocus(true)
end sub

sub restoreSession()
    ' Restore globals from registry
    m.global.serverUrl = Registry.getServerUrl()
    m.global.authToken = Registry.getAuthToken()
    m.global.userId = Registry.getUserId()

    m.spinner.visible = true
    m.apiTask.request = { action: "validateSession" }
end sub

sub onApiResponse()
    response = m.apiTask.response
    if response = invalid then return

    if response.action = "validateSession"
        m.spinner.visible = false
        if response.success
            m.toast.showToast = { message: "Connected to server", duration: 2 }
        else
            ' Session expired — sign out
            doSignOut()
        end if
    end if
end sub

sub onSignOut()
    doSignOut()
end sub

sub doSignOut()
    Registry.clearAuth()
    m.global.serverUrl = ""
    m.global.authToken = ""
    m.global.userId = ""
    m.top.signOut = true
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    ' Home screen is the root — don't handle back (let Roku exit)
    return false
end function
```

- [ ] **Step 3: Verify build compiles**

```bash
npm run build
```

- [ ] **Step 4: Commit**

```bash
git add components/screens/home/HomeScreen.xml components/screens/home/HomeScreen.bs
git commit -m "feat: add placeholder HomeScreen with session validation and sign out"
```

---

## Chunk 4: Wire Everything Together

### Task 12: Wire MainScene to Screens

**Files:**
- Modify: `components/MainScene.bs`

- [ ] **Step 1: Update MainScene.bs to observe screen events**

Add observers for `loginSuccess` on ServerConnectionScreen and `signOut` on HomeScreen so the nav stack transitions correctly.

Replace the `showScreen` sub with this updated version that wires up screen-specific observers:

```brightscript
sub showScreen(screenName as string)
    screen = createObject("roSGNode", screenName)
    if screen = invalid
        print "ERROR: Could not create screen: " + screenName
        return
    end if

    ' Hide current screen
    if m.currentScreen <> invalid
        m.currentScreen.visible = false
    end if

    ' Add and show new screen
    m.top.appendChild(screen)
    m.navStack.push(screen)
    m.currentScreen = screen
    screen.setFocus(true)

    ' Wire up screen-specific observers
    if screenName = "ServerConnectionScreen"
        screen.observeFieldScoped("loginSuccess", "onLoginSuccess")
    else if screenName = "HomeScreen"
        screen.observeFieldScoped("signOut", "onSignOut")
    end if
end sub

sub onLoginSuccess()
    navigateToHome()
end sub

sub onSignOut()
    navigateToAuth()
end sub
```

- [ ] **Step 2: Verify build compiles**

```bash
npm run build
```

- [ ] **Step 3: Commit**

```bash
git add components/MainScene.bs
git commit -m "feat: wire MainScene navigation between auth and home screens"
```

---

### Task 13: Integration Testing on Device

- [ ] **Step 1: Deploy to a Roku device**

```bash
cd /Users/mondo/Documents/git/sashimi-roku
npm run package
# Upload sashimi.zip to Roku device via http://<roku-ip>
```

- [ ] **Step 2: Test the full auth flow**

1. Channel launches with Sashimi splash screen
2. ServerConnectionScreen appears with URL, username, password fields
3. Enter Jellyfin server URL → validates server via `/System/Info/Public`
4. Enter credentials → authenticates via `/Users/AuthenticateByName`
5. On success → navigates to placeholder HomeScreen showing "Welcome to Sashimi"
6. HomeScreen validates session on load
7. Sign Out button → clears registry, returns to ServerConnectionScreen
8. Re-launch channel → auto-restores session, shows HomeScreen directly

- [ ] **Step 3: Test SSDP discovery**

1. Press "Discover Servers" button
2. Verify Jellyfin servers on the LAN appear in the list
3. Select a server → URL fills in automatically
4. Complete login flow

- [ ] **Step 4: Test error handling**

1. Enter invalid server URL → "Could not connect to server" error
2. Enter wrong password → "Authentication failed" error
3. Back button on ServerConnectionScreen exits channel
4. Loading spinner appears during network operations

- [ ] **Step 5: Test session persistence**

1. Log in successfully
2. Exit the channel (Home button)
3. Re-launch → HomeScreen appears without login prompt
4. Sign out → returns to ServerConnectionScreen
5. Re-launch → ServerConnectionScreen appears (session was cleared)

- [ ] **Step 6: Fix any issues found during testing and commit**

```bash
git add -A
git commit -m "fix: address issues found during device integration testing"
```

---

### Task 14: CI Setup (GitHub Actions)

**Files:**
- Create: `.github/workflows/build.yml`

- [ ] **Step 1: Create the CI workflow**

```yaml
name: Build Roku App

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Lint
        run: npm run lint

      - name: Build
        run: npm run build

      - name: Package
        run: npm run package

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: sashimi-roku
          path: sashimi.zip
```

- [ ] **Step 2: Push and verify CI passes**

```bash
git add .github/workflows/build.yml
git commit -m "ci: add GitHub Actions workflow for lint, build, and package"
git push -u origin main
gh run watch
```

Expected: CI passes — lint, build, package all succeed. Artifact `sashimi.zip` uploaded.

- [ ] **Step 3: Set up branch protection on main**

```bash
gh api repos/mondominator/sashimi-roku/branches/main/protection \
  --method PUT \
  --field required_status_checks='{"strict":true,"contexts":["build"]}' \
  --field enforce_admins=true \
  --field required_pull_request_reviews='{"required_approving_review_count":0}' \
  --field restrictions=null
```

---

### Task 15: Final Phase 1 Cleanup

- [ ] **Step 1: Review all files for leftover `print` statements**

These are fine for development but should be wrapped in `#if DEBUG` blocks for production:

Search for `print` in all `.bs` files and wrap in conditionals:

```brightscript
' Replace bare print statements with:
#if DEBUG
    print "message"
#end if
```

- [ ] **Step 2: Verify the complete build**

```bash
npm run lint && npm run build && npm run package
```

Expected: All pass, `sashimi.zip` produced.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: wrap debug print statements in #if DEBUG blocks"
```

---

## Phase 1 Deliverable

At the end of Phase 1, the `sashimi-roku` channel:

1. Launches with Sashimi branding (splash screen, channel icon)
2. Shows ServerConnectionScreen for first-time setup
3. Discovers Jellyfin servers on the LAN via SSDP
4. Accepts manual server URL with validation
5. Authenticates with username/password
6. Persists credentials in Roku Registry
7. Auto-restores sessions on re-launch
8. Shows placeholder HomeScreen with session validation
9. Supports sign out (clears credentials, returns to auth)
10. Shows loading spinners during network operations (certification)
11. Shows user-friendly error dialogs (certification)
12. Fires AppLaunchComplete beacon (certification)
13. Handles back button correctly at all levels (certification)
14. CI builds, lints, and packages on every push/PR

**Next:** Phase 2 plan will cover HomeScreen (hero carousel, continue watching, library rows) and LibraryScreen (grid browsing with sort/filter/pagination).
