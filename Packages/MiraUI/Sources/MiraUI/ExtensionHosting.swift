import AppKit
import SwiftUI

/// Hosts the shared editor inside a view the Photos editing window owns. Photos sizes that view and
/// resizes it live, so the editor is pinned to all four edges with Auto Layout and the hosting view
/// does not push its own ideal size back (`sizingOptions` empty).
public enum ExtensionHosting {
    @MainActor
    @discardableResult
    public static func install(_ model: EditorModel, in container: NSView) -> NSHostingView<EditorView<EmptyView>> {
        let host = NSHostingView(rootView: EditorView(model: model))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return host
    }
}
