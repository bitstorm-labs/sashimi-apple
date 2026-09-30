import SwiftUI

private struct DetailRootLeadingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Room a tab's root content leaves for the nav rail. Applied to the root
    /// only: a pushed detail page covers the whole screen, rail included.
    var detailRootLeadingInset: CGFloat {
        get { self[DetailRootLeadingInsetKey.self] }
        set { self[DetailRootLeadingInsetKey.self] = newValue }
    }
}

/// A tab's `NavigationStack`, bound to the app's `DetailRouter`, with every
/// detail page registered as a destination.
///
/// Put a tab's lifecycle modifiers (`.task`, `.onAppear`, refresh timers)
/// OUTSIDE this view, never on `root`: the root disappears whenever a page is
/// pushed over it, which would cancel and later re-run that work.
struct DetailNavigationStack<Root: View>: View {
    @EnvironmentObject private var router: DetailRouter
    @Environment(\.detailRootLeadingInset) private var leadingInset
    private let root: Root

    init(@ViewBuilder root: () -> Root) {
        self.root = root()
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            root
                .padding(.leading, leadingInset)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: DetailRoute.self) { route in
                    DetailRouteView(route: route)
                        .toolbar(.hidden, for: .navigationBar)
                }
        }
        // Menu pops one page. At the root it is not handled here, so it falls
        // through to the tab's own handler (back to Home, or suspend the app).
        .onExitCommand(perform: router.isAtRoot ? nil : { router.pop() })
    }
}

/// Builds the page for one route.
struct DetailRouteView: View {
    let route: DetailRoute
    @EnvironmentObject private var router: DetailRouter

    var body: some View {
        switch route.destination {
        case .item(let item, let forceYouTubeStyle, let serverID):
            MediaDetailView(item: item, forceYouTubeStyle: forceYouTubeStyle, serverID: serverID)
        case .person(let person, let context):
            PersonDetailView(
                person: person,
                excludingItemID: context.excludingItemID,
                excludingTitleKey: context.excludingTitleKey,
                originatingServerID: context.originatingServerID,
                onSelectSource: { source in router.push(.serverMedia(source)) }
            )
        case .serverMedia(let source):
            ServerScopedRouteView(route: route, source: source)
        }
    }
}

/// A title that may live on another saved server. The router owns the
/// server-client scope (see `DetailRouter`); this page only waits for it.
///
/// tvOS counterpart of the shared `ServerScopedMediaDetailView`, whose scope
/// is tied to its own `.task` — correct under a cover, but a pushed page's
/// task is cancelled as soon as another page is pushed over it.
private struct ServerScopedRouteView: View {
    let route: DetailRoute
    let source: ServerMediaResult
    @EnvironmentObject private var router: DetailRouter
    @ObservedObject private var sessionManager = SessionManager.shared

    private var serverName: String {
        sessionManager.servers.first(where: { $0.id == source.serverID })?.displayName ?? source.serverName
    }

    private var isYouTubeStyle: Bool {
        source.item.libraryName?.localizedCaseInsensitiveContains("youtube") == true
    }

    var body: some View {
        switch router.scopeState(for: route) {
        case .ready:
            MediaDetailView(item: source.item, forceYouTubeStyle: isYouTubeStyle, serverID: source.serverID)
        case .failed:
            ContentUnavailableView {
                Label("Unable to Open Title", systemImage: "key.slash")
            } description: {
                Text("The saved session for \(serverName) is unavailable. Reconnect this server in Settings, then try again.")
            } actions: {
                Button("Back") { router.pop() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SashimiTheme.background.ignoresSafeArea())
        case .connecting, nil:
            ProgressView("Connecting to \(serverName)...")
                // Focusable so focus has somewhere to rest while connecting.
                // With nothing focusable tvOS re-resolves focus scope-wide
                // (the guide's loading state hit this on device).
                .focusable()
                .focusEffectDisabled()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SashimiTheme.background.ignoresSafeArea())
        }
    }
}
