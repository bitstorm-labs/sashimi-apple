import SwiftUI

/// Shared header component with logo and avatar display
/// Used across all main tabs (Home, Library, Search, Settings)
struct AppHeader: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var showServerSwitcher = false
    @State private var showAddServer = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Logo at left (includes "Sashimi" text)
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 220)
                .padding(.top, -35)

            Spacer()

            // User avatar — click for the server quick-switcher
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
            }
            .buttonStyle(.plain)
            .padding(.trailing, 30)
            .padding(.top, 22)
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
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .horizontal)
    }
}
