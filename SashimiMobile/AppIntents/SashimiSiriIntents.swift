import AppIntents
import Foundation
import NukeUI
import SwiftUI

// Keep the iOS 27 system-schema intents together so Siri's search and video
// contracts share their error and routing behavior.
// swiftlint:disable file_length

enum SashimiSiriIntentError: LocalizedError, Equatable, Sendable {
    case emptySearchQuery
    case authenticationRequired
    case unavailableServer
    case noResults
    case resumeNotFound
    case playbackNotFound
    case seasonNotFound

    var errorDescription: String? {
        switch self {
        case .emptySearchQuery:
            return "Tell Sashimi which title to search for."
        case .authenticationRequired:
            return "Sign in to Sashimi before using Siri search."
        case .unavailableServer:
            return "Sashimi cannot reach the server for that title right now."
        case .noResults:
            return "Sashimi could not find a matching title."
        case .resumeNotFound:
            return "Sashimi could not find that title in Continue Watching."
        case .playbackNotFound:
            return "Sashimi could not find a playable episode for that title."
        case .seasonNotFound:
            return "Sashimi could not find that season for the requested show."
        }
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, *)
enum SashimiSiriIntentDependencies {
    /// Lets integration tests execute the exact OpenIntent returned by a
    /// navigation branch without replacing the production handoff contract.
    typealias OpenIntentFactory = @Sendable (SashimiMediaEntity) -> SashimiOpenMediaIntent

