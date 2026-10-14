import SwiftUI
import UIKit
import XCTest
@testable import SashimiMobile

/// The detail screens' rating + media chips + status badge row wraps instead
/// of clipping on a narrow (375pt) iPhone.
@MainActor
final class WrappingHStackTests: XCTestCase {
    /// 375pt iPhone (SE / mini) minus PhoneDetailView's 16pt side padding.
    private let narrowContentWidth: CGFloat = 375 - 2 * MobileSpacing.md

    // MARK: - Line breaking

    func testEverythingOnOneLineWhenItFits() {
        let lines = WrappingHStack.lines(widths: [60, 40, 50], maxWidth: 200, spacing: 12)
        XCTAssertEqual(lines, [0..<3])
    }

    func testOverflowingChildMovesToNextLine() {
        // 60 + 12 + 40 + 12 + 50 = 174 > 150: the last child wraps.
        let lines = WrappingHStack.lines(widths: [60, 40, 50], maxWidth: 150, spacing: 12)
        XCTAssertEqual(lines, [0..<2, 2..<3])
    }

    func testExactFitStaysOnOneLine() {
        let lines = WrappingHStack.lines(widths: [60, 40], maxWidth: 112, spacing: 12)
        XCTAssertEqual(lines, [0..<2])
    }

    func testChildWiderThanRowGetsItsOwnLine() {
        let lines = WrappingHStack.lines(widths: [30, 400, 30], maxWidth: 200, spacing: 8)
        XCTAssertEqual(lines, [0..<1, 1..<2, 2..<3])
    }

    func testNoChildrenNoLines() {
        XCTAssertEqual(WrappingHStack.lines(widths: [], maxWidth: 200, spacing: 8), [])
    }

    // MARK: - The real row at 375pt

    func testFullBadgeRowOverflowsAnHStackAtNarrowWidth() {
        // Guards the premise: if this ever fits, the wrap test below proves nothing.
        let hstack = measure(HStack(spacing: MobileSpacing.sm) { BadgeRowFixture.children }, width: .infinity)
        XCTAssertGreaterThan(hstack.width, narrowContentWidth)
    }

    func testFullBadgeRowWrapsAndKeepsTheStatusBadgeInside() throws {
        let single = measure(HStack(spacing: MobileSpacing.sm) { BadgeRowFixture.children }, width: .infinity)
        let wrapped = measure(WrappingHStack(spacing: MobileSpacing.sm) { BadgeRowFixture.children })

        XCTAssertLessThanOrEqual(wrapped.width, narrowContentWidth, "the row stays inside the column")
        XCTAssertGreaterThan(wrapped.height, single.height * 1.5, "the row wrapped onto a second line")

        // The status badge (last child) lands on a line that fits whole.
        let widths = BadgeRowFixture.childViews.map { measure($0, width: .infinity).width }
        let lines = WrappingHStack.lines(widths: widths, maxWidth: narrowContentWidth, spacing: MobileSpacing.sm)
        let badgeLine = try XCTUnwrap(lines.last)
        XCTAssertTrue(badgeLine.contains(widths.count - 1))
        let badgeLineWidth = badgeLine.reduce(0) { $0 + widths[$1] }
            + MobileSpacing.sm * CGFloat(badgeLine.count - 1)
        XCTAssertLessThanOrEqual(badgeLineWidth, narrowContentWidth)

        try snapshot(name: "badge-row-375-before-hstack") {
            HStack(spacing: MobileSpacing.sm) { BadgeRowFixture.children }
        }
        try snapshot(name: "badge-row-375-after-wrapping") {
            WrappingHStack(spacing: MobileSpacing.sm) { BadgeRowFixture.children }
        }
    }

    func testRowThatFitsKeepsASingleLine() {
        let single = measure(HStack(spacing: MobileSpacing.sm) { BadgeRowFixture.shortChildren })
        let wrapped = measure(WrappingHStack(spacing: MobileSpacing.sm) { BadgeRowFixture.shortChildren })
        XCTAssertEqual(wrapped.width, single.width, accuracy: 0.5)
        XCTAssertEqual(wrapped.height, single.height, accuracy: 0.5)
    }

    // MARK: - Helpers

    /// Size offered `width` (the 375pt column by default); `.infinity` gives
    /// the ideal, uncompressed size.
    private func measure<V: View>(_ view: V, width: CGFloat? = nil) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(
            in: CGSize(width: width ?? narrowContentWidth, height: .greatestFiniteMagnitude)
        )
    }

    /// Renders the row in a 375pt-wide phone column (16pt side padding, clipped
    /// like the detail screen) and writes it to `$WRAP_SNAPSHOT_DIR` when set
    /// (`TEST_RUNNER_WRAP_SNAPSHOT_DIR` on the xcodebuild command line).
    private func snapshot<V: View>(name: String, @ViewBuilder _ row: () -> V) throws {
        guard let dir = ProcessInfo.processInfo.environment["WRAP_SNAPSHOT_DIR"] else { return }
        let content = VStack(alignment: .leading, spacing: 0) {
            row()
        }
        .padding(.horizontal, MobileSpacing.md)
        .padding(.vertical, 12)
        .frame(width: 375, alignment: .leading)
        .clipped()
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        let png = try XCTUnwrap(renderer.uiImage?.pngData())
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }
}

/// The worst realistic phone row: TMDB + Rotten Tomatoes ratings, 1080p,
/// H.264, Dolby Digital+ 5.1 and an "Ended" status badge, styled like
/// PhoneDetailView's chips.
private enum BadgeRowFixture {
    @ViewBuilder static var children: some View {
        ratings
        mediaChips
        SeriesStatusBadge(status: .ended)
    }

    @ViewBuilder static var shortChildren: some View {
        ratings
        SeriesStatusBadge(status: .ended)
    }

    static var childViews: [AnyView] {
        [AnyView(ratings), AnyView(mediaChips), AnyView(SeriesStatusBadge(status: .ended))]
    }

    static var ratings: some View {
        HStack(spacing: MobileSpacing.md) {
            HStack(spacing: 4) {
                Image("TMDBLogo").resizable().scaledToFit().frame(height: 16)
                Text("7.9").font(.system(size: 14, weight: .bold))
            }
            HStack(spacing: 4) {
                Text("\u{1F345}").font(.system(size: 14))
                Text("93%").font(.system(size: 14, weight: .bold))
            }
        }
        .foregroundStyle(MobileColors.textPrimary)
    }

    static var mediaChips: some View {
        HStack(spacing: 6) {
            chip(Text("1080p"))
            chip(Text("H.264"))
            chip(HStack(spacing: 4) {
                Image("DolbyDigitalPlus").resizable().scaledToFit().frame(height: 10)
                Text("5.1")
            })
        }
    }

    static func chip<V: View>(_ label: V) -> some View {
        label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(MobileColors.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.3), lineWidth: 1))
    }
}
