import AppIntents
import NukeUI
import SwiftUI

#if compiler(>=6.4)
/// The interactive Siri result surface. Every poster is a real App Intent
/// button, so tapping a result invokes the server-aware OpenIntent and lands on
/// that title's Sashimi detail page.
@available(iOS 27.0, *)
struct SashimiSearchResultsSnippetIntent: SnippetIntent {
    static var title: LocalizedStringResource {
        "Sashimi Search Results"
    }

    static var isDiscoverable: Bool { false }

    @Parameter(title: "Results")
    var results: [SashimiMediaEntity]

    init() {
        results = []
    }

    init(results: [SashimiMediaEntity]) {
        self.results = results
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        .result(view: SashimiMediaResultsSnippet(heading: "Search Results", results: results))
    }
}

@available(iOS 27.0, *)
struct SashimiSearchResultsSnippet: View {
    let results: [SashimiMediaEntity]

    var body: some View {
        SashimiMediaResultsSnippet(heading: "Search Results", results: results)
    }
}

@available(iOS 27.0, *)
struct SashimiLatestAdditionsSnippetIntent: SnippetIntent {
    static var title: LocalizedStringResource {
        "Sashimi Latest Additions"
    }

    static var isDiscoverable: Bool { false }

    @Parameter(title: "Results")
    var results: [SashimiMediaEntity]

    init() {
        results = []
    }

    init(results: [SashimiMediaEntity]) {
        self.results = results
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        .result(view: SashimiMediaResultsSnippet(heading: "Latest Additions", results: results))
    }
}

@available(iOS 27.0, *)
struct SashimiMediaResultsSnippet: View {
    let heading: String
    let results: [SashimiMediaEntity]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(heading, systemImage: "play.rectangle.fill")
                .font(.headline)

            if results.isEmpty {
                Text("No matching titles")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(results.prefix(6))) { entity in
                            Button(intent: SashimiOpenMediaIntent(target: entity)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    SashimiIntentPosterView(entity: entity)
                                    Text(entity.title)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(width: 108, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16)
    }
}

@available(iOS 27.0, *)
private struct SashimiIntentPosterView: View {
    let entity: SashimiMediaEntity
    @ObservedObject private var sessionManager = SessionManager.shared

    private var imageURL: URL? {
        guard let serverURL = sessionManager.servers.first(where: { $0.id == entity.serverID })?.url else {
            return nil
        }
        return serverURL
            .appendingPathComponent("Items/\(entity.itemID)/Images/Primary")
            .appending(queryItems: [
                URLQueryItem(name: "maxWidth", value: "400"),
                URLQueryItem(name: "quality", value: "90")
            ])
    }

    var body: some View {
        Group {
            if let imageURL {
                LazyImage(request: SashimiImagePipeline.request(url: imageURL, serverID: entity.serverID)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 108, height: 152)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var placeholder: some View {
        Image(systemName: "play.rectangle")
            .font(.title2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
