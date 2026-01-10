import SwiftUI

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let type: ToastType
    let duration: TimeInterval

    enum ToastType {
        case error
        case warning
        case info
        case success

        var icon: String {
            switch self {
            case .error: return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.circle.fill"
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .error: return SashimiTheme.error
            case .warning: return SashimiTheme.warning
            case .info: return SashimiTheme.accent
            case .success: return SashimiTheme.success
            }
        }
    }

    init(message: String, type: ToastType = .error, duration: TimeInterval = 4.0) {
        self.message = message
        self.type = type
        self.duration = duration
    }

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class ToastManager: ObservableObject {
    static let shared = ToastManager()

    @Published var currentToast: ToastMessage?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String, type: ToastMessage.ToastType = .error, duration: TimeInterval = 4.0) {
        dismissTask?.cancel()
        currentToast = ToastMessage(message: message, type: type, duration: duration)

        dismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.3)) {
                    currentToast = nil
                }
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.3)) {
            currentToast = nil
        }
    }
}

struct ToastView: View {
    let toast: ToastMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: toast.type.icon)
                .font(.system(size: 24))
                .foregroundStyle(toast.type.color)

            Text(toast.message)
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.15))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        )
        .padding(.horizontal, 60)
    }
}

struct ToastModifier: ViewModifier {
    @ObservedObject var toastManager = ToastManager.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = toastManager.currentToast {
                    ToastView(toast: toast, onDismiss: { toastManager.dismiss() })
                        .padding(.top, 40)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toastManager.currentToast)
                        .zIndex(1000)
                }
            }
    }
}

extension View {
    func toastOverlay() -> some View {
        modifier(ToastModifier())
    }
}
