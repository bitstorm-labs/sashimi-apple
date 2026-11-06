#if DEBUG
import SwiftUI

/// Debug builds only: the screen `SASHIMI_SEERR_DEMO` names, against the
/// canned Seerr in `SeerrDemo` (A, A2, B, C, D, E, H).
struct MobileSeerrDemoRoot: View {
    let screen: String
    @State private var ready = false
    @StateObject private var search = SeerrSearchModel()

    var body: some View {
        NavigationStack {
            Group {
                if ready { content } else { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MobileColors.background)
        }
        .seerrRequestsSheet()
        .task {
            await SeerrDemo.start(signedIn: screen != "A")
            if screen == "B" { await search.search(query: "dune", library: []) }
            ready = true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case "A", "A2":
            MobileRequestsSettingsView()
        case "B":
            ScrollView {
                VStack(alignment: .leading, spacing: MobileSpacing.md) {
                    Text("Nothing in your library (demo)")
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textTertiary)
                        .padding(.horizontal, MobileSpacing.md)
                    MobileSeerrSearchRow(title: "Not in your library", items: search.items,
                                         cardWidth: PhoneSizing.posterWidth) { _ in }
                }
            }
            .navigationTitle("Search")
        case "C":
            MobileSeerrDetailView(target: SeerrTarget(kind: .tv, tmdbId: 90228, title: "Dune: Prophecy"))
        case "D":
            MobileSeerrDetailView(target: SeerrTarget(kind: .tv, tmdbId: 90228, title: "Dune: Prophecy"),
                                  opensSeasonPicker: true)
        case "E":
            MobileSeerrRequestsView()
        default:
            ScrollView {
                MobileSeerrHomeRow(cardWidth: PhoneSizing.posterWidth)
            }
            .navigationTitle("Home")
        }
    }
}
#endif