    @TaskLocal
    static var openIntentFactory: OpenIntentFactory = { entity in
        SashimiOpenMediaIntent(target: entity)
    }
}
#endif

#if compiler(>=6.4)
@available(iOS 26.0, *)
typealias SashimiInAppSearchResult = ReturnsValue<[SashimiMediaEntity]>
    & OpensIntent
    & ShowsSnippetIntent
    & ProvidesDialog
#else
typealias SashimiInAppSearchResult = IntentResult
#endif

// Xcode 27 introduces the system.searchInApp schema. Keep the iOS 26 SDK
// fallback buildable while the new toolchain is being installed locally.
#if compiler(>=6.4)
@available(iOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
#else
@available(iOS 17.2, *)
#endif
struct SashimiInAppSearchIntent: ShowInAppSearchResultsIntent {
    static var title: LocalizedStringResource {
        "Search Sashimi"
    }

    static var description: IntentDescription {
        IntentDescription(
            "Search Sashimi for movies, shows, and videos across your connected servers.",
            categoryName: "Media search",
            searchKeywords: ["Sashimi", "search", "movie", "show", "video"]
        )
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Search Sashimi for \(\.$criteria)")
    }

    static var authenticationPolicy: IntentAuthenticationPolicy {
#if compiler(>=6.4)
        // The iOS 27 system schema is exposed to Siri only after local device
        // authentication, even though the intent still uses the app session.
        .requiresLocalDeviceAuthentication
#else
        .requiresAuthentication
#endif
    }

#if compiler(>=6.4)
    // The iOS 27 system schema makes the enclosing intent iOS 27-available.
    // Keep this declaration unannotated for that compiler path; otherwise
    // Swift diagnoses the member as more available than its enclosing scope.
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    // ShowInAppSearchResultsIntent does not support the explicit `.background`
    // mode. Its dynamic foreground mode lets the system keep a rich search
    // response in Siri when possible. Explicit playback can still opt into
    // the foreground below, while explicit title opens return an OpenIntent
    // for the system to run through its normal scene handoff.
    static let supportedModes: IntentModes = [.foreground(.dynamic)]
#else
    @available(iOS 26.0, *)
    // Keep the complete declaration in this branch. Older Swift parsers do
    // not accept an availability attribute separated from its declaration by
    // the conditional-compilation terminator.
    static let supportedModes: IntentModes = [.foreground(.dynamic)]
#endif

    static let searchScopes: [StringSearchScope] = [.movies, .tv, .freeformVideo]

    @Parameter(
        title: "Search",
        description: "The movie, show, or video title to find."
    )
    var criteria: StringSearchCriteria

    // This method intentionally coordinates search, playback, and open routes
    // because the system search schema can deliver all of those phrases here.
    // swiftlint:disable:next function_body_length
    func perform() async throws -> some SashimiInAppSearchResult {
        let query = SashimiMediaSearchQuery.normalizedTerm(criteria.term)
        guard !query.isEmpty else {
            throw SashimiSiriIntentError.emptySearchQuery
        }

#if compiler(>=6.4)
        try await ensureIntentReady()

        if SashimiMediaSearchQuery.isLatestAdditionsRequest(criteria.term) {
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
#endif

#if compiler(>=6.4)
        // Apple can choose the system search schema for a phrase that contains
        // a playback verb. Keep this path owned by Sashimi too, so a request
        // such as “resume Ghosts in Sashimi” cannot fall through to another
        // PlayVideo provider such as Apple Music.
        let playbackRequest = SashimiPlaybackRequest(rawTerm: criteria.term)
        if playbackRequest.hasExplicitPlaybackDirective {
            let entity = try await resolvePlaybackEntity(for: playbackRequest)
            let dialog = SashimiPlaybackDialog.make(for: playbackRequest, entity: entity)

            if case .season = playbackRequest.selection {
                return .result(
                    value: [],
                    opensIntent: SashimiSiriIntentDependencies.openIntentFactory(entity),
                    dialog: dialog,
                    snippetIntent: EmptySnippetIntent()
                )
            }

            try await continueInForegroundForPlayback(dialog: dialog)
            await routePlayback(playbackRequest, entity: entity)

            let playbackEntities = [entity]
            return .result(
                value: playbackEntities,
                dialog: dialog,
                snippetIntent: SashimiSearchResultsSnippetIntent(results: playbackEntities)
            )
        }
#endif

#if compiler(>=6.4)
        let entities = await searchEntities(for: query)
#endif

#if compiler(>=6.4)
        if let seasonRoute = await resolveSeasonShorthand(query: query, entities: entities) {
            let dialog = SashimiPlaybackDialog.make(
                for: seasonRoute.request,
                entity: seasonRoute.entity
            )
            return .result(
                value: [],
                opensIntent: SashimiSiriIntentDependencies.openIntentFactory(seasonRoute.entity),
                dialog: dialog,
                snippetIntent: EmptySnippetIntent()
            )
        }
#endif

#if compiler(>=6.4)
        if SashimiMediaSearchQuery.isExplicitOpenRequest(criteria.term), entities.count == 1,
           let entity = entities.first {
            let dialog = IntentDialog(
                full: "Opening \(entity.title) in Sashimi.",
                supporting: "Opening the title page."
            )
            return .result(
                value: [],
                opensIntent: SashimiSiriIntentDependencies.openIntentFactory(entity),
                dialog: dialog,
                snippetIntent: EmptySnippetIntent()
            )
        }

    let dialog = entities.isEmpty
            ? IntentDialog(
                full: "Sashimi found no titles for \(query).",
                supporting: "Try another movie, show, or video title."
            )
            : IntentDialog(
                full: "Sashimi found \(entities.count) title\(entities.count == 1 ? "" : "s") for \(query).",
                supporting: "Choose a title to open it in Sashimi."
            )
        return .result(
            value: entities,
            dialog: dialog,
            snippetIntent: SashimiSearchResultsSnippetIntent(results: entities)
        )
#else
        return .result()
#endif
    }

#if compiler(>=6.4)
    private func ensureIntentReady() async throws {
        // App Intents can launch a cold app process before ContentView's scene
        // task has restored the saved session.
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
    }

    @available(iOS 27.0, *)
    private func continueInForegroundForPlayback(dialog: IntentDialog) async throws {
        guard systemContext.currentMode == .background else { return }
        try await continueInForeground(dialog, alwaysConfirm: false)
    }

    @available(iOS 27.0, *)
    private func resolveSeasonShorthand(
        query: String,
        entities: [SashimiMediaEntity]
    ) async -> (request: SashimiPlaybackRequest, entity: SashimiMediaEntity)? {
        guard entities.isEmpty else { return nil }
        let request = SashimiPlaybackRequest(
            rawTerm: query,
            allowSeasonShorthand: true
        )
        guard request.isSeasonShorthand else { return nil }
        let resolution = await SashimiMediaPlaybackResolver.resolve(request: request)
        guard let entity = resolution.matches.first else { return nil }
        return (request: request, entity: entity)
    }

    @available(iOS 27.0, *)
    private func resolvePlaybackEntity(
        for request: SashimiPlaybackRequest
    ) async throws -> SashimiMediaEntity {
        let resolution = await SashimiMediaPlaybackResolver.resolve(request: request)
        guard let entity = resolution.matches.first else {
            if resolution.queriedServerCount == 0
                || resolution.failedServerCount == resolution.queriedServerCount {
                throw SashimiSiriIntentError.unavailableServer
            }
            if case .season = request.selection {
                throw SashimiSiriIntentError.seasonNotFound
            }
            throw SashimiSiriIntentError.playbackNotFound
        }
        return entity
    }

    @MainActor
    private func routePlayback(
        _ request: SashimiPlaybackRequest,
        entity: SashimiMediaEntity
    ) {
        switch request.selection {
        case .season:
            SashimiIntentCoordinator.shared.requestOpen(entity: entity)
        default:
            SashimiIntentCoordinator.shared.requestPlay(entity: entity)
        }
    }

    @available(iOS 27.0, *)
    private func searchEntities(for query: String) async -> [SashimiMediaEntity] {
        let search = await MultiServerSearchService.searchWithStatus(query: query, limit: 50)
        let preferredServerID = await MainActor.run { SessionManager.shared.activeServerId }
        return ServerMediaResultGrouping.groups(
            from: search.results,
            preferredServerID: preferredServerID
        )
        .prefix(6)
        .map { SashimiMediaEntity(result: $0.primary) }
    }
#endif
}

// The system.open schema is available in the Xcode 27 SDK. On older SDKs this
// remains a regular OpenIntent, which keeps the route testable without
// pretending the iOS 27 Siri schema is present.
#if compiler(>=6.4)
@available(iOS 27.0, *)
@AppIntent(schema: .system.open)
#endif
struct SashimiOpenMediaIntent: OpenIntent {
    static var title: LocalizedStringResource {
        "Open Sashimi Title"
    }

    static var description: IntentDescription {
        IntentDescription(
            "Open a movie, show, season, or episode in Sashimi.",
            categoryName: "Media navigation",
            searchKeywords: ["Sashimi", "open", "title", "movie", "show"]
        )
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target) in Sashimi")
    }

    static var authenticationPolicy: IntentAuthenticationPolicy {
#if compiler(>=6.4)
        .requiresLocalDeviceAuthentication
#else
        .requiresAuthentication
#endif
    }

#if compiler(>=6.4)
    // See the availability note on SashimiInAppSearchIntent.supportedModes.
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let supportedModes: IntentModes = [.foreground(.immediate)]
#else
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
#endif

    @Parameter(
        title: "Title",
        description: "The Sashimi title to open."
    )
    var target: SashimiMediaEntity

    init() {
        target = .placeholder
    }

    init(target: SashimiMediaEntity) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        // Make cold-launch entity opens use the same persisted-session path as
        // normal app startup before checking the server-scoped target.
        await SessionManager.shared.restoreSessionForIntent()
        let availability = await MainActor.run {
            guard SessionManager.shared.isAuthenticated else {
                return OpenAvailability.authenticationRequired
            }
            guard let server = SessionManager.shared.servers.first(where: { $0.id == target.serverID }) else {
                return OpenAvailability.unavailableServer
            }
            guard SessionManager.shared.token(for: server, allowLegacyFallback: true) != nil else {
                return OpenAvailability.authenticationRequired
            }
            return OpenAvailability.available
        }

        switch availability {
        case .available:
            break
        case .authenticationRequired:
            throw SashimiSiriIntentError.authenticationRequired
        case .unavailableServer:
            throw SashimiSiriIntentError.unavailableServer
        }

        await MainActor.run {
            SashimiIntentCoordinator.shared.requestOpen(entity: target)
        }
        return .result()
    }

    private enum OpenAvailability: Sendable {
        case available
        case authenticationRequired
        case unavailableServer
    }
}

#if compiler(>=6.4)
/// Plays or opens a title using the system video contract Siri understands.
///
/// `PlayVideoIntent` is intentionally the one Sashimi playback entry point.
/// It resolves explicit requests for Continue Watching, Up Next, newest
/// episodes, and seasons before handing a server-scoped entity to the existing
/// player or detail route. Keeping the title and summary play-oriented makes
/// Siri classify Sashimi as the requested video provider instead of handing a
/// resume phrase to an unrelated audio provider.
@available(iOS 27.0, *)
struct SashimiPlayVideoIntent: PlayVideoIntent {
    static var title: LocalizedStringResource {
        "Play or Resume in Sashimi"
    }

