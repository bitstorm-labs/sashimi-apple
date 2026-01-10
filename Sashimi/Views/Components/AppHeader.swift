import SwiftUI

/// Shared header component with logo and profile avatar
/// Used across all main tabs (Home, Library, Search)
struct AppHeader: View {
    @Binding var showProfile: Bool
    @EnvironmentObject private var sessionManager: SessionManager
    @FocusState private var avatarFocused: Bool

    var body: some View {
        HStack {
            // Logo at left
            HStack(spacing: 16) {
                Image("Logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 100)

                Text("Sashimi")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(SashimiTheme.textPrimary)
            }

            Spacer()

            // Profile avatar at right
            Button {
                showProfile = true
            } label: {
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
                        .frame(width: 62, height: 62)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                    }
                }
                .overlay(
                    Circle()
                        .stroke(SashimiTheme.accent.opacity(avatarFocused ? 1.0 : 0), lineWidth: 3)
                )
                .shadow(color: SashimiTheme.accent.opacity(avatarFocused ? 0.6 : 0.2), radius: avatarFocused ? 12 : 6)
                .scaleEffect(avatarFocused ? 1.1 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: avatarFocused)
            }
            .buttonStyle(.card)
            .focused($avatarFocused)
            .accessibilityLabel(sessionManager.currentUser?.name ?? "Profile")
            .accessibilityHint("Double-tap to open profile settings")
        }
        .padding(.horizontal, 80)
        .padding(.top, 40)
        .padding(.bottom, 20)
    }
}
