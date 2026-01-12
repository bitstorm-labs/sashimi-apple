import SwiftUI

/// Shared header component with logo and avatar display
/// Used across all main tabs (Home, Library, Search, Settings)
struct AppHeader: View {
    @EnvironmentObject private var sessionManager: SessionManager

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Logo at left (includes "Sashimi" text)
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 270)
                .padding(.top, -30)

            Spacer()

            // User avatar - display only
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
            .padding(.trailing, 50)
            .padding(.top, 30)
        }
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .horizontal)
    }
}
