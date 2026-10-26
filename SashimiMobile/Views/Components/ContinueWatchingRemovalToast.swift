import SwiftUI

/// "Removed from Continue Watching — Undo" (#742), at the top of Home for a few
/// seconds after a card is removed. Drawn like the download toast.
struct ContinueWatchingRemovalToastModifier: ViewModifier {
    @ObservedObject var viewModel: HomeViewModel

    /// Long enough to reach Undo, short enough not to linger over the rows.
    private static let visibleFor: Duration = .seconds(5)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice = viewModel.removalNotice {
                    toast(notice)
                        .padding(.top, 60)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: notice.message + (notice.receipt?.item.id ?? "")) {
                            try? await Task.sleep(for: Self.visibleFor)
                            guard !Task.isCancelled else { return }
                            withAnimation { viewModel.removalNotice = nil }
                        }
                }
            }
            .animation(.easeInOut, value: viewModel.removalNotice)
    }

    private func toast(_ notice: ContinueWatchingRemovalNotice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: notice.receipt == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(notice.message)
                .font(MobileTypography.body)
                .lineLimit(1)
            if let receipt = notice.receipt {
                Button("Undo") {
                    Task { await viewModel.undoRemoval(receipt) }
                }
                .font(MobileTypography.body.weight(.semibold))
                .foregroundStyle(MobileColors.accent)
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .padding(.horizontal, MobileSpacing.md)
    }
}

extension View {
    func continueWatchingRemovalToast(_ viewModel: HomeViewModel) -> some View {
        modifier(ContinueWatchingRemovalToastModifier(viewModel: viewModel))
    }
}
