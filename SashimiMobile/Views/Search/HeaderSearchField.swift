import SwiftUI

/// The iPad Search tab's query field, drawn inside MainNavigationView's header
/// bar so the tab has one chrome bar like every other tab (#126). Styled after
/// the system search field: magnifying glass, placeholder, clear button.
struct HeaderSearchField: View {
    static let placeholder = "Movies, shows, people…"
    /// Matches the header's avatar so the bar keeps its height.
    static let height: CGFloat = 40

    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MobileColors.textTertiary)
                .accessibilityHidden(true)

            TextField(
                "Search",
                text: $text,
                prompt: Text(Self.placeholder).foregroundStyle(MobileColors.textTertiary)
            )
            .font(.system(size: 17))
            .foregroundStyle(MobileColors.textPrimary)
            .tint(MobileColors.accent)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused(isFocused)
            .onSubmit(onSubmit)

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(MobileColors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(MobileColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.large, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { isFocused.wrappedValue = true }
    }
}
