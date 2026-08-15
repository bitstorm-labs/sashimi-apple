---
description: Build the tvOS app and install it on both Apple TVs
argument-hint: "[living|bedroom|both] (default: both)"
---

Build the current working tree and install it on the Apple TVs so I can look at
it on a real screen. Argument picks the target; default both.

```bash
cd "$CLAUDE_PROJECT_DIR"
xcodegen generate    # only if project.yml changed — it is the source of truth

xcodebuild -project Sashimi.xcodeproj -scheme Sashimi -configuration Debug \
  -destination 'platform=tvOS,name=Living Room' \
  -allowProvisioningUpdates -derivedDataPath build/dd build
```

Then install the same built product to each device:

| Device | ID |
| --- | --- |
| Living Room | `3DEAD265-908E-5316-B8C4-A29524449F94` |
| Bedroom | `097AEE6F-7257-56FF-9247-2C4C2FFE238F` |

```bash
xcrun devicectl device install app --device <ID> \
  build/dd/Build/Products/Debug-appletvos/Sashimi.app
```

Report which devices succeeded. Notes:

- Build once, install twice — don't rebuild per device.
- `xcrun devicectl list devices` re-discovers the IDs if one has changed.
- The installed build reports the `MARKETING_VERSION` currently in `project.yml`,
  which lags behind release branches. Don't read the version string as proof of
  which code is running — the build timestamp is the reliable signal.
- If a TV still shows the old UI, the app was running when it was replaced; tell
  me to back out to the tvOS home screen and relaunch.
- Anything focus-, remote-, or playback-related can only be judged on the device.
  Say plainly what you verified and what you didn't.
