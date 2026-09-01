import SwiftUI

struct DefaultServerBadge: View {
    let tint: Color
    let font: Font

    init(tint: Color, font: Font = .caption2) {
        self.tint = tint
        self.font = font
    }

    var body: some View {
        Text("Default")
            .font(font.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(tint.opacity(0.45), lineWidth: 0.5)
            }
            .accessibilityLabel("Default server")
    }
}
