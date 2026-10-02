import SwiftUI

/// The wording for each offline state, shared by the banner and the
/// placeholders so the app never describes one outage two ways.
struct OfflineStatusText {
    let status: ConnectionStatus
    let serverName: String?

    var title: String {
        switch status {
        case .serverUnreachable:
            return serverName.map { "Can't reach \($0)" } ?? "Can't reach your server"
        case .noNetwork, .online:
            return "You're offline"
        }
    }

    var icon: String {
        status == .serverUnreachable ? "exclamationmark.icloud" : "wifi.slash"
    }

    @MainActor
    static func current(_ monitor: NetworkMonitor, session: SessionManager) -> OfflineStatusText {
        OfflineStatusText(status: monitor.status, serverName: session.activeServer?.displayName)
    }
}

/// Says why the app is showing downloads only. "Can't reach <server>" offers
/// a retry: the network is fine, so the viewer may know the server is back
/// before the next automatic check.
struct OfflineStatusBanner: View {
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var session = SessionManager.shared

    var body: some View {
        let text = OfflineStatusText.current(networkMonitor, session: session)
        HStack(spacing: MobileSpacing.sm) {
            Image(systemName: text.icon)
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title)
                    .font(.system(size: 15, weight: .semibold))
                Text("Showing your downloads")
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textSecondary)
            }
            Spacer(minLength: MobileSpacing.sm)
            if networkMonitor.status == .serverUnreachable {
                Button("Retry") {
                    networkMonitor.requestProbe()
                }
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
        .foregroundStyle(MobileColors.textPrimary)
        .padding(.horizontal, MobileSpacing.md)
        .padding(.vertical, MobileSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MobileCornerRadius.large, style: .continuous)
                .fill(MobileColors.warning.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileCornerRadius.large, style: .continuous)
                .stroke(MobileColors.warning.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// Stands in for a section that needs the server (iPhone's Libraries and
/// Search tabs) while offline.
struct OfflineUnavailableView: View {
    let title: String
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var session = SessionManager.shared

    var body: some View {
        let text = OfflineStatusText.current(networkMonitor, session: session)
        ContentUnavailableView {
            Label(text.title, systemImage: text.icon)
        } description: {
            Text("\(title) is available when you're back online. Your downloads are on Home and in Downloads.")
        } actions: {
            if networkMonitor.status == .serverUnreachable {
                Button("Retry") {
                    networkMonitor.requestProbe()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MobileColors.background)
        .navigationTitle(title)
    }
}

/// Marks artwork whose watch progress was saved offline and will be sent to
/// the server once it is reachable again.
struct PendingSyncBadge: View {
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(Circle().fill(Color.black.opacity(0.65)))
            .padding(6)
            .accessibilityLabel("Progress will sync when online")
    }
}

extension View {
    /// Overlays `PendingSyncBadge` in the top-leading corner when `pending`.
    func pendingSyncBadge(_ pending: Bool, size: CGFloat = 12) -> some View {
        overlay(alignment: .topLeading) {
            if pending {
                PendingSyncBadge(size: size)
            }
        }
    }
}
