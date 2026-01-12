import SwiftUI

// MARK: - Parental Controls

@MainActor
class ParentalControlsManager: ObservableObject {
    static let shared = ParentalControlsManager()

    @AppStorage("parentalPIN") private var storedPIN: String = ""
    @AppStorage("isPINEnabled") var isPINEnabled: Bool = false
    @AppStorage("maxContentRating") var maxContentRating: ContentRating = .any
    @AppStorage("kidsMode") var kidsMode: Bool = false
    @AppStorage("hideUnrated") var hideUnrated: Bool = false

    var hasSetPIN: Bool {
        !storedPIN.isEmpty
    }

    func setPIN(_ pin: String) {
        storedPIN = pin
        isPINEnabled = true
    }

    func verifyPIN(_ pin: String) -> Bool {
        pin == storedPIN
    }

    func disablePIN() {
        storedPIN = ""
        isPINEnabled = false
    }

    func shouldHideItem(withRating rating: String?) -> Bool {
        guard maxContentRating != .any else { return false }

        guard let rating = rating else {
            return hideUnrated
        }

        let itemRating = ContentRating(officialRating: rating)
        return itemRating.severity > maxContentRating.severity
    }
}

enum ContentRating: String, CaseIterable, Codable {
    case any = "Any"
    case g = "G"
    case pg = "PG"
    case pg13 = "PG-13"
    case r = "R"
    case nc17 = "NC-17"

    var displayName: String {
        switch self {
        case .any: return "No Restriction"
        case .g: return "G - General Audiences"
        case .pg: return "PG - Parental Guidance"
        case .pg13: return "PG-13 - Parents Strongly Cautioned"
        case .r: return "R - Restricted"
        case .nc17: return "NC-17 - Adults Only"
        }
    }

    var severity: Int {
        switch self {
        case .any: return 100
        case .g: return 0
        case .pg: return 1
        case .pg13: return 2
        case .r: return 3
        case .nc17: return 4
        }
    }

    init(officialRating: String) {
        let normalized = officialRating.uppercased().replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "G": self = .g
        case "PG": self = .pg
        case "PG13": self = .pg13
        case "R": self = .r
        case "NC17": self = .nc17
        case "TV14": self = .pg13
        case "TVMA": self = .r
        case "TVG": self = .g
        case "TVPG": self = .pg
        case "TVY", "TVY7": self = .g
        default: self = .any
        }
    }
}

struct ParentalControlsView: View {
    @StateObject private var controls = ParentalControlsManager.shared
    @State private var showPINSetup = false
    @State private var showPINVerify = false
    @State private var pendingAction: (() -> Void)?

