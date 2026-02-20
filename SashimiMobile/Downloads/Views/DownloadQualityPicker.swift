import SwiftUI

struct DownloadQualityPicker: View {
    let itemName: String
    let onSelect: (DownloadQuality) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(DownloadQuality.allCases) { quality in
                        Button {
                            onSelect(quality)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(quality.displayName)
                                        .font(MobileTypography.title)
                                        .foregroundStyle(MobileColors.textPrimary)
                                    Text(quality.subtitle)
                                        .font(MobileTypography.caption)
                                        .foregroundStyle(MobileColors.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle")
                                    .foregroundStyle(MobileColors.accent)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Choose quality for \"\(itemName)\"")
                }

                Section {
                    HStack {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(MobileColors.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Available Storage")
                                .font(MobileTypography.bodySmall)
                                .foregroundStyle(MobileColors.textSecondary)
                            Text(ByteCountFormatter.string(
                                fromByteCount: DownloadFileManager.availableDiskSpace(),
                                countStyle: .file
                            ))
                            .font(MobileTypography.title)
                            .foregroundStyle(MobileColors.textPrimary)
                        }
                    }
                }
            }
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
