import SwiftUI

// MARK: - Empty State View

struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    @FocusState private var isButtonFocused: Bool

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(SashimiTheme.textTertiary)

            Text(title)
                .font(Typography.headline)
                .foregroundStyle(SashimiTheme.textPrimary)
                .multilineTextAlignment(.center)

            if let message = message {
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text(actionTitle)
                    }
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isButtonFocused ? .black : .white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(isButtonFocused ? Color.white : SashimiTheme.cardBackground)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(isButtonFocused ? SashimiTheme.accent : .clear, lineWidth: 3)
                    )
                    .shadow(color: isButtonFocused ? SashimiTheme.focusGlow : .clear, radius: 12)
                    .scaleEffect(isButtonFocused ? 1.05 : 1.0)
                    .animation(.spring(response: 0.3), value: isButtonFocused)
                }
                .buttonStyle(PlainNoHighlightButtonStyle())
                .focused($isButtonFocused)
                .padding(.top, Spacing.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }
}

// MARK: - Error State View

struct ErrorStateView: View {
    let title: String
    var message: String?
    var retryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(SashimiTheme.warning)

            Text(title)
                .font(Typography.headline)
                .foregroundStyle(SashimiTheme.textPrimary)
                .multilineTextAlignment(.center)

            if let message = message {
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            if let retryAction = retryAction {
                Button(action: retryAction) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "arrow.clockwise")
                        Text("Try Again")
                    }
                    .font(Typography.titleSmall)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(SashimiTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
                }
                .buttonStyle(.plain)
                .padding(.top, Spacing.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }
}

// MARK: - Loading State View

struct LoadingStateView: View {
    var message: String?

    var body: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .scaleEffect(1.5)

            if let message = message {
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Offline State View

struct OfflineStateView: View {
    var retryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 64))
                .foregroundStyle(SashimiTheme.textTertiary)

            Text("No Connection")
                .font(Typography.headline)
                .foregroundStyle(SashimiTheme.textPrimary)

            Text("Check your internet connection and try again")
                .font(Typography.body)
                .foregroundStyle(SashimiTheme.textSecondary)
                .multilineTextAlignment(.center)

            if let retryAction = retryAction {
                Button(action: retryAction) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .font(Typography.titleSmall)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(SashimiTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
                }
                .buttonStyle(.plain)
                .padding(.top, Spacing.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }
}

// MARK: - Branded Loading Overlay

struct BrandedLoadingOverlay: View {
    var body: some View {
        ZStack {
            SashimiTheme.overlay
                .ignoresSafeArea()

            VStack(spacing: Spacing.md) {
                Image("SashimiLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)

                ProgressView()
                    .scaleEffect(1.2)
            }
        }
    }
}

// MARK: - Progress Bar

struct SashimiProgressBar: View {
    let progress: Double
    var height: CGFloat = 4
    var showBackground: Bool = true
    var useGradient: Bool = false
    var accessibilityLabelPrefix: String = "Progress"

    private var accessibilityText: String {
        let percent = Int(min(max(progress, 0), 1) * 100)
        return "\(accessibilityLabelPrefix): \(percent) percent"
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if showBackground {
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(SashimiTheme.progressBackground)
                }

                RoundedRectangle(cornerRadius: height / 2)
                    .fill(progressFill)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue("\(Int(progress * 100)) percent")
    }

    private var progressFill: AnyShapeStyle {
        if useGradient {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [SashimiTheme.accent, SashimiTheme.accent.opacity(0.7)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        } else {
            return AnyShapeStyle(SashimiTheme.accent)
        }
    }
}
