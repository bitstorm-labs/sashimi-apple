import SwiftUI

struct MobilePlayerLoadingView: View {
    @ObservedObject var viewModel: PlayerViewModel
    /// Nil when there is nothing to retry against (a local file).
    var onRetry: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15))
                    .clipShape(Circle())
            }
            .padding(20)

            VStack(spacing: 16) {
                if viewModel.isLoading {
                    ProgressView().scaleEffect(1.5)
                    Text(viewModel.playbackNotice ?? "Loading...").foregroundStyle(.white)
                } else if let errorMessage = viewModel.errorMessage {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    Text(errorMessage)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                    HStack(spacing: 12) {
                        if let onRetry {
                            Button("Try Again", action: onRetry)
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Dismiss", action: onClose)
                            .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}
