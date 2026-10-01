import SwiftUI

/// Marks an item that is downloaded on this device: a download arrow in the
/// artwork's bottom-right corner, opposite the watched check (top-right), so a
/// show's episode list says what is already here.
struct OfflineIndicator: ViewModifier {
    let itemId: String
    var serverID: String?
    var size: CGFloat = 16
    @ObservedObject private var downloadManager = DownloadManager.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if downloadManager.isDownloaded(itemId: itemId, serverID: serverID) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: size))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 2)
                    // Clear of the progress bar along the bottom edge.
                    .padding(.trailing, 6)
                    .padding(.bottom, 8)
                    .accessibilityLabel("Downloaded")
            }
        }
    }
}

extension View {
    func offlineIndicator(itemId: String, serverID: String? = nil, size: CGFloat = 16) -> some View {
        modifier(OfflineIndicator(itemId: itemId, serverID: serverID, size: size))
    }
}
