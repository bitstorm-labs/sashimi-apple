import SwiftUI
import UIKit

/// The banner for a server's `DisplayMessage` (#723).
struct RemoteMessageBanner: View {
    let message: RemoteMessage

    #if os(tvOS)
    private let headerFont = Font.system(size: 34, weight: .bold)
    private let textFont = Font.system(size: 30, weight: .regular)
    private let maxWidth: CGFloat = 1100
    private let topPadding: CGFloat = 60
    private let padding: CGFloat = 32
    #else
    private let headerFont = Font.headline
    private let textFont = Font.subheadline
    private let maxWidth: CGFloat = 520
    private let topPadding: CGFloat = 12
    private let padding: CGFloat = 16
    #endif

    var body: some View {
        HStack(alignment: .top, spacing: padding * 0.6) {
            Image(systemName: "bubble.left.fill")
                .font(headerFont)
                .foregroundStyle(.white.opacity(0.85))
            VStack(alignment: .leading, spacing: 6) {
                if let header = message.header {
                    Text(header)
                        .font(headerFont)
                        .foregroundStyle(.white)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(textFont)
                        .foregroundStyle(.white.opacity(message.header == nil ? 1 : 0.85))
                }
            }
            .multilineTextAlignment(.leading)
            .lineLimit(6)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(padding)
        .frame(maxWidth: maxWidth)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: padding, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: padding, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .padding(.horizontal, padding)
        .padding(.top, topPadding)
        .accessibilityElement(children: .combine)
    }
}

/// Shows `DisplayMessage` banners in a window of their own above the app, so
/// one lands on top of whatever is up — the player's `fullScreenCover`
/// included, which an overlay on the root view would sit underneath.
///
/// The window never becomes key and takes no touches, so the remote's focus
/// and the player's controls stay where they were.
@MainActor
final class RemoteMessagePresenter {
    static let shared = RemoteMessagePresenter()

    private final class Model: ObservableObject {
        @Published var message: RemoteMessage?
        /// A new message replaces the current one even when identical.
        @Published var revision = 0
    }

    private struct Host: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack {
                if let message = model.message {
                    RemoteMessageBanner(message: message)
                        .id(model.revision)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.3), value: model.revision)
            .animation(.easeInOut(duration: 0.3), value: model.message == nil)
            .allowsHitTesting(false)
        }
    }

    private let model = Model()
    private var window: UIWindow?
    private var hideTask: Task<Void, Never>?

    func show(_ message: RemoteMessage) {
        guard let scene = Self.foregroundScene() else { return }
        let window = window ?? makeWindow(in: scene)
        if window.windowScene !== scene { window.windowScene = scene }
        window.isHidden = false
        model.message = message
        model.revision += 1

        hideTask?.cancel()
        let duration = message.displayDuration
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.model.message = nil
            // Let the banner animate out before the window goes.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, self?.model.message == nil else { return }
            self?.window?.isHidden = true
        }
    }

    private func makeWindow(in scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        let host = UIHostingController(rootView: Host(model: model))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        self.window = window
        return window
    }

    private static func foregroundScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
    }
}
