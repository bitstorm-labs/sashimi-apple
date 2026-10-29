import SwiftUI

/// Settings › Server Plugins on tvOS: which of the plugins Sashimi uses the
/// connected server has, and for admins their version and Jellyfin status.
/// Settings owns the model (it already loaded it for the row's subtitle).
struct ServerPluginsView: View {
    @ObservedObject var model: ServerPluginsViewModel
    @EnvironmentObject private var sessionManager: SessionManager
    /// Each state swap removes whatever held focus (the loading message, the
    /// error row); re-resolving inside this scope keeps focus on this screen
    /// instead of letting tvOS fall back to the rail.
    @Namespace private var focusNamespace
    @Environment(\.resetFocus) private var resetFocus

    init(model: ServerPluginsViewModel) {
        self.model = model
    }

    var body: some View {
        SettingsContainer {
            VStack(alignment: .leading, spacing: 24) {
                header

                switch model.state {
                case .idle, .loading:
                    ServerFocusableMessage(icon: "puzzlepiece.extension", title: "Asking the server…")
                        .prefersDefaultFocus(in: focusNamespace)
                case .failed:
                    ServerPluginsErrorRow(serverName: ServerPluginsViewModel.serverName(for: sessionManager)) {
                        Task { await model.refresh(for: sessionManager) }
                    }
                    .prefersDefaultFocus(in: focusNamespace)
                case .loaded(let report):
                    rows(report)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
        }
        .focusScope(focusNamespace)
        .onChange(of: model.state) { _, _ in
            resetFocus(in: focusNamespace)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Server Plugins")
                    .font(Typography.headline)
                    .foregroundStyle(SashimiTheme.textPrimary)
                if case .loaded(let report) = model.state {
                    Text(report.serverLine)
                        .font(Typography.bodySmall)
                        .foregroundStyle(SashimiTheme.textSecondary)
                }
            }
            Spacer()
            ServerPluginsRefreshButton(isBusy: model.state == .loading) {
                Task { await model.refresh(for: sessionManager) }
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func rows(_ report: ServerPluginsReport) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(report.rows.enumerated()), id: \.element.id) { index, row in
                ServerPluginRowView(row: row, showsVersion: report.isAdministrator)
                    .prefersDefaultFocus(index == 0, in: focusNamespace)
            }
        }
        if !report.isAdministrator {
            Text("Versions are visible to server admins.")
                .font(Typography.caption)
                .foregroundStyle(SashimiTheme.textTertiary)
                .padding(.leading, 8)
        }
    }
}

/// One plugin: name, version, status badge, and what it powers or what breaks.
/// Focusable so the remote can walk the list (and the page scrolls with it);
/// selecting it does nothing.
struct ServerPluginRowView: View {
    let row: ServerPluginRow
    let showsVersion: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {} label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(row.plugin.title)
                        .font(Typography.titleSmall)
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 16)
                    if showsVersion {
                        Text(row.version ?? (row.badge == .notInstalled ? "—" : ""))
                            .font(Typography.bodySmall.monospacedDigit())
                            .foregroundStyle(SashimiTheme.textSecondary)
                            .frame(width: 130, alignment: .leading)
                    }
                    ServerPluginBadge(badge: row.badge)
                        .frame(width: showsVersion ? 280 : 420, alignment: .leading)
                }
                Text(row.detail)
                    .font(Typography.caption)
                    .foregroundStyle(isFocused ? SashimiTheme.textPrimary.opacity(0.85) : SashimiTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = row.providerLine {
                    Text(line)
                        .font(Typography.captionSmall)
                        .foregroundStyle(SashimiTheme.textSecondary)
                        .padding(.leading, 24)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusHighlight(isFocused, cornerRadius: 14)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityElement(children: .combine)
    }
}