    var body: some View {
        SettingsContainer {
            VStack(alignment: .leading, spacing: 24) {
                Text("Parental Controls")
                    .font(Typography.headline)
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .padding(.bottom, 8)

                // PIN Protection Section
                SettingsSection(title: "PIN Protection") {
                    SettingsToggleRow(
                        title: "Enable PIN Lock",
                        isOn: Binding(
                            get: { controls.isPINEnabled },
                            set: { newValue in
                                if newValue {
                                    showPINSetup = true
                                } else {
                                    pendingAction = { controls.disablePIN() }
                                    showPINVerify = true
                                }
                            }
                        )
                    )

                    if controls.isPINEnabled {
                        SettingsActionRow(title: "Change PIN", icon: "key") {
                            pendingAction = { showPINSetup = true }
                            showPINVerify = true
                        }
                    }
                }

                Text("PIN protects access to settings and adult content.")
                    .font(Typography.captionSmall)
                    .foregroundStyle(SashimiTheme.textTertiary)
                    .padding(.horizontal, 8)

                // Content Restrictions Section
                SettingsSection(title: "Content Restrictions") {
                    SettingsNavigationRow(
                        title: "Maximum Content Rating",
                        subtitle: controls.maxContentRating.rawValue
                    ) {
                        ContentRatingPickerView()
                    }

                    SettingsToggleRow(title: "Hide Unrated Content", isOn: $controls.hideUnrated)
                }

                Text("Content above the selected rating will be hidden.")
                    .font(Typography.captionSmall)
                    .foregroundStyle(SashimiTheme.textTertiary)
                    .padding(.horizontal, 8)

                // Kids Mode Section
                SettingsSection(title: "Kids Mode") {
                    SettingsToggleRow(
                        title: "Enable Kids Mode",
                        isOn: Binding(
                            get: { controls.kidsMode },
                            set: { newValue in
                                if !newValue && controls.isPINEnabled {
                                    pendingAction = { controls.kidsMode = false }
                                    showPINVerify = true
                                } else {
                                    controls.kidsMode = newValue
                                    if newValue {
                                        controls.maxContentRating = .g
                                    }
                                }
                            }
                        )
                    )
                }

                Text("Kids Mode shows only G-rated content. Requires PIN to exit.")
                    .font(Typography.captionSmall)
                    .foregroundStyle(SashimiTheme.textTertiary)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
        .sheet(isPresented: $showPINSetup) {
            PINSetupView { pin in
                controls.setPIN(pin)
                showPINSetup = false
            }
        }
        .sheet(isPresented: $showPINVerify) {
            PINVerifyView { success in
                showPINVerify = false
                if success {
                    pendingAction?()
                }
                pendingAction = nil
            }
        }
    }
}

struct SettingsActionRow: View {
    let title: String
    var icon: String = ""
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(SashimiTheme.textPrimary)

                Spacer()

                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(Typography.body)
                        .foregroundStyle(SashimiTheme.textTertiary)
                }
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

struct ContentRatingPickerView: View {
    @AppStorage("maxContentRating") private var maxContentRating: ContentRating = .any

    var body: some View {
        SettingsContainer {
            VStack(alignment: .leading, spacing: 16) {
                Text("Content Rating")
                    .font(Typography.headline)
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .padding(.bottom, 8)

                Text("Content above the selected rating will be hidden")
                    .font(Typography.caption)
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .padding(.bottom, 16)

                ForEach(ContentRating.allCases, id: \.rawValue) { rating in
                    SettingsPickerOptionRow(
                        title: rating.rawValue,
                        subtitle: rating.displayName,
                        isSelected: maxContentRating == rating
                    ) {
                        maxContentRating = rating
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
        }
    }
}

struct PINSetupView: View {
    let onComplete: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var step = 1
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                Image(systemName: step == 1 ? "lock" : "lock.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(SashimiTheme.accent)

                Text(step == 1 ? "Create a 4-Digit PIN" : "Confirm Your PIN")
                    .font(.title2)
                    .fontWeight(.bold)

                // PIN dots display
                HStack(spacing: 20) {
                    ForEach(0..<4) { index in
                        Circle()
                            .fill(currentPIN.count > index ? SashimiTheme.accent : Color.gray.opacity(0.3))
                            .frame(width: 20, height: 20)
                    }
                }
                .padding(.vertical)

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                // Hidden text field for PIN input
                TextField("", text: Binding(
                    get: { currentPIN },
                    set: { handlePINInput($0) }
                ))
                .keyboardType(.numberPad)
                .focused($isFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)

                Text("Use the number keys on your remote")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(60)
            .navigationTitle("Set PIN")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                isFocused = true
            }
        }
    }

    private var currentPIN: String {
        step == 1 ? pin : confirmPin
    }

    private func handlePINInput(_ input: String) {
        let filtered = String(input.filter { $0.isNumber }.prefix(4))

        if step == 1 {
            pin = filtered
            if pin.count == 4 {
                step = 2
            }
        } else {
            confirmPin = filtered
            if confirmPin.count == 4 {
                if confirmPin == pin {
                    onComplete(pin)
                } else {
                    errorMessage = "PINs don't match. Try again."
                    confirmPin = ""
                    step = 1
                    pin = ""
                }
            }
        }
    }
}

struct PINVerifyView: View {
    let onComplete: (Bool) -> Void

    @StateObject private var controls = ParentalControlsManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var attempts = 0
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(SashimiTheme.accent)

                Text("Enter Your PIN")
                    .font(.title2)
                    .fontWeight(.bold)

                // PIN dots display
                HStack(spacing: 20) {
                    ForEach(0..<4) { index in
                        Circle()
                            .fill(pin.count > index ? SashimiTheme.accent : Color.gray.opacity(0.3))
                            .frame(width: 20, height: 20)
                    }
                }
                .padding(.vertical)

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                // Hidden text field for PIN input
                TextField("", text: Binding(
                    get: { pin },
                    set: { handlePINInput($0) }
                ))
                .keyboardType(.numberPad)
                .focused($isFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)

                Text("Use the number keys on your remote")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(60)
            .navigationTitle("Enter PIN")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onComplete(false)
                        dismiss()
                    }
                }
            }
            .onAppear {
                isFocused = true
            }
        }
    }

    private func handlePINInput(_ input: String) {
        let filtered = String(input.filter { $0.isNumber }.prefix(4))
        pin = filtered

        if pin.count == 4 {
            if controls.verifyPIN(pin) {
                onComplete(true)
                dismiss()
            } else {
                attempts += 1
                if attempts >= 3 {
                    errorMessage = "Too many attempts. Please try again later."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        onComplete(false)
                        dismiss()
                    }
                } else {
                    errorMessage = "Incorrect PIN. \(3 - attempts) attempts remaining."
                    pin = ""
                }
            }
        }
    }
}
