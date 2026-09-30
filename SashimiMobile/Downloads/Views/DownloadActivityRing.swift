import SwiftUI

/// Small circular progress ring with the active/queued download count in the
/// middle. Spins indeterminately while no overall progress is known yet.
struct DownloadActivityRing: View {
    let snapshot: DownloadActivitySnapshot
    var diameter: CGFloat = 26
    var lineWidth: CGFloat = 3

    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(MobileColors.accent.opacity(0.25), lineWidth: lineWidth)
            if let progress = snapshot.progress {
                Circle()
                    .trim(from: 0, to: max(progress, 0.02))
                    .stroke(MobileColors.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(MobileColors.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 270 : -90))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
                    .onAppear { spinning = true }
                    .onDisappear { spinning = false }
            }
            Text("\(snapshot.activeCount)")
                .font(.system(size: diameter * 0.42, weight: .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .foregroundStyle(MobileColors.accent)
                .padding(lineWidth)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let noun = snapshot.activeCount == 1 ? "download" : "downloads"
        guard let progress = snapshot.progress else { return "\(snapshot.activeCount) \(noun) in progress" }
        return "\(snapshot.activeCount) \(noun) in progress, \(Int(progress * 100)) percent"
    }
}
