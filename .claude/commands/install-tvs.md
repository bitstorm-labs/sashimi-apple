---
description: Build the tvOS app and install it on a connected Apple TV
argument-hint: "[device name] (default: every paired Apple TV)"
---

Build the current working tree and install it on an Apple TV so I can look at
it on a real screen. The argument is a device name from `devicectl`; with none,
use every paired Apple TV.

```bash
cd "$CLAUDE_PROJECT_DIR"
xcodegen generate    # only if project.yml changed — it is the source of truth

xcrun devicectl list devices    # find the Apple TV names and IDs

xcodebuild -project Sashimi.xcodeproj -scheme Sashimi -configuration Debug \
  -destination 'platform=tvOS,name=<device name>' \
  -allowProvisioningUpdates -derivedDataPath build/dd build
```

Then install the same built product to each device:

```bash
xcrun devicectl device install app --device <ID> \
  build/dd/Build/Products/Debug-appletvos/Sashimi.app
```

Report which devices succeeded. Notes:

- Build once and install the same product on each device.
- The installed build reports the `MARKETING_VERSION` currently in `project.yml`,
  which lags behind release branches. Don't read the version string as proof of
  which code is running — the build timestamp is the reliable signal.
- If a TV still shows the old UI, the app was running when it was replaced; tell
  me to back out to the tvOS home screen and relaunch.
- Anything focus-, remote-, or playback-related can only be judged on the device.
  Say plainly what you verified and what you didn't.