    // Keep the legacy free-form PlayVideo contract available to existing
    // integrations, but keep it out of new Siri/App Shortcut discovery. A
    // raw String target is ambiguous with audio providers; the entity-based
    // intent below carries Sashimi's resolved media identity instead.
    static let isDiscoverable = false

    static var description: IntentDescription {
        IntentDescription(
            "Play movies, shows, and videos in Sashimi. Resume Continue Watching, play Up Next or the newest episode, or open a season.",
            categoryName: "Video playback",
            searchKeywords: [
                "Sashimi", "play", "resume", "watch", "continue watching", "up next",
                "next episode", "newest episode", "latest episode", "season", "movie", "show"
            ]
        )
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$term) in Sashimi")
    }

    static var authenticationPolicy: IntentAuthenticationPolicy {
        .requiresLocalDeviceAuthentication
    }

    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let supportedCategories: [VideoCategory] = [.movies, .tv, .freeform]

    @Parameter(
        title: "Title",
        description: "The movie, show, or video to play in Sashimi."
    )
    var term: String

    init() {
        term = ""
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let request = SashimiPlaybackRequest(rawTerm: term)
        guard !request.title.isEmpty else {
            throw SashimiSiriIntentError.emptySearchQuery
        }

        await SessionManager.shared.restoreSessionForIntent()
        let isAuthenticated = await MainActor.run { SessionManager.shared.isAuthenticated }
        guard isAuthenticated else {
            throw SashimiSiriIntentError.authenticationRequired
        }

        let resolution = await SashimiMediaPlaybackResolver.resolve(request: request)
        guard let entity = resolution.matches.first else {
            if resolution.queriedServerCount == 0
                || resolution.failedServerCount == resolution.queriedServerCount {
                throw SashimiSiriIntentError.unavailableServer
            }
            if case .resume = request.selection {
                throw SashimiSiriIntentError.resumeNotFound
            }
            if case .season = request.selection {
                throw SashimiSiriIntentError.seasonNotFound
            }
            throw SashimiSiriIntentError.playbackNotFound
        }

        await MainActor.run {
            switch request.selection {
            case .season:
                SashimiIntentCoordinator.shared.requestOpen(entity: entity)
            default:
                SashimiIntentCoordinator.shared.requestPlay(entity: entity)
            }
        }

        return .result(dialog: SashimiPlaybackDialog.make(for: request, entity: entity))
    }
}

