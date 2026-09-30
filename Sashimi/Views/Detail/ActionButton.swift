import SwiftUI

struct ActionButton: View {
    let title: String
    let icon: String
    var isPrimary: Bool = false
    var isActive: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.subheadline)
            .fontWeight(.semibold)
            .padding(.horizontal, isPrimary ? 24 : 16)
            .padding(.vertical, 10)
            .foregroundStyle(isPrimary ? .black : (isActive ? SashimiTheme.accent : .white))
            .background(
                isPrimary ? AnyShapeStyle(Color.white) : AnyShapeStyle(SashimiTheme.cardBackground)
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 3)
            )
            .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 12)
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isPrimary ? .startsMediaSession : [])
    }
}
