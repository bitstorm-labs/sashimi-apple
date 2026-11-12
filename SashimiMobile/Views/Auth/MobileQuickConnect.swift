import SwiftUI

/// Quick Connect on the iPhone/iPad/Mac sign-in (#901). The polling itself is
/// the shared `QuickConnectViewModel` the tvOS login uses; this is only what
/// the iOS form shows for it.
enum MobileQuickConnect {
    /// Whether the sign-in step offers "Use Quick Connect": once a server is
    /// connected, it has Quick Connect on, and no password sign-in is running.
    static func offersButton(isAvailable: Bool, serverURL: URL?, isSigningIn: Bool) -> Bool {
        isAvailable && serverURL != nil && !isSigningIn
    }

    /// What the code screen shows in one phase.
    struct Content: Equatable {
        enum Tone: Equatable { case normal, warning, error }

        /// The code, spaced so it reads easily ("4 8 2 9 1 7").
        var code: String?
        /// Where to enter the code, shown with it.
        var instructions: String?
        /// A running step, shown with a spinner.
        var status: String?
        /// Why the request ended (expired or failed).
        var message: String?
        var tone: Tone = .normal
        /// The button that starts a fresh request once this one has ended.
        var retryTitle: String?

        @MainActor
        init(phase: QuickConnectViewModel.Phase) {
            switch phase {
            case .idle, .requesting:
                status = "Getting a code…"
            case .waiting(let code):
                self.code = QuickConnectViewModel.spaced(code)
                instructions = "On a device that's already signed in, open Jellyfin › Profile › Quick Connect "
                    + "(in Sashimi: Settings › Sign In a TV) and enter this code."
                status = "Waiting for approval…"
            case .signingIn, .signedIn:
                status = "Signing in…"
            case .expired:
                message = "Code expired"
                tone = .warning
                retryTitle = "Get New Code"
            case .failed(let reason):
                message = reason
                tone = .error
                retryTitle = "Try Again"
            }
        }
    }
}

/// The Quick Connect code screen, as Form sections that replace the
/// credential fields while a request runs.
struct MobileQuickConnectSections: View {
    @ObservedObject var viewModel: QuickConnectViewModel
    var onCancel: () -> Void

    var body: some View {
        let content = MobileQuickConnect.Content(phase: viewModel.phase)
        Group {
            Section {
                if let code = content.code {
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                        .accessibilityLabel(code.replacingOccurrences(of: " ", with: ", "))
                        .accessibilityIdentifier("quickConnectCode")
                        .spansRowSeparator()
                }
                if let status = content.status {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(status)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .spansRowSeparator()
                }
                if let message = content.message {
                    Text(message)
                        .font(.headline)
                        .foregroundStyle(color(for: content.tone))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .spansRowSeparator()
                }
            } footer: {
                if let instructions = content.instructions {
                    Text(instructions)
                }
            }

            Section {
                if let retryTitle = content.retryTitle {
                    Button {
                        viewModel.requestNewCode()
                    } label: {
                        Text(retryTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .spansRowSeparator()
                }
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .frame(maxWidth: .infinity)
                .spansRowSeparator()
            }
        }
    }

    private func color(for tone: MobileQuickConnect.Content.Tone) -> Color {
        switch tone {
        case .normal: .primary
        case .warning: .orange
        case .error: .red
        }
    }
}
