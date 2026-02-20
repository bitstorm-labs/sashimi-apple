import SwiftUI

struct OfflineIndicator: ViewModifier {
    let itemId: String
    @ObservedObject private var downloadManager = DownloadManager.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if downloadManager.isDownloaded(itemId: itemId) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 2)
                    .padding(6)
            }
        }
    }
}

extension View {
    func offlineIndicator(itemId: String) -> some View {
        modifier(OfflineIndicator(itemId: itemId))
    }
}
