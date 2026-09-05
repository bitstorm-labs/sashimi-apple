import Combine
import CoreFoundation
import Foundation

/// Delivers foreground App Intent requests to the mobile navigation tree.
///
/// App Intents and SwiftUI do not share a view instance, so a small process-wide
/// coordinator is the bridge between the intent's `perform()` method and the
/// already-existing search/detail presentation surfaces.
@MainActor
final class SashimiIntentCoordinator: ObservableObject {
    static let shared = SashimiIntentCoordinator()

    struct SearchRequest: Equatable, Codable, Sendable {
        let id: UUID
        let query: String
    }

    struct OpenRequest: Equatable, Codable, Sendable {
        let id: UUID
        let entity: SashimiMediaEntity
    }

    struct PlayRequest: Equatable, Codable, Sendable {
        let id: UUID
        let entity: SashimiMediaEntity
    }

    enum Route: Equatable, Codable, Sendable {
        case search(SearchRequest)
        case open(OpenRequest)
        case play(PlayRequest)

        var id: UUID {
            switch self {
            case .search(let request): return request.id
            case .open(let request): return request.id
            case .play(let request): return request.id
            }
        }
    }

    @Published private(set) var route: Route?
    private(set) var lastRequestedRoute: Route?

    private static let pendingRouteKey = "pendingSashimiIntentRoute"
    nonisolated(unsafe) private static let routeDidChangeNotificationString: CFString =
        "com.mondominator.sashimi.intent-route-changed" as CFString
    nonisolated private static let routeDidChangeNotification = CFNotificationName(
        rawValue: "com.mondominator.sashimi.intent-route-changed" as CFString
    )
    private var routeObserver: UnsafeMutableRawPointer?

    init() {
        route = Self.loadPersistedRoute()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        routeObserver = observer
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let coordinator = Unmanaged<SashimiIntentCoordinator>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                Task { @MainActor in
                    coordinator.reloadPersistedRoute()
                }
            },
            Self.routeDidChangeNotificationString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        guard let routeObserver else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            routeObserver,
            Self.routeDidChangeNotification,
            nil
        )
    }

    /// Reload a route written by Siri or Shortcuts while the app process was
    /// already alive. The system may execute an App Intent in a separate
    /// process, so the in-memory published value is not guaranteed to update
    /// until the app becomes active again.
    func reloadPersistedRoute() {
        guard let persistedRoute = Self.loadPersistedRoute(),
              persistedRoute.id != route?.id else {
            return
        }
        route = persistedRoute
    }

    func requestSearch(query: String) {
        let requestedRoute = Route.search(SearchRequest(id: UUID(), query: query))
        lastRequestedRoute = requestedRoute
        route = requestedRoute
        persistRoute()
    }

    func requestOpen(entity: SashimiMediaEntity) {
        let requestedRoute = Route.open(OpenRequest(id: UUID(), entity: entity))
        lastRequestedRoute = requestedRoute
        route = requestedRoute
        persistRoute()
    }

    func requestPlay(entity: SashimiMediaEntity) {
        let requestedRoute = Route.play(PlayRequest(id: UUID(), entity: entity))
        lastRequestedRoute = requestedRoute
        route = requestedRoute
        persistRoute()
    }

    func consume(_ route: Route) {
        guard self.route == route else { return }
        self.route = nil
        clearPersistedRoute()
    }

    /// Playback routes remain persisted until the destination has created a
    /// player. This avoids losing a cold-launch request while the player is
    /// still resolving the server-local item or while SwiftUI is presenting
    /// the full-screen destination.
    func acknowledgePlaybackReady(for entity: SashimiMediaEntity) {
        guard case .play(let request) = route, request.entity == entity else { return }
        consume(.play(request))
    }

    /// A failed handoff is visible in the destination, but it must not be
    /// replayed forever on every scene activation. Clear only the matching
    /// request so a newer intent cannot be discarded by an older destination.
    func acknowledgePlaybackFailure(for entity: SashimiMediaEntity) {
        guard case .play(let request) = route, request.entity == entity else { return }
        consume(.play(request))
    }

    /// Closing a destination before the player becomes ready is a deliberate
    /// cancellation, not a successful handoff.
    func cancelPlayback(for entity: SashimiMediaEntity) {
        acknowledgePlaybackFailure(for: entity)
    }

    /// A search route stays pending until the search surface acknowledges its
    /// handoff. This lets cancellation/disappearance consume the request too,
    /// while an older request can never clear a newer one.
    func consumeSearchRequest(id: UUID) {
        guard case .search(let request) = route, request.id == id else { return }
        route = nil
        clearPersistedRoute()
    }

    private func persistRoute() {
        guard let route,
              let data = try? JSONEncoder().encode(route) else {
            clearPersistedRoute()
            return
        }
        UserDefaults.standard.set(data, forKey: Self.pendingRouteKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Self.routeDidChangeNotification,
            nil,
            nil,
            true
        )
    }

    private func clearPersistedRoute() {
        UserDefaults.standard.removeObject(forKey: Self.pendingRouteKey)
    }

    private static func loadPersistedRoute() -> Route? {
        guard let data = UserDefaults.standard.data(forKey: pendingRouteKey) else {
            return nil
        }
        return try? JSONDecoder().decode(Route.self, from: data)
    }
}
