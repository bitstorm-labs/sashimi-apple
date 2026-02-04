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
                MainNavigationView()
            } else {
                MobileAuthView()
            }
        }
        .task {
            await sessionManager.restoreSession()
        }
    }
}
