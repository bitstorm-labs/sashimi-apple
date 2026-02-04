import SwiftUI

@main
struct SashimiMobileApp: App {
    @StateObject private var sessionManager = SessionManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        Group {
            if sessionManager.isAuthenticated {
                MainView()
            } else {
                AuthView()
            }
        }
    }
}

// Placeholder views - will be replaced in later phases
struct MainView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("Home", systemImage: "house")
                Label("Library", systemImage: "rectangle.stack")
                Label("Search", systemImage: "magnifyingglass")
                Label("Settings", systemImage: "gearshape")
            }
            .navigationTitle("Sashimi")
        } detail: {
            Text("Select an item")
                .foregroundStyle(.secondary)
        }
    }
}

struct AuthView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            Text("Sashimi")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Connect to your Jellyfin server")
                .foregroundStyle(.secondary)

            // Placeholder - will be replaced with actual auth flow
            Button("Connect to Server") {
                // Auth flow will be implemented in later phases
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
