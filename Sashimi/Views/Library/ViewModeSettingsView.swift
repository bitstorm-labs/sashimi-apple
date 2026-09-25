import SwiftUI

/// Settings > Playback > Default View Mode: the mode every video opens in
/// unless one was picked in the player this session.
struct ViewModeSettingsView: View {
    @ObservedObject private var viewModes = VideoViewModeStore.shared

    var body: some View {
        SettingsContainer {
            VStack(alignment: .leading, spacing: 16) {
                Text("Default View Mode")
                    .font(Typography.headline)
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .padding(.bottom, 8)

                Text("How the picture fills the screen when a video starts. Change it for one session from View Mode in the player.")
                    .font(Typography.caption)
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .padding(.bottom, 16)

                ForEach(VideoViewMode.allCases) { mode in
                    SettingsPickerOptionRow(
                        title: mode.displayName,
                        subtitle: Self.summary(for: mode),
                        isSelected: viewModes.defaultMode == mode
                    ) {
                        viewModes.setDefault(mode)
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
    }

    private static func summary(for mode: VideoViewMode) -> String {
        switch mode {
        case .normal: return "The whole picture at its own shape"
        case .zoom: return "Fills the screen; crops the edges"
        case .stretch: return "Fills the screen; distorts the picture"
        }
    }
}
