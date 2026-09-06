# Issue 429 player verification

The player was exercised against the authenticated Jellyfin library on the
three Apple-platform simulators created for this issue. The captures were
taken before the review-gated PR step and are revisioned by the
simulator-screenshots workflow. Revision 11 is the authoritative exact-HEAD
capture set for this worktree.

The live-series scenario used Silo, season 3 episode 4, “Whatever You Do,
Don't Go Home” (47 min). Its player rendered actual video frames, episode
metadata, stream information, and opt-in Previous Episode and Next Episode
transport controls. On the iPad, native AVPlayer controls were revealed while
the episode controls remained available beside the 10-second transport
controls. Pressing Next Episode on the iPad transitioned the live player to
Silo season 3 episode 5, “Memory” (52 min), and Previous Episode returned it to
episode 4.

| Surface | Simulator | Result | Capture |
| --- | --- | --- | --- |
| iPhone | Sashimi iPhone 429, iOS 26.5, `E955E442-E4A0-41B2-9F45-3A1FBB729833` | Live Silo playback with the opt-in Previous and Next controls aligned with the native transport row. | `/Users/pratik/Desktop/Sashimi-429-Screenshots/11/iphone-live-silo-transport-controls.png` |
| iPad | Sashimi iPad 429, iOS 26.5, `C8721C8B-DD1C-4DEE-AD11-766BBA01E9C1` | Live Silo playback with native controls visible and opt-in Previous and Next controls remaining at the sides of the 10-second transport cluster. | `/Users/pratik/Desktop/Sashimi-429-Screenshots/11/ipad-live-silo-transport-controls.png` |
| tvOS | Sashimi Apple TV 429, tvOS 26.5, `584A456A-A99E-4162-A5FE-349A752F0205` | Live Silo playback with the opt-in tvOS Previous and Next controls centered in the transport area. | `/Users/pratik/Desktop/Sashimi-429-Screenshots/11/tvos-live-silo-transport-controls.png` |

The complete revision-11 manifest and checksums are in
`/Users/pratik/Desktop/Sashimi-429-Screenshots/11/manifest.json` and
`/Users/pratik/Desktop/Sashimi-429-Screenshots/11/checksums.sha256`. The
manifest records the exact worktree `HEAD` used for the capture.

The episode was opened with `sashimi://play/<live-episode-id>` after
installing the updated Debug iOS and tvOS builds. Playback was muted at the
host output during capture. These are simulator evidence only:
physical-device playback, Siri/App Intent launch, a physical Siri Remote,
codec behavior, and network conditions outside the live simulator session
were not verified here.
