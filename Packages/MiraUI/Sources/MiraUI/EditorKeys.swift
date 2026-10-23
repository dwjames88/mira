import AppKit
import SwiftUI

/// What a key press does in the editor.
public enum EditorKeyAction: Equatable, Sendable {
    case selectTab(EditorTab)
    case toggleImmersive
    case exitImmersive
    /// Show the original while held (`true`), back to the edit on release (`false`).
    case compare(Bool)
    case zoomIn
    case zoomOut
    /// Dodge and burn tool: the brush one step bigger (+1) or smaller (-1).
    case brushSize(Int)
    /// Dodge and burn tool: show or hide the mask overlay.
    case toggleMaskOverlay
    /// Dodge and burn tool: close it.
    case exitDodgeBurn
    /// Space held: drag pans, and Space alone scrolls nothing.
    case space(Bool)
    /// Consume the event (auto-repeat of a handled key) without doing anything.
    case swallow
}

/// One key event, reduced to what the key map needs.
public struct EditorKeyEvent: Equatable, Sendable {
    /// `charactersIgnoringModifiers`.
    public var characters: String
    public var keyCode: UInt16
    public var isDown: Bool
    public var isRepeat: Bool
    /// Command, Option or Control is held: those belong to menus and the system.
    public var hasCommandOptionControl: Bool
    public var hasShift: Bool
    /// Command is held without Option or Control (the dodge and burn tool takes ⌘= and ⌘- for zoom).
    public var hasCommandOnly: Bool

    public init(characters: String, keyCode: UInt16 = 0, isDown: Bool = true, isRepeat: Bool = false,
                hasCommandOptionControl: Bool = false, hasShift: Bool = false, hasCommandOnly: Bool = false) {
        self.characters = characters
        self.keyCode = keyCode
        self.isDown = isDown
        self.isRepeat = isRepeat
        self.hasCommandOptionControl = hasCommandOptionControl
        self.hasShift = hasShift
        self.hasCommandOnly = hasCommandOnly
    }

    public static let escapeKeyCode: UInt16 = 53
}

/// The editor state the key map depends on.
public struct EditorKeyContext: Equatable, Sendable {
    public var hasPhoto = true
    /// A text field or other text input has keyboard focus.
    public var isTextInputFocused = false
    public var isImmersive = false
    public var isCropping = false
    public var isComparing = false
    public var isSpaceHeld = false
    /// The dodge and burn brush tool is open.
    public var isDodgeBurn = false

    public init(hasPhoto: Bool = true, isTextInputFocused: Bool = false, isImmersive: Bool = false,
                isCropping: Bool = false, isComparing: Bool = false, isSpaceHeld: Bool = false,
                isDodgeBurn: Bool = false) {
        self.hasPhoto = hasPhoto
        self.isTextInputFocused = isTextInputFocused
        self.isImmersive = isImmersive
        self.isCropping = isCropping
        self.isComparing = isComparing
        self.isSpaceHeld = isSpaceHeld
        self.isDodgeBurn = isDodgeBurn
    }
}

/// The editor's single-key shortcuts as a pure table: key event and state in, action out. nil means
/// "not ours" and the event goes on to the responder chain and the menus.
///
/// | Key | Action |
/// |---|---|
/// | 1 / 2 / 3 | Films / Develop / Crop tab |
/// | F | full screen, panels hidden (not while cropping) |
/// | Esc | leave that view |
/// | C (hold) | compare with the original |
/// | ] / [ | zoom in / out one step |
/// | Space (hold) | drag pans |
///
/// While the dodge and burn tool is open:
///
/// | Key | Action |
/// |---|---|
/// | ] / [ | brush bigger / smaller (zoom moves to ⌘= / ⌘-) |
/// | O | mask overlay on / off |
/// | Esc | leave the tool (Esc leaves full screen only when the tool is closed) |
/// | ⌥ (hold, as a stroke starts) | flip dodge and burn for that stroke |
public enum EditorKeyMap {
    public static func action(for event: EditorKeyEvent, context: EditorKeyContext) -> EditorKeyAction? {
        guard context.hasPhoto else { return nil }
        let key = event.characters.lowercased()

        // The tool takes [ and ] for the brush, so zoom steps move to Command with = and -.
        if context.isDodgeBurn, event.isDown, event.hasCommandOnly, !context.isTextInputFocused {
            switch key {
            case "=", "+": return event.isRepeat ? .swallow : .zoomIn
            case "-", "_": return event.isRepeat ? .swallow : .zoomOut
            default: break
            }
        }
        guard !event.hasCommandOptionControl else { return nil }

        if event.keyCode == EditorKeyEvent.escapeKeyCode {
            guard event.isDown else { return nil }
            if context.isDodgeBurn { return .exitDodgeBurn }
            return context.isImmersive ? .exitImmersive : nil
        }

        // Releases always finish a hold that began here, even if focus moved meanwhile.
        if !event.isDown {
            switch key {
            case "c": return context.isComparing ? .compare(false) : nil
            case " ": return context.isSpaceHeld ? .space(false) : nil
            default: return nil
            }
        }
        guard !context.isTextInputFocused, !event.hasShift else { return nil }

        switch key {
        case "1", "2", "3":
            guard let tab = EditorTab.forKey(key), !context.isImmersive else { return .swallow }
            return event.isRepeat ? .swallow : .selectTab(tab)
        case "f":
            if event.isRepeat || (context.isCropping && !context.isImmersive) { return .swallow }
            return .toggleImmersive
        case "c":
            if event.isRepeat || context.isCropping { return .swallow }
            return .compare(true)
        case "]", "[":
            if context.isDodgeBurn { return .brushSize(key == "]" ? 1 : -1) }
            if event.isRepeat || context.isCropping { return .swallow }
            return key == "]" ? .zoomIn : .zoomOut
        case "o":
            guard context.isDodgeBurn else { return nil }
            return event.isRepeat ? .swallow : .toggleMaskOverlay
        case " ":
            return event.isRepeat ? .swallow : .space(true)
        default:
            return nil
        }
    }
}

