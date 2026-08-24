import SwiftUI
import NukeUI

// Smart image that tries multiple item IDs until one works
// For each item ID, tries specified image types in order
struct SmartPosterImage: View {
    let itemIds: [String]
    let maxWidth: Int
    var imageTypes: [String] = ["Primary", "Thumb"]
    var contentMode: ContentMode = .fill
    var serverURL: URL?
    var serverID: String?

    @State private var currentIndex: Int = 0
    @State private var currentTypeIndex: Int = 0
    @State private var loadFailed: Bool = false
    @State private var attemptId = UUID()

    private var currentURL: URL? {
        guard currentIndex < itemIds.count, currentTypeIndex < imageTypes.count else { return nil }
        return JellyfinClient.shared.syncImageURL(
            itemId: itemIds[currentIndex],
            imageType: imageTypes[currentTypeIndex],
            maxWidth: maxWidth,
            serverURL: resolvedServerURL
        )
    }

    private var resolvedServerURL: URL? {
        if let serverURL { return serverURL }
        guard let serverID else { return nil }
        return SessionManager.shared.servers.first(where: { $0.id == serverID })?.url
    }

    private var currentRequest: ImageRequest? {
        guard let currentURL else { return nil }
        return SashimiImagePipeline.request(url: currentURL, serverID: serverID)
    }

    var body: some View {
        Group {
            if loadFailed {
                placeholderView
            } else if currentRequest != nil {
                LazyImage(request: currentRequest) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                    } else if state.error != nil {
                        Color.clear
                            .task(id: attemptId) {
                                advanceToNext()
                            }
                    } else {
                        Rectangle()
                            .fill(.gray.opacity(0.2))
                            .overlay { ProgressView() }
                    }
                }
                .pipeline(SashimiImagePipeline.shared)
                .id("\(currentIndex)-\(currentTypeIndex)-\(attemptId)")
            } else {
                placeholderView
            }
        }
    }

    private func advanceToNext() {
        // Add small delay before fallback to allow slow images to load
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                // Try next image type for current item
                if currentTypeIndex < imageTypes.count - 1 {
                    currentTypeIndex += 1
                    attemptId = UUID()
                    return
                }

                // Move to next item ID, reset to first image type
                if currentIndex < itemIds.count - 1 {
                    currentIndex += 1
                    currentTypeIndex = 0
                    attemptId = UUID()
                } else {
                    loadFailed = true
                }
            }
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
