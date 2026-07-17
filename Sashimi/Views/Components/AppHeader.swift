import SwiftUI

/// Shared header with the logo and avatar. Purely decorative: the avatar is
/// an identity anchor, not a button — server switching lives in
/// Settings > Servers. Keeping the header out of the focus chain means
/// swiping up from content lands directly on the tab bar (issue #235).
struct AppHeader: View {
    @EnvironmentObject private var sessionManager: SessionManager

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Logo at left (includes "Sashimi" text)
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 220)
                .padding(.top, -35)

            Spacer()

            // User avatar (display only)
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [SashimiTheme.accent, SashimiTheme.accent.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 70, height: 70)

                if let userId = sessionManager.currentUser?.id,
                   let imageURL = JellyfinClient.shared.userImageURL(userId: userId) {
                    AsyncImage(url: imageURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "person.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 70, height: 70)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                }
            }
            .shadow(color: SashimiTheme.accent.opacity(0.3), radius: 8)
            .padding(.trailing, 30)
            .padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .horizontal)
        .zIndex(1)
    }
}
