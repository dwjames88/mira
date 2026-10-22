import AppKit
import MiraUI
import SwiftUI

/// The content of the update window: observes the controller and draws the Field Frames notice.
private struct UpdateWindowRoot: View {
    let controller: UpdateController

    var body: some View {
        UpdateNoticeView(phase: controller.phase, actions: controller.actions)
    }
}

/// A plain, non-modal window around `UpdateNoticeView`: transparent title bar, close button, no resizing.
@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private unowned let controller: UpdateController

    init(controller: UpdateController) {
        self.controller = controller
        let hosting = NSHostingController(rootView: UpdateWindowRoot(controller: controller))
        hosting.sizingOptions = []
        window = NSWindow(contentViewController: hosting)
        super.init()
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Software Update"
        window.setContentSize(NSSize(width: UpdateNoticeView.width, height: FieldFramesTheme.rows(26)))
        window.center()
        window.delegate = self
    }

    func show(activate: Bool) {
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)   // do not take focus from what the user is doing
        }
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        // Closing a window that is waiting on the user counts as Later; an active download is cancelled.
        switch controller.phase {
        case .checking, .downloading: controller.abandonWork()
        default: break
        }
    }
}
