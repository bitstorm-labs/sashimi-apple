import AppIntents

#if compiler(>=6.4)
/// Publishes parameterized Sashimi actions without requiring people to create
/// one shortcut per title. Media parameters are AppEntities, so Siri and
/// Shortcuts resolve them through SashimiMediaEntityQuery.
@available(iOS 27.0, *)
struct SashimiAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SashimiOpenMediaIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Show \(\.$target) in \(.applicationName)",
                "Go to \(\.$target) in \(.applicationName)"
            ],
            shortTitle: "Open in Sashimi",
            systemImageName: "rectangle.portrait.and.arrow.forward"
        )
        AppShortcut(
            intent: SashimiLatestAdditionsIntent(),
            phrases: [
                "Show the latest additions in \(.applicationName)",
                "Show me what's new in \(.applicationName)",
                "What's new in \(.applicationName)"
            ],
            shortTitle: "Latest Additions",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: SashimiEntityPlaybackIntent(mode: .automatic),
            phrases: [
                "Play \(\.$target) in \(.applicationName)",
                "Watch \(\.$target) in \(.applicationName)"
            ],
            shortTitle: "Play in Sashimi",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: SashimiEntityPlaybackIntent(mode: .resume),
            phrases: [
                "Resume \(\.$target) in \(.applicationName)",
                "Continue watching \(\.$target) in \(.applicationName)"
            ],
            shortTitle: "Resume in Sashimi",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: SashimiEntityPlaybackIntent(mode: .upNext),
            phrases: [
                "Play Up Next for \(\.$target) in \(.applicationName)",
                "Play the next episode of \(\.$target) in \(.applicationName)"
            ],
            shortTitle: "Play Up Next",
            systemImageName: "forward.end.fill"
        )
        AppShortcut(
            intent: SashimiEntityPlaybackIntent(mode: .newestEpisode),
            phrases: [
                "Play the newest episode of \(\.$target) in \(.applicationName)",
                "Play the latest episode of \(\.$target) in \(.applicationName)"
            ],
            shortTitle: "Play Newest",
            systemImageName: "sparkles"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
#endif
