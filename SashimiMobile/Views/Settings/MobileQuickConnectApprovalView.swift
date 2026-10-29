import SwiftUI

/// Settings › Sign In a TV on iPhone, iPad and Mac (#801): type the six-digit
/// Quick Connect code a TV shows and approve it with this device's session.
/// Settings owns the model (it already asked whether to show the row).
struct MobileQuickConnectApprovalView: View {
    @ObservedObject var model: QuickConnectApprovalViewModel
    let userName: String
    let serverName: String

    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        Form {
            Section {
                codeEntry
                    .listRowBackground(Color.clear)
            } header: {
                Text("Enter the code shown on the TV.")
            } footer: {
                Text("Signs the TV in as \(userName) on \(serverName).")
            }

            Section {
                Button {
                    codeFieldFocused = false
                    Task { await model.approve() }
                } label: {
                    HStack {
                        Spacer()
                        if model.phase == .approving {
                            ProgressView()
                        } else {
                            Text("Approve").bold()
                        }
                        Spacer()
                    }
                }
                .disabled(!model.canApprove)
            }

            result
        }
        .navigationTitle("Sign In a TV")
        .onAppear {
            model.reset()
            codeFieldFocused = true
        }
    }

    /// Six digit boxes over an invisible field that takes the typing, so the
    /// number pad (and paste, and a Mac keyboard) all work.
    private var codeEntry: some View {
        ZStack {
            TextField("", text: $model.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($codeFieldFocused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .accessibilityLabel("TV code")
                .frame(maxWidth: .infinity, minHeight: 64)

            HStack(spacing: 10) {
                ForEach(0..<QuickConnectApprovalViewModel.codeLength, id: \.self) { index in
                    digitBox(at: index)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { codeFieldFocused = true }
    }

    private func digitBox(at index: Int) -> some View {
        let digits = Array(model.code)
        let digit = index < digits.count ? String(digits[index]) : ""
        let isNext = index == digits.count && codeFieldFocused
        return Text(digit)
            .font(.system(size: 30, weight: .semibold, design: .monospaced))
            .frame(width: 44, height: 56)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isNext ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isNext ? 2 : 1)
            )
    }

    @ViewBuilder
    private var result: some View {
        switch model.phase {
        case .approved:
            Section {
                Label("TV signed in", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        case .entering, .approving:
            EmptyView()
        }
    }
}
