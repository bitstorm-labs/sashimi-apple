import NukeUI
import SwiftUI

extension SeerrBadge {
    /// The mockup's colours: purple to request, amber waiting, blue on its
    /// way, red declined, green on the server.
    var color: Color {
        switch self {
        case .request: return Color(red: 185 / 255, green: 153 / 255, blue: 230 / 255)
        case .pending: return Color(red: 242 / 255, green: 193 / 255, blue: 78 / 255)
        case .coming: return Color(red: 92 / 255, green: 173 / 255, blue: 230 / 255)
        case .declined: return Color(red: 226 / 255, green: 100 / 255, blue: 90 / 255)
        case .available: return Color(red: 63 / 255, green: 191 / 255, blue: 127 / 255)
        }
    }
}

extension SeerrRequestState {
    var color: Color {
        switch self {
        case .pending: return SeerrBadge.pending.color
        case .coming: return SeerrBadge.coming.color
        case .ready: return SeerrBadge.available.color
        case .declined, .failed: return SeerrBadge.declined.color
        }
    }
}

/// A status word as a tag: the same outlined, tinted rounded rectangle as
/// the series status and quality badges, sized by the caller (tvOS larger).
struct SeerrStatusTag: View {
    let label: String
    let color: Color
    var fontSize: CGFloat = 12
    /// Over artwork: a dark plate so the word reads on any poster.
    var onArtwork = false

    private var cornerRadius: CGFloat { fontSize / 3 }

    var body: some View {
        Text(label)
            .font(.system(size: fontSize, weight: .heavy))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, fontSize * 0.55)
            .padding(.vertical, fontSize * 0.2)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(onArtwork ? Color.black.opacity(0.65) : color.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
            .accessibilityLabel(label)
    }
}

/// TMDB artwork for a title Seerr knows about, with a quiet placeholder
/// carrying the title while it loads (or when there's no art).
struct SeerrArtwork: View {
    let url: URL?
    let title: String
    var cornerRadius: CGFloat = 8
    var titleFont: Font = .caption.weight(.bold)

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(white: 0.2), Color(white: 0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(title)
                .font(titleFont)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(3)
                .padding(8)
            if let url {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}

/// A YouTube trailer link from Seerr's related videos.
enum SeerrTrailer {
    static func url(key: String) -> URL? {
        #if os(tvOS)
        // The YouTube app; tvOS has no browser to fall back on.
        return URL(string: "youtube://watch/\(key)")
        #else
        return URL(string: "https://www.youtube.com/watch?v=\(key)")
        #endif
    }
}
