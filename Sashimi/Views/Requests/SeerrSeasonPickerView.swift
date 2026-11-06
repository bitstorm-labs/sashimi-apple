import SwiftUI

/// Pick seasons to request (mockup D). Starts with every season that isn't
/// on the server ticked; seasons on the server are listed, dimmed, and
/// can't be picked.
struct SeerrSeasonPickerView: View {
    let title: String
    @State var plan: SeerrSeasonPlan
    let onRequest: (SeerrSeasonPlan) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Request \(title)")
                .font(Typography.headline)
                .foregroundStyle(SashimiTheme.textPrimary)
                .lineLimit(2)
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 12) {
                    if plan.partialRequestsEnabled, plan.missing.count > 1 {
                        SeasonPickRow(
                            title: "All missing seasons",
                            detail: "\(plan.missing.count)",
                            isOn: plan.allMissingSelected,
                            isPickable: true
                        ) {
                            plan.setAllMissing(!plan.allMissingSelected)
                        }
                    }
                    ForEach(plan.rows) { row in
                        SeasonPickRow(
                            title: row.title,
                            detail: row.detail,
                            isOn: row.seasons.allSatisfy(plan.selected.contains),
                            isPickable: row.isPickable,
                            isOnServer: row.detail == "On server"
                        ) {
                            row.seasons.forEach { plan.toggle($0) }
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
            }
            .focusSection()

            if !plan.partialRequestsEnabled {
                Text("This server only takes whole-show requests.")
                    .font(Typography.caption)
                    .foregroundStyle(SashimiTheme.textTertiary)
            }

            HStack(spacing: 20) {
                ActionButton(title: plan.buttonTitle, icon: "plus", isPrimary: true) {
                    onRequest(plan)
                }
                .disabled(plan.requestSeasons.isEmpty)
                ActionButton(title: "Cancel", icon: "xmark", action: onCancel)
            }
            .padding(.top, 10)
            .focusSection()
        }
        .padding(50)
        .frame(width: 1000)
        .frame(maxHeight: 900)
        .background(RoundedRectangle(cornerRadius: CornerRadius.xl).fill(Color(red: 0.106, green: 0.106, blue: 0.13)))
    }
}

private struct SeasonPickRow: View {
    let title: String
    let detail: String
    let isOn: Bool
    let isPickable: Bool
    var isOnServer = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: isOn && isPickable ? "checkmark.square.fill" : "square")
                    .font(.system(size: 30))
                    .foregroundStyle(isOn && isPickable ? SashimiTheme.accent : SashimiTheme.textTertiary)
                Text(title)
                    .font(Typography.titleSmall)
                    .foregroundStyle(SashimiTheme.textPrimary)
                Spacer()
                if isOnServer {
                    SeerrStatusTag(label: detail, color: SeerrBadge.available.color, fontSize: 18)
                } else {
                    Text(detail)
                        .font(Typography.caption)
                        .foregroundStyle(SashimiTheme.textTertiary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .focusHighlight(isFocused, cornerRadius: CornerRadius.medium)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .disabled(!isPickable)
        .opacity(isPickable ? 1 : 0.45)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
