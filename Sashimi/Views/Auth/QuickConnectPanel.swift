import SwiftUI

/// The Quick Connect code screen that replaces the login form while a
/// request is running. Cancel holds focus by default; Get New Code / Try
/// Again takes it once the request has ended.
struct QuickConnectPanel: View {
    @ObservedObject var viewModel: QuickConnectViewModel
    var focusedField: FocusState<ServerConnectionField?>.Binding
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 40) {
            Text("Quick Connect")
                .font(.title2.bold())

            content

            Button("Cancel") {
                onCancel()
            }
            .focused(focusedField, equals: .quickConnectCancel)
        }
        .frame(maxWidth: 900)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .requesting:
            status("Getting a code…")
        case .waiting(let code):
            VStack(spacing: 32) {
                Text(QuickConnectViewModel.spaced(code))
                    .font(.system(size: 120, weight: .bold, design: .monospaced))
                    .accessibilityLabel(code.map(String.init).joined(separator: ", "))
                Text("On your phone or computer, open Jellyfin › Profile › Quick Connect and enter this code.")
                    .font(.callout)
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .multilineTextAlignment(.center)
                status("Waiting for approval…")
            }
        case .signingIn, .signedIn:
            status("Signing in…")
        case .expired:
            ended(message: "Code expired", color: .yellow, action: "Get New Code")
        case .failed(let message):
            ended(message: message, color: .red, action: "Try Again")
        }
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: 16) {
            ProgressView()
            Text(text)
                .foregroundStyle(SashimiTheme.textSecondary)
        }
    }

    private func ended(message: String, color: Color, action: String) -> some View {
        VStack(spacing: 24) {
            Text(message)
                .font(.headline)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
            Button(action) {
                viewModel.requestNewCode()
            }
            .focused(focusedField, equals: .quickConnectNewCode)
        }
    }
}
