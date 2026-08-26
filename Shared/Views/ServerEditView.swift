import SwiftUI

/// Shared saved-server editor used by tvOS, iPhone, and iPad. The view only
/// collects values; SessionManager owns validation, authentication, and the
/// atomic persistence transition.
struct ServerEditView: View {
    let server: ServerConfig

    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var alias: String
    @State private var serverURL: String
    @State private var username: String
    @State private var password = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(server: ServerConfig) {
        self.server = server
        _alias = State(initialValue: server.nameOverride ?? "")
        _serverURL = State(initialValue: server.url.absoluteString)
        _username = State(initialValue: server.username)
    }

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09)
                .ignoresSafeArea()

            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        displayNameSection
                        connectionSection

                        Button {
                            save()
                        } label: {
                            Group {
                                if isSaving {
                                    ProgressView()
                                } else {
                                    Label("Save Server", systemImage: "checkmark.circle.fill")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
                    }
                    .frame(maxWidth: 720)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .navigationTitle("Edit Server")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                        .disabled(isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            save()
                        }
                        .disabled(isSaving)
                    }
                }
                .alert("Couldn’t Save Server", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK") { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "Please check the server details and try again.")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .preferredColorScheme(.dark)
    }

    private var displayNameSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display Name")
                .font(.headline)

            TextField("Alias (Optional)", text: $alias)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .serverEditFieldStyle()

            Text("Leave this blank to use Jellyfin’s name: \(server.name).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection")
                .font(.headline)

            TextField("Server URL", text: $serverURL)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .serverEditFieldStyle()

            TextField("Username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .serverEditFieldStyle()

            SecureField("New Password (Optional)", text: $password)
                .textContentType(.newPassword)
                .serverEditFieldStyle()

            Text("Leave the password blank to keep the current credential. A new password is required when changing the URL or username.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        guard let normalizedURL = ServerEditRequest.normalize(serverURL) else {
            errorMessage = SessionError.invalidServerURL.localizedDescription
            return
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = SessionError.invalidUsername.localizedDescription
            return
        }

        isSaving = true
        errorMessage = nil

        Task {
            do {
                try await sessionManager.updateServer(
                    id: server.id,
                    nameOverride: alias,
                    serverURL: normalizedURL,
                    username: username,
                    password: password
                )
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension View {
    func serverEditFieldStyle() -> some View {
        padding(12)
            .background(Color.secondary.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
