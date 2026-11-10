import SwiftUI

/// The plex.tv/link code, as the Plex app shows it. Settings › Requests and
/// the Watchlist's Connect Plex show the same screen; each adds its own Cancel.
struct PlexCodePanel: View {
    let code: String

    var body: some View {
        VStack(spacing: 20) {
            Text("On your phone or computer, go to")
                .font(Typography.bodySmall.weight(.semibold))
                .foregroundStyle(SashimiTheme.textSecondary)
            Text("plex.tv/link")
                .font(Typography.headline)
                .foregroundStyle(SashimiTheme.textPrimary)
            Text("and enter")
                .font(Typography.bodySmall.weight(.semibold))
                .foregroundStyle(SashimiTheme.textSecondary)
            Text(code)
                .font(.system(size: 96, weight: .medium, design: .monospaced))
                .kerning(24)
                .foregroundStyle(SashimiTheme.textPrimary)
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
            Text("Waiting… this screen continues on its own.")
                .font(Typography.caption)
                .foregroundStyle(SashimiTheme.textTertiary)
        }
    }
}
