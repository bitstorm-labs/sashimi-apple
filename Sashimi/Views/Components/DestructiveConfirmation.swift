import SwiftUI
import UIKit

extension View {
    /// A two-button confirmation for something that cannot be undone, which
    /// always opens with Cancel focused.
    ///
    /// SwiftUI's `alert` and `confirmationDialog` give no say over which
    /// button the remote lands on: `keyboardShortcut(.defaultAction)` is
    /// unavailable on tvOS, and focus simply goes wherever that tvOS release
    /// lays the buttons out. `UIAlertController.preferredAction` is the one
    /// thing the system honours, so the alert is presented through UIKit.
    /// Menu dismisses it as Cancel.
    ///
    /// - Parameter onConfirm: runs while `isPresented` is still true, so it
    ///   can read whatever state the binding is derived from.
    func destructiveConfirmation(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        background(
            DestructiveConfirmationPresenter(
                title: title,
                message: message,
                confirmTitle: confirmTitle,
                isPresented: isPresented,
                onConfirm: onConfirm
            )
            .accessibilityHidden(true)
        )
    }
}

private struct DestructiveConfirmationPresenter: UIViewControllerRepresentable {
    let title: String
    let message: String
    let confirmTitle: String
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    final class Coordinator {
        weak var alert: UIAlertController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let anchor = UIViewController()
        anchor.view.isUserInteractionEnabled = false
        return anchor
    }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        if isPresented, coordinator.alert == nil {
            let alert = makeAlert(coordinator: coordinator)
            coordinator.alert = alert
            // Deferred a turn: the anchor may not be in a window yet during
            // the update that flips the binding.
            DispatchQueue.main.async {
                guard coordinator.alert === alert, anchor.viewIfLoaded?.window != nil else {
                    coordinator.alert = nil
                    isPresented = false
                    return
                }
                anchor.present(alert, animated: true)
            }
        } else if !isPresented, let alert = coordinator.alert {
            coordinator.alert = nil
            alert.dismiss(animated: true)
        }
    }

    static func dismantleUIViewController(_ anchor: UIViewController, coordinator: Coordinator) {
        coordinator.alert?.dismiss(animated: false)
        coordinator.alert = nil
    }

    private func makeAlert(coordinator: Coordinator) -> UIAlertController {
        DestructiveConfirmationAlert.make(
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            onConfirm: {
                coordinator.alert = nil
                onConfirm()
                isPresented = false
            },
            onCancel: {
                coordinator.alert = nil
                isPresented = false
            }
        )
    }
}

enum DestructiveConfirmationAlert {
    static func make(
        title: String,
        message: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let confirm = UIAlertAction(title: confirmTitle, style: .destructive) { _ in onConfirm() }
        let cancel = UIAlertAction(title: "Cancel", style: .cancel) { _ in onCancel() }
        alert.addAction(confirm)
        alert.addAction(cancel)
        // What decides where the remote starts: without it focus follows
        // the system's button layout, which is not ours to rely on.
        alert.preferredAction = cancel
        return alert
    }
}
