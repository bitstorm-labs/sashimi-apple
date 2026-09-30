import SwiftUI

/// Where a detail page leads: one page pushed onto a tab's `NavigationStack`.
///
/// Each push gets its own `id`, so pushing the same title twice (Episode ->
/// Series -> the same Episode) produces two distinct pages, and per-page state
/// the router keeps — a server scope — can be keyed on the page, not the title.
struct DetailRoute: Hashable, Identifiable {
    enum Destination: Hashable {
        /// A title on the server the app (or the enclosing server-scoped page)
        /// is currently talking to.
        case item(BaseItemDto, forceYouTubeStyle: Bool = false, serverID: String? = nil)
        /// A cast or crew member's cross-server filmography.
        case person(PersonInfo, PersonRouteContext)
        /// A title chosen from search or a filmography, which may live on a
        /// different saved server. The router holds that server's client scope
        /// for as long as this page is anywhere in the path.
        case serverMedia(ServerMediaResult)
    }

    let id: UUID
    let destination: Destination

    init(_ destination: Destination, id: UUID = UUID()) {
        self.id = id
        self.destination = destination
    }

    /// The show this page belongs to, for theme songs. People have none.
    var themeSeriesKey: String? {
        switch destination {
        case .item(let item, _, _): return ThemeSongVisitState.seriesKey(for: item)
        case .serverMedia(let source): return ThemeSongVisitState.seriesKey(for: source.item)
        case .person: return nil
        }
    }

    var scopedServerID: String? {
        if case .serverMedia(let source) = destination { return source.serverID }
        return nil
    }
}

/// What a person page needs to know about the title it was opened from.
struct PersonRouteContext: Hashable {
    let excludingItemID: String?
    let excludingTitleKey: String?
    let originatingServerID: String?
}

/// The one navigation path for detail pages (tvOS, issue #15).
///
/// Detail pages used to stack `fullScreenCover`s with no depth limit. They are
/// now pushed onto the current tab's `NavigationStack`, which binds to `path`.
/// Only one tab's content is alive at a time (the rail swaps the view), so one
/// app-level path is the same thing as one path per tab — and it lets the rail,
/// deep links and theme songs all see the same state:
///
/// - The rail hides while `path` is non-empty, so a detail page covers the
///   whole screen as the cover did.
/// - Deep links replace the path (`openExternally`).
/// - The show that owns the path drives `ThemeSongPlayer`.
/// - A `.serverMedia` page's server-client scope lives exactly as long as the
///   page is in the path. A view's `.task` can't own it: a page that is pushed
///   over disappears, which cancels its task, and the scope would end under
///   the deeper pages that still need that server.
@MainActor
final class DetailRouter: ObservableObject {
    enum ScopeState: Equatable {
        case connecting
        case ready
        case failed
    }

    @Published var path: [DetailRoute] = [] {
        didSet { pathDidChange(from: oldValue) }
    }

    /// Scope progress for each `.serverMedia` page in the path, by route id.
    @Published private(set) var scopeStates: [UUID: ScopeState] = [:]

    /// A page requested from outside the tab UI (a Top Shelf deep link). The
    /// tab host consumes it — switching to a tab that can push if needed — and
    /// clears it.
    @Published var externalRequest: DetailRoute?

    private var scopeTokens: [UUID: ServerClientScopeToken] = [:]
    private let beginScope: (String) async -> ServerClientScopeToken?
    private let endScope: (ServerClientScopeToken) async -> Void
    private let themeSeriesChanged: @MainActor (String?) -> Void

    /// Scope ends run one at a time, innermost first, in the order the pages
    /// left the path. Chained so a later pop can't overtake an earlier one.
    private var endChain: Task<Void, Never>?

    init(
        beginScope: @escaping (String) async -> ServerClientScopeToken? = { serverID in
            await SessionManager.shared.beginServerScope(for: serverID)
        },
        endScope: @escaping (ServerClientScopeToken) async -> Void = { token in
            await SessionManager.shared.endServerScope(token)
        },
        themeSeriesChanged: @escaping @MainActor (String?) -> Void = { seriesID in
            ThemeSongPlayer.shared.activeSeriesChanged(to: seriesID)
        }
    ) {
        self.beginScope = beginScope
        self.endScope = endScope
        self.themeSeriesChanged = themeSeriesChanged
    }

    var isAtRoot: Bool { path.isEmpty }

    func push(_ destination: DetailRoute.Destination) {
        path.append(DetailRoute(destination))
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func popToRoot() {
        guard !path.isEmpty else { return }
        path.removeAll()
    }

    /// Ask the tab host to show `destination` as the only page on the stack.
    func openExternally(_ destination: DetailRoute.Destination) {
        externalRequest = DetailRoute(destination)
    }

    func scopeState(for route: DetailRoute) -> ScopeState? {
        scopeStates[route.id]
    }

    /// Returns a finished scope-end chain; tests await it to observe ends.
    func waitForPendingScopeEnds() async {
        await endChain?.value
    }

    // MARK: - Path bookkeeping

    /// The show whose theme should be playing for `path`: the nearest page
    /// from the top that belongs to a show. A person or movie page pushed over
    /// a series keeps that series' theme (as it did under covers); a
    /// server-scoped page counts only once its server is connected, so the
    /// theme is never looked up against the wrong server. An empty path — a
    /// tab's root — has no show, which stops the theme.
    static func themeSeriesID(for path: [DetailRoute], scopeStates: [UUID: ScopeState]) -> String? {
        var connected = true
        var owner: String?
        // Walk bottom-up: a page below an unconnected server scope is still on
        // its own server, but nothing above that scope can be trusted yet.
        for route in path {
            if route.scopedServerID != nil {
                connected = scopeStates[route.id] == .ready
            }
            guard connected else { continue }
            if let key = route.themeSeriesKey { owner = key }
        }
        return owner
    }

    private func pathDidChange(from oldPath: [DetailRoute]) {
        let liveIDs = Set(path.map(\.id))

        // Pages that left the path release their scopes, innermost first.
        let departed = oldPath.reversed().filter { $0.scopedServerID != nil && !liveIDs.contains($0.id) }
        for route in departed {
            scopeStates[route.id] = nil
            if let token = scopeTokens.removeValue(forKey: route.id) {
                enqueueEnd(token)
            }
            // A scope still connecting is ended by its begin task once it
            // notices the page is gone.
        }

        // New server-scoped pages start connecting.
        for route in path where route.scopedServerID != nil && scopeStates[route.id] == nil {
            begin(route)
        }

        publishTheme()
    }

    private func begin(_ route: DetailRoute) {
        guard let serverID = route.scopedServerID else { return }
        scopeStates[route.id] = .connecting
        Task { [weak self] in
            guard let self else { return }
            let token = await beginScope(serverID)
            guard path.contains(where: { $0.id == route.id }) else {
                // Popped while connecting: give the scope straight back.
                if let token { enqueueEnd(token) }
                return
            }
            if let token {
                scopeTokens[route.id] = token
                scopeStates[route.id] = .ready
            } else {
                scopeStates[route.id] = .failed
            }
            publishTheme()
        }
    }

    private func enqueueEnd(_ token: ServerClientScopeToken) {
        let previous = endChain
        let endScope = endScope
        endChain = Task {
            await previous?.value
            await endScope(token)
        }
    }

    private func publishTheme() {
        themeSeriesChanged(Self.themeSeriesID(for: path, scopeStates: scopeStates))
    }
}
