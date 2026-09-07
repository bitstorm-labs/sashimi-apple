# Issue 429 player verification

The player was exercised against the authenticated Jellyfin library on the
three Apple-platform simulators created for this issue. The captures were
taken before the review-gated PR step and are revisioned by the
simulator-screenshots workflow. Revision 14 is the authoritative visual
capture set for this worktree. It contains the final app-owned transport row
used when the opt-in setting is enabled.

The live-series scenario used Silo, season 3 episode 4, “Whatever You Do,
Don't Go Home” (47 min). Its player rendered actual video frames, episode
metadata, stream information, and the opt-in five-button transport row. When
enabled, the app owns the transport controls so the episode buttons stay next
to the 10-second controls on iPhone, iPad, and tvOS. When disabled, the custom
row is absent and the native AVPlayer transport remains in use. The transition
callbacks preserve the existing episode state flow for Previous Episode and
Next Episode.

| Surface | Simulator | Result | Capture |
| --- | --- | --- | --- |
| iPhone | Sashimi iPhone 429, iOS 26.5, `E955E442-E4A0-41B2-9F45-3A1FBB729833` | Live Silo playback with the complete opt-in five-button transport row. | `/Users/pratik/Desktop/Sashimi-429-Screenshots/13/iphone-live-silo-transport-controls-final.png` |
| iPad | Sashimi iPad 429, iOS 26.5, `C8721C8B-DD1C-4DEE-AD11-766BBA01E9C1` | Live Silo playback with the complete opt-in five-button transport row. | `/Users/pratik/Desktop/Sashimi-429-Screenshots/14/ipad-live-silo-transport-controls-final.png` |
| tvOS | Sashimi Apple TV 429, tvOS 26.5, `584A456A-A99E-4162-A5FE-349A752F0205` | Live Silo playback with the complete opt-in five-button transport row centered in the player. | `/Users/pratik/Desktop/Sashimi-429-Screenshots/13/tvos-live-silo-transport-controls-final.png` |

The revision-13 and revision-14 manifests and checksums are in
`/Users/pratik/Desktop/Sashimi-429-Screenshots/13/manifest.json`,
`/Users/pratik/Desktop/Sashimi-429-Screenshots/13/checksums.sha256`,
`/Users/pratik/Desktop/Sashimi-429-Screenshots/14/manifest.json`, and
`/Users/pratik/Desktop/Sashimi-429-Screenshots/14/checksums.sha256`.

The episode was opened with `sashimi://play/<live-episode-id>` after
installing the updated Debug iOS and tvOS builds. The simulator builds force
`AVPlayer.volume = 0` and `isMuted = true` before playback starts; no host
output volume was changed. These are simulator evidence only:
physical-device playback, Siri/App Intent launch, a physical Siri Remote,
codec behavior, and network conditions outside the live simulator session
were not verified here.