@available(iOS 27.0, *)
enum SashimiPlaybackMode: String, AppEnum, CaseIterable, Sendable {
    case automatic
    case resume
    case upNext
    case newestEpisode

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Playback mode"
    }

    static var caseDisplayRepresentations: [SashimiPlaybackMode: DisplayRepresentation] {
        [
            .automatic: "Play",
            .resume: "Resume",
            .upNext: "Up Next",
            .newestEpisode: "Newest episode"
        ]
    }

    var selection: SashimiPlaybackSelection {
        switch self {
        case .automatic:
            return .automatic
        case .resume:
            return .resume
        case .upNext:
            return .upNext
        case .newestEpisode:
            return .newestEpisode
        }
    }
}

/// Resolves a concrete Sashimi media entity before choosing how to play it.
/// Unlike `PlayVideoIntent`, this action gives Siri an AppEntity parameter, so
/// App Shortcut phrases can bind the requested title to Sashimi's server-aware
/// entity query instead of competing with audio providers on a free-form
/// string.
@available(iOS 27.0, *)
struct SashimiEntityPlaybackIntent: AppIntent {
    static var title: LocalizedStringResource {
        "Play a Sashimi Title"
    }

    static var description: IntentDescription {
        IntentDescription(
            "Play or resume a movie, show, or video in Sashimi.",
            categoryName: "Video playback",
            searchKeywords: [
                "Sashimi", "play", "resume", "watch", "continue watching", "up next",
                "newest episode", "latest episode", "movie", "show", "video"
            ]
        )
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$target) in Sashimi")
    }

    static var authenticationPolicy: IntentAuthenticationPolicy {
        .requiresLocalDeviceAuthentication
    }

    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    @Parameter(
        title: "Title",
        description: "The movie, show, season, or video to play in Sashimi."
    )
    var target: SashimiMediaEntity

    @Parameter(
        title: "Playback",
        description: "How Sashimi should choose the item to play.",
        default: .automatic
    )
    var mode: SashimiPlaybackMode

    init() {
        target = .placeholder
        mode = .automatic
    }

    init(target: SashimiMediaEntity = .placeholder, mode: SashimiPlaybackMode) {
        self.target = target
        self.mode = mode
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SessionManager.shared.restoreSessionForIntent()
        let isAuthenticated = await MainActor.run { SessionManager.shared.isAuthenticated }
        guard isAuthenticated else {
            throw SashimiSiriIntentError.authenticationRequired
        }

        if target.mediaType == ItemType.season.rawValue {
            await MainActor.run {
                SashimiIntentCoordinator.shared.requestOpen(entity: target)
            }
            return .result(
                dialog: IntentDialog(
                    full: "Opening \(target.title) in Sashimi.",
                    supporting: "Showing the episodes in that season."
                )
            )
        }

        // A movie or episode already identifies the exact server-local item.
        // Hand it directly to the existing player so Jellyfin's stored resume
        // position is preserved without a second title search.
        if isDirectPlayableTarget, mode == .automatic || mode == .resume {
            await MainActor.run {
                SashimiIntentCoordinator.shared.requestPlay(entity: target)
            }
            let request = SashimiPlaybackRequest(
                rawTerm: target.title,
                defaultSelection: mode.selection
            )
            return .result(dialog: SashimiPlaybackDialog.make(for: request, entity: target))
        }

        let request = SashimiPlaybackRequest(
            rawTerm: target.title,
            defaultSelection: mode.selection
        )
        let resolution = await SashimiMediaPlaybackResolver.resolve(
            request: request,
            serverID: target.serverID
        )
        guard let entity = resolution.matches.first else {
            if resolution.queriedServerCount == 0
                || resolution.failedServerCount == resolution.queriedServerCount {
                throw SashimiSiriIntentError.unavailableServer
            }
            if mode == .resume {
                throw SashimiSiriIntentError.resumeNotFound
            }
            throw SashimiSiriIntentError.playbackNotFound
        }

        await MainActor.run {
            SashimiIntentCoordinator.shared.requestPlay(entity: entity)
        }
        return .result(dialog: SashimiPlaybackDialog.make(for: request, entity: entity))
    }

    private var isDirectPlayableTarget: Bool {
        guard let mediaType = target.mediaType,
              let itemType = ItemType(rawValue: mediaType) else {
            return false
        }
        return itemType.isPlayableMediaType
    }
}

#endif