// MARK: Key host

/// Installs a local key monitor while the editor is on screen and feeds the key map. A monitor, not
/// SwiftUI focus, so the keys work whichever control was clicked last, and key-up is seen (compare
/// is press-and-hold). Events are ignored while a text field is being edited.
struct EditorKeyHost: NSViewRepresentable {
    let model: EditorModel
    /// True in the app: F also toggles the window's full screen. The extension only hides panels.
    let windowFullScreen: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.coordinator = context.coordinator
        context.coordinator.model = model
        context.coordinator.windowFullScreen = windowFullScreen
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        context.coordinator.model = model
        context.coordinator.windowFullScreen = windowFullScreen
        context.coordinator.sync(immersive: model.isImmersive)
    }

    static func dismantleNSView(_ view: HostView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class HostView: NSView {
        var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { coordinator?.start(window: window) } else { coordinator?.stop() }
        }
    }

    @MainActor
    final class Coordinator {
        var model: EditorModel?
        var windowFullScreen = false
        private weak var window: NSWindow?
        private var lastImmersive = false
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []

        func start(window: NSWindow) {
            stop()
            self.window = window
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                nonisolated(unsafe) let e = event
                let consumed = MainActor.assumeIsolated { self?.handle(e) ?? false }
                return consumed ? nil : event
            }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.model?.releaseHolds() }
                },
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.windowFullScreen else { return }
                        self.model?.setImmersive(false)
                    }
                },
            ]
        }

        /// Puts the window in or out of macOS full screen when the model's immersive state changes.
        func sync(immersive: Bool) {
            guard immersive != lastImmersive else { return }
            lastImmersive = immersive
            guard windowFullScreen, let window else { return }
            if immersive != window.styleMask.contains(.fullScreen) {
                Task { @MainActor in window.toggleFullScreen(nil) }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            model?.releaseHolds()
            // Leaving the editor (back to the library) must not strand the window in full screen.
            if windowFullScreen, lastImmersive, let window, window.styleMask.contains(.fullScreen) {
                Task { @MainActor in window.toggleFullScreen(nil) }
            }
            if lastImmersive { model?.setImmersive(false) }
            lastImmersive = false
        }

        /// True when the event was ours and is consumed.
        private func handle(_ event: NSEvent) -> Bool {
            guard let model, let window, event.window === window else { return false }
            let responder = window.firstResponder
            let editing = responder is NSText || responder is NSTextField
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = EditorKeyEvent(
                characters: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode,
                isDown: event.type == .keyDown,
                isRepeat: event.type == .keyDown && event.isARepeat,
                hasCommandOptionControl: !flags.isDisjoint(with: [.command, .option, .control]),
                hasShift: flags.contains(.shift),
                hasCommandOnly: flags.contains(.command) && flags.isDisjoint(with: [.option, .control]))
            let ctx = EditorKeyContext(
                hasPhoto: model.source != nil, isTextInputFocused: editing, isImmersive: model.isImmersive,
                isCropping: model.isCropping, isComparing: model.showOriginal, isSpaceHeld: model.isSpaceHeld,
                isDodgeBurn: model.dodgeBurnTool.isActive)
            guard let action = EditorKeyMap.action(for: key, context: ctx) else { return false }
            model.perform(action)
            return true
        }
    }
}