/// "● Active", "▲ Restart needed", "– Only an admin can check this".
struct ServerPluginBadge: View {
    let badge: PluginRowBadge

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: badge.symbolName)
                .font(Typography.captionSmall)
                .foregroundStyle(badge.tone.color)
            Text(badge.label)
                .font(Typography.bodySmall)
                .foregroundStyle(badge.tone == .neutral ? SashimiTheme.textSecondary : SashimiTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

struct ServerPluginsRefreshButton: View {
    let isBusy: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        // Not `.disabled` while busy: a disabled button drops focus mid-press.
        Button {
            if !isBusy { action() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise")
                Text("Refresh")
            }
            .font(Typography.bodySmall.weight(.medium))
            .foregroundStyle(isFocused ? .white : SashimiTheme.textSecondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .focusHighlight(isFocused, cornerRadius: 24)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}

/// The network-failure row: the server couldn't be asked, which says nothing
/// about its plugins, so no row claims "not installed".
struct ServerPluginsErrorRow: View {
    let serverName: String
    let retry: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: retry) {
            HStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Typography.title)
                    .foregroundStyle(SashimiTheme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't reach \(serverName)")
                        .font(Typography.titleSmall)
                        .foregroundStyle(SashimiTheme.textPrimary)
                    Text("Plugin status is unknown until it answers. Select to try again.")
                        .font(Typography.caption)
                        .foregroundStyle(isFocused ? SashimiTheme.textPrimary.opacity(0.85) : SashimiTheme.textTertiary)
                }
                Spacer()
                Text("Retry")
                    .font(Typography.bodySmall.weight(.semibold))
                    .foregroundStyle(SashimiTheme.textPrimary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusHighlight(isFocused, cornerRadius: 14)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}

#if DEBUG
/// Admin view from fixture data (the device test account is not an admin).
private struct ServerPluginsPreviewClient: ServerPluginsClient {
    func getInstalledPlugins() async throws -> [InstalledPluginInfo] {
        [
            InstalledPluginInfo(name: "Sashimi Lists", version: "0.1.0", status: .active, id: "d95b448462cb487392c566a65b86b420"),
            InstalledPluginInfo(name: "Channels", version: "0.11.0", status: .restart, id: "7a3f1c925d644b089f216c8e5b0a4d73"),
            InstalledPluginInfo(name: "Continue Watching", version: "0.2.0", status: .malfunctioned, id: "a286cbd2ce2246adad0fd49491cce52a"),
            InstalledPluginInfo(name: "Intro Skipper", version: "12.0.6", status: .active, id: "c83d86bba1e04c35a113e2101cf4ee6b"),
            InstalledPluginInfo(name: "TheIntroDB", version: "1.3.0", status: .active, id: "c9e41b9563e445e29db6b83df21ae5e7"),
            InstalledPluginInfo(name: "Segment Editor", version: "12.0.20", status: .active, id: "ace21d44a4e54a85ae75acd2e24a9574")
        ]
    }

    func probePluginRoute(path: String, query: [URLQueryItem]) async -> PluginProbeResult {
        path == "/ContinueWatching" ? .notDetected : .detected
    }

    func getPublicServerInfo() async throws -> DashboardSystemInfo {
        DashboardSystemInfo(serverName: "popcorn", version: "12.4.0")
    }
}

private struct ServerPluginsPreview: View {
    let isAdmin: Bool
    @StateObject private var model: ServerPluginsViewModel

    init(isAdmin: Bool) {
        self.isAdmin = isAdmin
        _model = StateObject(wrappedValue: ServerPluginsViewModel(client: ServerPluginsPreviewClient()))
    }

    var body: some View {
        ServerPluginsView(model: model)
            .environmentObject(SessionManager.shared)
            .task { await model.refresh(key: "preview", isAdministrator: isAdmin, fallbackServerName: "popcorn") }
    }
}

#Preview("Admin") { ServerPluginsPreview(isAdmin: true) }
#Preview("Non-admin") { ServerPluginsPreview(isAdmin: false) }
#endif
