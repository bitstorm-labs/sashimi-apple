import SwiftUI
import UIKit

// MARK: - Playing from inside a sheet (#781)
//
// A full-screen cover presented from a sheet's content belongs to the sheet.
// On the Mac that put the player inside the small sheet window: Play in an
// episode sheet played in the sheet, and the viewer had to maximise it, where
// the page's own Resume button filled the window. So a play request made in a
// sheet is handed to the view that showed the sheet: the sheet closes and that
// view presents the player over the whole window. Nested sheets pass the
// request up until it reaches a view that is not in a sheet.

/// What to play, carried out of a sheet.
struct PlayerRequest: Identifiable {
    let id = UUID()
    let item: BaseItemDto
    var serverID: String?
    var startFromBeginning = false
}

/// Takes a play request made inside a sheet. Present only in a sheet's
/// content, so its absence means "present the player here".
struct PlayerHandoff {
    let send: @MainActor (PlayerRequest) -> Void
}

private struct PlayerHandoffKey: EnvironmentKey {
    static let defaultValue: PlayerHandoff? = nil
}

extension EnvironmentValues {
    var playerHandoff: PlayerHandoff? {
        get { self[PlayerHandoffKey.self] }
        set { self[PlayerHandoffKey.self] = newValue }
    }
}

/// Where a play request goes. Pure, so it is tested without UI.
enum PlayerPresentationRoute: Equatable {
    /// Not in a sheet: this view's full-screen cover fills the window.
    case presentHere
    /// In a sheet: close it and let the view that showed it present.
    case handOffToPresenter

    static func route(insideSheet: Bool) -> Self {
        insideSheet ? .handOffToPresenter : .presentHere
    }
}

/// The view that shows a sheet holds a play request from it until the sheet
/// has gone, then presents it, or passes it further up when it is itself in
/// a sheet.
struct SheetPlayerHandoffState {
    private(set) var pending: PlayerRequest?

    /// The sheet asked to play. The caller closes the sheet.
    mutating func receive(_ request: PlayerRequest) {
        pending = request
    }

    /// The sheet has gone: what to present, and where. Nil when the sheet
    /// closed for any other reason.
    mutating func sheetDidDismiss(presenterIsInSheet: Bool) -> (request: PlayerRequest, route: PlayerPresentationRoute)? {
        guard let request = pending else { return nil }
        pending = nil
        return (request, PlayerPresentationRoute.route(insideSheet: presenterIsInSheet))
    }
}

// MARK: - Sheet that plays outside itself

private struct PlayerSheetModifier<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    var onDismiss: (() -> Void)?
    @ViewBuilder var sheetContent: (Item) -> SheetContent

    @Environment(\.playerHandoff) private var parentHandoff
    @State private var handoff = SheetPlayerHandoffState()
    @State private var presenting: PlayerRequest?

    func body(content: Content) -> some View {
        content
            .sheet(item: $item, onDismiss: sheetDidDismiss) { value in
                sheetContent(value)
                    .dismissesOnOutsideTap()
                    .environment(\.playerHandoff, PlayerHandoff { request in
                        handoff.receive(request)
                        item = nil
                    })
            }
            .fullScreenCover(item: $presenting) { request in
                MobilePlayerView(
                    item: request.item,
                    serverID: request.serverID,
                    startFromBeginning: request.startFromBeginning
                )
            }
    }

    private func sheetDidDismiss() {
        onDismiss?()
        guard let next = handoff.sheetDidDismiss(presenterIsInSheet: parentHandoff != nil) else { return }
        switch next.route {
        case .presentHere:
            presenting = next.request
        case .handOffToPresenter:
            parentHandoff?.send(next.request)
        }
    }
}

private struct PresentedSheetToken: Identifiable {
    let id = 0
}

extension View {
    /// A sheet whose content may start playback: the player opens over the
    /// whole window, not inside the sheet. Also closes on a tap outside.
    func playerSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        modifier(PlayerSheetModifier(item: item, onDismiss: onDismiss, sheetContent: content))
    }

    func playerSheet<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let token = Binding<PresentedSheetToken?>(
            get: { isPresented.wrappedValue ? PresentedSheetToken() : nil },
            set: { isPresented.wrappedValue = $0 != nil }
        )
        return modifier(PlayerSheetModifier(item: token, onDismiss: onDismiss) { _ in content() })
    }
}

// MARK: - Closing a sheet with a tap outside it

extension View {
    /// Applied to a sheet's content: a click or tap outside the sheet closes
    /// it, as Esc already does on the Mac. Sheets that refuse interactive
    /// dismissal stay open.
    func dismissesOnOutsideTap() -> some View {
        modifier(OutsideTapDismissModifier())
    }
}

private struct OutsideTapDismissModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.background(
            OutsideTapDismissInstaller { dismiss() }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}

/// Puts a tap recognizer on the sheet's presentation container (the dimmed
/// area around it) that fires only for touches outside the sheet itself.
private struct OutsideTapDismissInstaller: UIViewRepresentable {
    let onOutsideTap: () -> Void

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.onOutsideTap = onOutsideTap
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        uiView.onOutsideTap = onOutsideTap
    }

    static func dismantleUIView(_ uiView: InstallerView, coordinator: ()) {
        uiView.uninstall()
    }

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        var onOutsideTap: (() -> Void)?
        private weak var presentation: UIPresentationController?
        private var recognizer: UITapGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // The container exists once the presentation is under way.
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        private func install() {
            guard recognizer == nil,
                  let presentation = owningViewController()?.presentationController,
                  let container = presentation.containerView else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            container.addGestureRecognizer(tap)
            self.presentation = presentation
            recognizer = tap
        }

        func uninstall() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onOutsideTap?()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let presentation,
                  let container = presentation.containerView,
                  let sheet = presentation.presentedView,
                  !presentation.presentedViewController.isModalInPresentation,
                  // A cover or player presented over the sheet owns the touch.
                  presentation.presentedViewController.presentedViewController == nil else { return false }
            let sheetFrame = sheet.convert(sheet.bounds, to: container)
            return !sheetFrame.contains(touch.location(in: container))
        }

        private func owningViewController() -> UIViewController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController { return controller }
                responder = next
            }
            return nil
        }
    }
}
