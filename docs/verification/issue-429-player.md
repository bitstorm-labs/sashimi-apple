# Issue 429 player verification

The player was exercised separately on the three Apple-platform simulators
created for this issue. The captures were taken before the review-gated PR
step and are revisioned by the simulator-screenshots workflow. Revision 7 is
the authoritative exact-HEAD capture set for this worktree.

| Surface | Simulator | Result | Capture |
| --- | --- | --- | --- |
| iPhone | Sashimi iPhone 429, iOS 26.5, `E955E442-E4A0-41B2-9F45-3A1FBB729833` | Player route rendered to the completion card with Replay and Done controls. | `/Users/pratik/Desktop/Sashimi-429-Screenshots/7/iphone-player-overlay.png` |
| iPad | Sashimi iPad 429, iOS 26.5, `C8721C8B-DD1C-4DEE-AD11-766BBA01E9C1` | Player rendered to the completion card with Replay and Done controls. | `/Users/pratik/Desktop/Sashimi-429-Screenshots/7/ipad-player-overlay.png` |
| tvOS | Sashimi Apple TV 429, tvOS 26.5, `584A456A-A99E-4162-A5FE-349A752F0205` | Player rendered to the completion card with the tvOS focused Replay control and Done control. | `/Users/pratik/Desktop/Sashimi-429-Screenshots/7/tvos-player-overlay.png` |

The complete revision-7 manifest and checksums are in
`/Users/pratik/Desktop/Sashimi-429-Screenshots/7/manifest.json` and
`/Users/pratik/Desktop/Sashimi-429-Screenshots/7/checksums.sha256`. The
manifest records the exact worktree `HEAD` used for the capture.

The fixture was opened with `sashimi://play/episode-1` after installing the
Debug iOS and tvOS builds. The visual checks cover the player route, current
episode metadata, stream status, episode controls, the completion state, and
the tvOS focusable control surface. They are simulator evidence only:
physical-device playback, Siri/App Intent launch, a physical Siri Remote,
codec behavior, and network conditions outside the fixture were not verified
here.
