import SwiftUI
import NukeUI

struct CastCard: View {
    let person: PersonInfo
    let serverID: String?
    let action: () -> Void
    @FocusState private var isFocused: Bool

    private var imageURL: URL? {
        guard person.primaryImageTag != nil else { return nil }
        let serverURL = serverID.flatMap { id in
            SessionManager.shared.servers.first(where: { $0.id == id })?.url
        } ?? SessionManager.shared.serverURL
        return JellyfinClient.shared.personImageURL(
            personId: person.id,
            maxWidth: 200,
            serverURL: serverURL
        )
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if let imageURL {
                    LazyImage(request: SashimiImagePipeline.request(url: imageURL, serverID: serverID)) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                        } else {
                            Circle().fill(SashimiTheme.cardBackground)
                        }
                    }
                    .pipeline(SashimiImagePipeline.shared)
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 3)
                    )
                } else {
                    Circle()
                        .fill(SashimiTheme.cardBackground)
                        .frame(width: 100, height: 100)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(SashimiTheme.textTertiary)
                        }
                        .overlay(
                            Circle()
                                .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 3)
                        )
                }

                MarqueeText(
                    text: person.name,
                    isScrolling: isFocused,
                    height: 32,
                    pingPong: true
                )
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)

                if let role = person.displayRole {
                    MarqueeText(
                        text: role,
                        isScrolling: isFocused,
                        height: 28,
                        startDelay: 2.0,
                        pingPong: true
                    )
                    .font(.caption2)
                    .foregroundStyle(SashimiTheme.textTertiary)
                }
            }
            .frame(width: 140)
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(person.displayRole.map { "\(person.name), \($0)" } ?? person.name)
        .accessibilityHint("Show other movies and shows with this person")
    }
}
