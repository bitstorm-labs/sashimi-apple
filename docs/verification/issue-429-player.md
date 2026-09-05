# Issue 429 player verification

The player was exercised separately on the three Apple-platform simulators
created for this issue. The captures were taken before the review-gated PR
step and are revisioned by the simulator-screenshots workflow.

| Surface | Simulator | Result | Capture |
| --- | --- | --- | --- |
| iPhone | Sashimi iPhone 429, iOS 26.5, `E955E442-E4A0-41B2-9F45-3A1FBB729833` | Player route rendered; the revision-1 capture reached the end-card state because the fixture was short. | `/Users/pratik/Desktop/Sashimi-429-Screenshots/1/iphone-player-overlay.png` |
| iPad | Sashimi iPad 429, iOS 26.5, `C8721C8B-DD1C-4DEE-AD11-766BBA01E9C1` | Player rendered with the app metadata overlay and Previous/Next controls. | `/Users/pratik/Desktop/Simulator Screenshot - Sashimi iPad 429 - 2026-09-04 at 22.47.06.png` |
| tvOS | Sashimi Apple TV 429, tvOS 26.5, `584A456A-A99E-4162-A5FE-349A752F0205` | Player rendered with the tvOS metadata overlay and focusable Previous/Next controls. | `/Users/pratik/Desktop/Sashimi-429-Screenshots/1/tvos-player-overlay.png` |

The complete revision-1 manifest and checksums are in
`/Users/pratik/Desktop/Sashimi-429-Screenshots/1/manifest.json` and
`/Users/pratik/Desktop/Sashimi-429-Screenshots/1/checksums.sha256`.

The fixture was opened with `sashimi://play/episode-1` after installing the
Debug iOS and tvOS builds. The visual checks cover the player route, current
episode metadata, stream status, episode controls, and the tvOS focusable
control surface. They are simulator evidence only: physical-device playback,
Siri/App Intent launch, a physical Siri Remote, codec behavior, and network
conditions outside the fixture were not verified here.
