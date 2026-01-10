import SwiftUI

// MARK: - Empty State View

struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

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
                    Text(actionTitle)
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

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if showBackground {
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(SashimiTheme.progressBackground)
                }

                RoundedRectangle(cornerRadius: height / 2)
                    .fill(SashimiTheme.accent)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: height)
    }
}
