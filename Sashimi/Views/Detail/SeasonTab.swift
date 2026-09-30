import SwiftUI

struct SeasonTab: View {
    let season: BaseItemDto
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(season.name)
                .font(.system(size: 24))
                .fontWeight(isSelected ? .bold : .medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    isSelected || isFocused ? Color(red: 0.28, green: 0.35, blue: 0.45) : SashimiTheme.cardBackground
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isFocused ? Color.white.opacity(0.5) : .clear, lineWidth: 3)
                )
                .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 10)
                .scaleEffect(isFocused ? 1.05 : 1.0)
                .animation(.spring(response: 0.3), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel("\(season.name)\(isSelected ? ", selected" : "")")
        .accessibilityHint("Double-tap to show episodes")
    }
}
