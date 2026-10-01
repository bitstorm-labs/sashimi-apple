import SwiftUI
import NukeUI

struct AsyncItemImage: View {
    let itemId: String
    let imageType: String
    let maxWidth: Int
    var contentMode: ContentMode = .fill
    var fallbackImageTypes: [String] = []
    var serverID: String?

    @State private var currentTypeIndex: Int = 0
    @State private var loadFailed: Bool = false
    @State private var attemptId = UUID()

    private var allImageTypes: [String] {
        [imageType] + fallbackImageTypes
    }

    private var currentURL: URL? {
        guard currentTypeIndex < allImageTypes.count else { return nil }
        return JellyfinClient.shared.syncImageURL(
            itemId: itemId,
            imageType: allImageTypes[currentTypeIndex],
            maxWidth: maxWidth,
            serverURL: resolvedServerURL
        )
    }

    private var resolvedServerURL: URL? {
        guard let serverID else { return nil }
        return SessionManager.shared.servers.first(where: { $0.id == serverID })?.url
    }

    var body: some View {
        Group {
            if loadFailed {
                placeholderView
            } else if let url = currentURL {
                LazyImage(request: SashimiImagePipeline.request(url: url, serverID: serverID)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                    } else if state.error != nil {
                        Color.clear
                            .task(id: attemptId) {
                                advanceToNextType()
                            }
                    } else {
                        Rectangle()
                            .fill(.gray.opacity(0.2))
                            .overlay { ProgressView() }
                    }
                }
                .pipeline(SashimiImagePipeline.shared)
                .id("\(currentTypeIndex)-\(attemptId)")
            } else {
                placeholderView
            }
        }
    }

    private func advanceToNextType() {
        if currentTypeIndex < allImageTypes.count - 1 {
            currentTypeIndex += 1
            attemptId = UUID()
        } else {
            loadFailed = true
        }
    }

    private var placeholderView: some View {
        Rectangle()
            .fill(.gray.opacity(0.3))
            .overlay {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.gray)
            }
    }
}
