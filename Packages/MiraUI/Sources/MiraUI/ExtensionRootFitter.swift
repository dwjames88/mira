import AppKit
import os

/// Keeps an extension's root view filling whatever Photos gives it. The extension runs in a remote-view
/// service, and the host does not always resize the controller's root view, so this pins it to its
/// superview (Auto Layout) or, with no superview, tracks the window's content area.
@MainActor
public final class ExtensionRootFitter {
    private static let log = Logger(subsystem: "com.fieldframes.mira", category: "extension")

    private weak var view: NSView?
    private var pinned: NSView?
    private var constraints: [NSLayoutConstraint] = []
    private var observers: [NSObjectProtocol] = []
    private var observedWindow: NSWindow?
    private var observedSuperview: NSView?
    /// Called with the size the root view should have, so the controller can update `preferredContentSize`.
    public var onFit: ((NSSize) -> Void)?

    public init(view: NSView) {
        self.view = view
    }

    isolated deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Fits the root view now and (re)installs the observers. Safe to call repeatedly.
    public func fit(reason: String) {
        guard let view else { return }
        if let superview = view.superview {
            pin(view, to: superview)
            observe(superview: superview)
        } else if let window = view.window, let content = window.contentView, content !== view {
            observe(window: window)
            view.frame = content.bounds
        } else if let window = view.window {
            observe(window: window)
        }
        view.layoutSubtreeIfNeeded()
        report(reason)
        let size = view.superview?.bounds.size ?? view.window?.contentView?.bounds.size ?? view.bounds.size
        if size.width > 0, size.height > 0 { onFit?(size) }
    }

    private func pin(_ view: NSView, to superview: NSView) {
        if pinned === superview, !constraints.isEmpty { return }
        NSLayoutConstraint.deactivate(constraints)
        view.translatesAutoresizingMaskIntoConstraints = false
        constraints = [
            view.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: superview.trailingAnchor),
            view.topAnchor.constraint(equalTo: superview.topAnchor),
            view.bottomAnchor.constraint(equalTo: superview.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        pinned = superview
    }

    private func observe(superview: NSView) {
        guard observedSuperview !== superview else { return }
        observedSuperview = superview
        superview.postsFrameChangedNotifications = true
        let token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: superview, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fit(reason: "superview frame changed") }
        }
        observers.append(token)
        if let window = superview.window { observe(window: window) }
    }

    private func observe(window: NSWindow) {
        guard observedWindow !== window else { return }
        observedWindow = window
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fit(reason: "window \(name.rawValue)") }
            }
            observers.append(token)
        }
    }

    private func report(_ reason: String) {
        guard let view else { return }
        let sup = view.superview
        let supClass = sup.map { String(describing: type(of: $0)) } ?? "none"
        let win = view.window
        Self.log.notice("""
        [\(reason, privacy: .public)] view=\(NSStringFromRect(view.frame), privacy: .public) \
        superview=\(sup.map { NSStringFromRect($0.frame) } ?? "none", privacy: .public) (\(supClass, privacy: .public)) \
        window=\(win.map { NSStringFromRect($0.frame) } ?? "none", privacy: .public) \
        contentView=\(win?.contentView.map { NSStringFromRect($0.frame) } ?? "none", privacy: .public)
        """)
    }
}
