#if DEBUG
import SwiftUI

/// Debug builds only: the screen `SASHIMI_SEERR_DEMO` names, against the
/// canned Seerr in `SeerrDemo` (A, A2, B, C, D, E, H).
struct SeerrDemoRoot: View {
    let screen: String
    @State private var ready = false
    @State private var plan: SeerrSeasonPlan?
    @StateObject private var search = SeerrSearchModel()

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()
            if ready { content }
        }
        .task {
            await SeerrDemo.start(signedIn: screen != "A")
            if screen == "A" { SeerrSession.shared.startPlexCodeSignIn() }
            if screen == "B" { await search.search(query: "dune", library: []) }
            if screen == "D", let details = try? await SeerrSession.shared.client?.details(kind: .tv, tmdbId: 77) {
                plan = SeerrSeasonPlan(details: details)
            }
            ready = true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case "A", "A2":
            RequestsSettingsView()
        case "B":
            VStack(alignment: .leading, spacing: 40) {
                Text("Nothing in your library for \u{201C}dune\u{201D} (demo)")
                    .font(.subheadline)
                    .foregroundStyle(SashimiTheme.textTertiary)
                    .padding(.horizontal, 60)
                SeerrSearchRow(title: search.sectionTitle, items: search.items) { _ in }
                Spacer()
            }
            .padding(.top, 60)
        case "C":
            SeerrDetailView(target: SeerrTarget(kind: .tv, tmdbId: 90228, title: "Dune: Prophecy"))
        case "D":
            if let plan {
                SeerrSeasonPickerView(title: "Love Is Blind", plan: plan) { _ in } onCancel: {}
            }
        case "E":
            SeerrRequestsView()
        default:
            VStack {
                Spacer()
                SeerrHomeSection { _ in }
                Spacer()
            }
        }
    }
}
#endif
