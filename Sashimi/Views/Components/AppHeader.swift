import SwiftUI

/// Accessories rendered on the same row as the native tab bar: a compact
/// decorative logo at the left edge and the avatar (server quick-switcher)
/// at the right. Replaces the old full-height AppHeader that lived above
/// the tab bar and forced an extra focus hop (issue #235).
struct TabBarAccessories: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var showServerSwitcher = false
    @State private var showAddServer = false

    var body: some View {
        HStack(alignment: .center) {
            // Logo at left (decorative, never focusable)
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 100)
                .focusable(false)

            Spacer()

            // Avatar — sits at the right end of the tab bar row so a single
            // rightward swipe from the last tab reaches it
            Button {
                showServerSwitcher = true
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
                        .frame(width: 58, height: 58)

                    if let userId = sessionManager.currentUser?.id,
                       let imageURL = JellyfinClient.shared.userImageURL(userId: userId) {
                        AsyncImage(url: imageURL) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "person.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 58, height: 58)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                    }
                }
                .shadow(color: SashimiTheme.accent.opacity(0.3), radius: 8)
            }
            .buttonStyle(.plain)
            .confirmationDialog("Switch Server", isPresented: $showServerSwitcher, titleVisibility: .visible) {
                ForEach(sessionManager.servers) { server in
                    Button(server.id == sessionManager.activeServerId ? "✓ \(server.name)" : server.name) {
                        Task { await sessionManager.switchServer(to: server.id) }
                    }
                }
                Button("Add Server…") { showAddServer = true }
                Button("Cancel", role: .cancel) {}
            }
            .fullScreenCover(isPresented: $showAddServer) {
                AddServerSheet()
            }
        }
        .padding(.horizontal, 60)
        .padding(.top, 30)
        // Own focus section beside the tab bar; content below is unaffected.
        .focusSection()
    }
}
