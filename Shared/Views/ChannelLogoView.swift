import NukeUI
import SwiftUI

/// A channel's logo from the server (plugin 0.8.0+), or nothing when the
/// channel has none — callers check `logo` so an empty frame never takes room.
struct ChannelLogoView: View {
    let channelId: String
    let logo: String?
    var mono = false
    let size: CGFloat

    @State private var url: URL?

    var body: some View {
        ZStack {
            if let url {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        // The key is part of the URL, so a seasonal swap loads the new logo
        // instead of reusing the cached old one.
        .task(id: logo) {
            guard let logo else {
                url = nil
                return
            }
            url = await JellyfinClient.shared.channelLogoURL(channelId: channelId, key: logo, mono: mono)
        }
    }
}
