import SwiftUI

/// DownloadManager's toast ("Downloading 6 episodes...", "Will download on
/// Wi-Fi"), shown at the top for three seconds. Tapping it opens Downloads.
struct DownloadToastModifier: ViewModifier {
    @ObservedObject private var downloadManager = DownloadManager.shared
    let onTap: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message = downloadManager.toastMessage {
                    Button {
                        onTap()
                        downloadManager.toastMessage = nil
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(message)
                                .font(MobileTypography.body)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation {
                                downloadManager.toastMessage = nil
                            }
                        }
                    }
                }
            }
            .animation(.easeInOut, value: downloadManager.toastMessage)
    }
}

extension View {
    func downloadToast(onTap: @escaping () -> Void) -> some View {
        modifier(DownloadToastModifier(onTap: onTap))
    }
}
