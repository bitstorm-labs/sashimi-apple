import SwiftUI

// MARK: - Certificate Settings

struct CertificateSettingsView: View {
    @StateObject private var certSettings = CertificateTrustSettings.shared
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var showingWarning = false
    @State private var pendingToggle: (() -> Void)?

    private var isHTTPS: Bool {
        sessionManager.serverURL?.scheme?.lowercased() == "https"
    }

    private var hasValidCert: Bool {
        isHTTPS && !certSettings.allowSelfSigned && !certSettings.allowExpiredCerts
    }

    var body: some View {
        SettingsContainer {
            VStack(alignment: .leading, spacing: 24) {
                Text("Security Settings")
                    .font(Typography.headline)
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .padding(.bottom, 8)

                // Certificate Validation Section
                SettingsSection(title: "Certificate Validation") {
                    SettingsToggleRow(
                        title: "Allow Self-Signed Certificates",
                        isOn: Binding(
                            get: { certSettings.allowSelfSigned },
                            set: { newValue in
                                if newValue {
                                    pendingToggle = { certSettings.allowSelfSigned = true }
                                    showingWarning = true
                                } else {
                                    certSettings.allowSelfSigned = false
                                }
                            }
                        )
                    )

                    SettingsToggleRow(
                        title: "Allow Expired Certificates",
                        isOn: Binding(
                            get: { certSettings.allowExpiredCerts },
                            set: { newValue in
                                if newValue {
                                    pendingToggle = { certSettings.allowExpiredCerts = true }
                                    showingWarning = true
                                } else {
                                    certSettings.allowExpiredCerts = false
                                }
                            }
                        )
                    )
                }

                Text("Disabling certificate validation reduces security. Only enable if you trust your network.")
                    .font(Typography.captionSmall)
                    .foregroundStyle(SashimiTheme.textTertiary)
                    .padding(.horizontal, 8)

                // Trusted Hosts Section
                if !certSettings.trustedHosts.isEmpty {
                    SettingsSection(title: "Trusted Hosts") {
                        ForEach(Array(certSettings.trustedHosts).sorted(), id: \.self) { host in
                            TrustedHostRow(host: host) {
                                certSettings.untrustHost(host)
                            }
                        }
                    }

                    Text("These hosts have been manually trusted.")
                        .font(Typography.captionSmall)
                        .foregroundStyle(SashimiTheme.textTertiary)
                        .padding(.horizontal, 8)
                }

                // Security Status Section
                SettingsSection(title: "Security Status") {
                    if hasValidCert {
                        SecurityStatusRow(
                            icon: "lock.shield.fill",
                            iconColor: .green,
                            text: "HTTPS"
                        )
                    } else if isHTTPS {
                        SecurityStatusRow(
                            icon: "lock.trianglebadge.exclamationmark",
                            iconColor: .yellow,
                            text: "HTTPS (certificate override)"
                        )
                    } else {
                        SecurityStatusRow(
                            icon: "lock.open",
                            iconColor: .red,
                            text: "HTTP (not encrypted)"
                        )
                    }

                    SecurityStatusRow(
                        icon: certSettings.allowSelfSigned ? "exclamationmark.triangle" : "checkmark.shield",
                        iconColor: certSettings.allowSelfSigned ? .yellow : .green,
                        text: certSettings.allowSelfSigned ? "Self-signed certificates accepted" : "Only trusted certificates accepted"
                    )
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
        .confirmationDialog(
            "Security Warning",
            isPresented: $showingWarning,
            titleVisibility: .visible
        ) {
            Button("Enable Anyway", role: .destructive) {
                pendingToggle?()
                pendingToggle = nil
            }
            Button("Cancel", role: .cancel) {
                pendingToggle = nil
            }
        } message: {
            Text("Enabling this setting reduces the security of your connection. Man-in-the-middle attacks become possible.")
        }
    }
}

struct TrustedHostRow: View {
    let host: String
    let onRemove: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onRemove) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(host)
                        .font(Typography.body)
                        .foregroundStyle(SashimiTheme.textPrimary)
                    Text("Tap to remove")
                        .font(Typography.captionSmall)
                        .foregroundStyle(SashimiTheme.textTertiary)
                }

                Spacer()

                Image(systemName: "xmark.circle.fill")
                    .font(Typography.titleSmall)
                    .foregroundStyle(.red.opacity(0.8))
            }
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFocused ? SashimiTheme.accent.opacity(0.15) : SashimiTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(SashimiTheme.accent.opacity(isFocused ? 1.0 : 0), lineWidth: 3)
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .focused($isFocused)
    }
}

struct SecurityStatusRow: View {
    let icon: String
    let iconColor: Color
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(Typography.titleSmall)
                .foregroundStyle(iconColor)

            Text(text)
                .font(Typography.body)
                .foregroundStyle(SashimiTheme.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(SashimiTheme.cardBackground)
        )
    }
}
