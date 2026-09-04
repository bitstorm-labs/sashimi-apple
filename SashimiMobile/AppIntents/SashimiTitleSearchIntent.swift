import AppIntents
import Foundation

#if compiler(>=6.4)
/// Returns media entities directly to Siri so it can present rich, tappable
/// title results. This is intentionally separate from the system
/// `searchInApp` intent: that schema is the right path for handing a query to
/// Sashimi's custom search screen, while this intent lets Siri keep the result
/// cards in its own UI.
@available(iOS 27.0, *)
struct SashimiTitleSearchIntent: AppIntent {
    static var title: LocalizedStringResource {
        "Find Titles in Sashimi"
    }

    static var description: IntentDescription {
        IntentDescription(
            "Find movies, shows, and videos in Sashimi and show the matching titles.",
            categoryName: "Media search",
            searchKeywords: ["Sashimi", "find", "search", "movie", "show", "video"]
        )
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$searchTerm) in Sashimi")
    }

    static var authenticationPolicy: IntentAuthenticationPolicy {
        .requiresLocalDeviceAuthentication
    }

    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    // Keep title lookup in the background so Siri can render the returned
    // entities and their posters without foregrounding Sashimi. Explicit
    // playback requests can opt into the foreground below; a selected result
    // is opened separately through SashimiOpenMediaIntent.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(
        title: "Title",
        description: "The movie, show, or video title to find."
    )
    var searchTerm: String

    init() {
        searchTerm = ""
    }

    // The intent intentionally keeps its search, playback fallback, and rich
    // result assembly together so every Siri path returns the same cards.
    // Explicit open and playback branches must remain ordered before the
    // ordinary result path so Siri never receives both actions accidentally.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func perform() async throws -> some ReturnsValue<[SashimiMediaEntity]> & ShowsSnippetIntent & ProvidesDialog {
        let query = SashimiMediaSearchQuery.normalizedTerm(searchTerm)
        guard !query.isEmpty else {
            throw SashimiSiriIntentError.emptySearchQuery
        }

        await SessionManager.shared.restoreSessionForIntent()
        let availability = await MainActor.run {
            (
                isAuthenticated: SessionManager.shared.isAuthenticated,
                isConnected: NetworkMonitor.shared.isConnected
            )
        }
        guard availability.isAuthenticated else {
            throw SashimiSiriIntentError.authenticationRequired
        }
        guard availability.isConnected else {
            throw SashimiSiriIntentError.unavailableServer
        }

        if SashimiMediaSearchQuery.isLatestAdditionsRequest(searchTerm) {
            let resolution = try await SashimiLatestAdditionsResolver.resolve()
            return .result(
                value: resolution.entities,
                dialog: IntentDialog(
                    full: "Here are the latest additions in Sashimi.",
                    supporting: "From \(resolution.serverName)."
                ),
                snippetIntent: SashimiLatestAdditionsSnippetIntent(results: resolution.entities)
            )
        }

        // Keep this rich-result fallback from becoming a second provider for
        // playback phrases. Siri normally selects PlayVideoIntent, but if it
        // resolves this discoverable action instead, the request still stays
        // inside Sashimi rather than falling through to Apple Music.
        let playbackRequest = SashimiPlaybackRequest(rawTerm: searchTerm)
        if playbackRequest.hasExplicitPlaybackDirective {
            let resolution = await SashimiMediaPlaybackResolver.resolve(request: playbackRequest)
            guard let entity = resolution.matches.first else {
                if resolution.queriedServerCount == 0
                    || resolution.failedServerCount == resolution.queriedServerCount {
                    throw SashimiSiriIntentError.unavailableServer
                }
                if case .resume = playbackRequest.selection {
                    throw SashimiSiriIntentError.resumeNotFound
                }
                if case .season = playbackRequest.selection {
                    throw SashimiSiriIntentError.seasonNotFound
                }
                throw SashimiSiriIntentError.playbackNotFound
            }

            let dialog = SashimiPlaybackDialog.make(for: playbackRequest, entity: entity)
            try await continueInForegroundForPlayback(dialog: dialog)

            if case .season = playbackRequest.selection {
                await MainActor.run {
                    SashimiIntentCoordinator.shared.requestOpen(entity: entity)
                }
                return .result(
                    value: [],
                    dialog: dialog,
                    snippetIntent: EmptySnippetIntent()
                )
            }

            await MainActor.run {
                switch playbackRequest.selection {
                case .season:
                    SashimiIntentCoordinator.shared.requestOpen(entity: entity)
                default:
                    SashimiIntentCoordinator.shared.requestPlay(entity: entity)
                }
            }
            return .result(
                value: [entity],
                dialog: dialog,
                snippetIntent: SashimiSearchResultsSnippetIntent(results: [entity])
            )
        }

        let search = await MultiServerSearchService.searchWithStatus(query: query, limit: 50)

        // Siri may pass a season request as “Ghosts 2” after reducing the
        // spoken phrase. Try that interpretation only when title search has no
        // result, keeping real numbered titles on the normal search path.
        let shorthandRequest = SashimiPlaybackRequest(
            rawTerm: query,
            allowSeasonShorthand: true
        )
        if search.results.isEmpty, shorthandRequest.isSeasonShorthand {
            let resolution = await SashimiMediaPlaybackResolver.resolve(request: shorthandRequest)
            if let entity = resolution.matches.first {
                let dialog = SashimiPlaybackDialog.make(for: shorthandRequest, entity: entity)
                try await continueInForegroundForPlayback(dialog: dialog)

                await MainActor.run {
                    SashimiIntentCoordinator.shared.requestOpen(entity: entity)
                }
                return .result(
                    value: [],
                    dialog: dialog,
                    snippetIntent: EmptySnippetIntent()
                )
            }
        }

        guard !search.results.isEmpty || !search.hasServerFailures else {
            throw SashimiSiriIntentError.unavailableServer
        }

        let entities = search.results.map(SashimiMediaEntity.init(result:))
        guard !entities.isEmpty else {
            throw SashimiSiriIntentError.noResults
        }

        if SashimiMediaSearchQuery.isExplicitOpenRequest(searchTerm), entities.count == 1,
           let entity = entities.first {
            let dialog = IntentDialog(
                full: "Opening \(entity.title) in Sashimi.",
                supporting: "Opening the title page."
            )
            try await continueInForegroundForPlayback(dialog: dialog)
            await MainActor.run {
                SashimiIntentCoordinator.shared.requestOpen(entity: entity)
            }
            return .result(
                value: [],
                dialog: dialog,
                snippetIntent: EmptySnippetIntent()
            )
        }

        // Each returned AppEntity carries its DisplayRepresentation (including
        // the poster) and is opened by SashimiOpenMediaIntent when selected.
        return .result(
            value: entities,
            dialog: IntentDialog(
                full: "Sashimi found \(entities.count) title\(entities.count == 1 ? "" : "s") for \(query).",
                supporting: "Choose a title to open it in Sashimi."
            ),
            snippetIntent: SashimiSearchResultsSnippetIntent(results: entities)
        )
    }

    @available(iOS 27.0, *)
    private func continueInForegroundForPlayback(dialog: IntentDialog) async throws {
        guard systemContext.currentMode == .background else { return }
        try await continueInForeground(dialog, alwaysConfirm: false)
    }
}
#endif
