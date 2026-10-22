import SwiftUI

private typealias T = FieldFramesTheme

/// A block of release notes, already split by the updater (MiraUI does not depend on it).
public enum UpdateNoticeBlock: Equatable, Sendable {
    case heading(String)
    case bullet(String)
    case paragraph(String)
}

/// What the notice says about a release.
public struct UpdateNoticeInfo: Equatable, Sendable {
    public var version: String
    public var current: String
    public var notes: [UpdateNoticeBlock]

    public init(version: String, current: String, notes: [UpdateNoticeBlock]) {
        self.version = version
        self.current = current
        self.notes = notes
    }
}

/// Where the update window is in its flow.
public enum UpdateNoticePhase: Equatable, Sendable {
    case checking
    case upToDate(current: String)
    case available(UpdateNoticeInfo)
    case downloading(UpdateNoticeInfo, received: Int64, total: Int64)
    /// Verifying, installing, relaunching: no buttons. `status` is the mono line, `detail` an optional note.
    case working(UpdateNoticeInfo, status: String, detail: String?)
    /// The new version is in place. `note` explains anything the user must do on first launch.
    case installed(UpdateNoticeInfo, note: String?)
    /// The verified download was saved for a manual install (the in-place install was not possible).
    case savedForManualInstall(UpdateNoticeInfo, fileName: String, reason: String)
    case failed(String, info: UpdateNoticeInfo?)
}

public struct UpdateNoticeActions {
    public var install: () -> Void
    public var later: () -> Void
    public var skip: () -> Void
    public var cancel: () -> Void
    public var dismiss: () -> Void
    public var openReleasePage: () -> Void
    public var reveal: () -> Void

    public init(install: @escaping () -> Void = {}, later: @escaping () -> Void = {}, skip: @escaping () -> Void = {},
                cancel: @escaping () -> Void = {}, dismiss: @escaping () -> Void = {},
                openReleasePage: @escaping () -> Void = {}, reveal: @escaping () -> Void = {}) {
        self.install = install
        self.later = later
        self.skip = skip
        self.cancel = cancel
        self.dismiss = dismiss
        self.openReleasePage = openReleasePage
        self.reveal = reveal
    }
}

/// The software-update window: Cormorant headline, mono status, release notes on a panel, hairlines, square
/// buttons. Non-modal; the app owns the window.
public struct UpdateNoticeView: View {
    private let phase: UpdateNoticePhase
    private let actions: UpdateNoticeActions

    public init(phase: UpdateNoticePhase, actions: UpdateNoticeActions = UpdateNoticeActions()) {
        self.phase = phase
        self.actions = actions
    }

    public static let width: CGFloat = T.cells(60)

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headline)
                .font(T.display(40, weight: .regular))
                .foregroundStyle(T.paper)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, T.rows(2))
            Text(status).ffLabel(size: 11, color: statusColor)
                .padding(.top, 2)
            FFByline().padding(.top, T.rows(1) / 2)
            FFHairline().padding(.top, T.rows(1))
            content
            Spacer(minLength: 0)
            FFHairline().padding(.bottom, T.rows(1))
            HStack(spacing: T.cells(1)) { buttons }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.bottom, T.rows(1))
        }
        .padding(.horizontal, T.cells(4))
        .frame(width: Self.width, height: T.rows(26), alignment: .topLeading)
        .fieldFramesWindow()
    }

    // MARK: Text

    private var headline: String {
        switch phase {
        case .checking: "Checking\u{2026}"
        case .upToDate: "Up to date"
        case .available(let info), .downloading(let info, _, _), .working(let info, _, _), .installed(let info, _), .savedForManualInstall(let info, _, _):
            "Mira \(info.version)"
        case .failed: "Update failed"
        }
    }

    private var status: String {
        switch phase {
        case .checking: "Asking GitHub for the latest release"
        case .upToDate(let current): "Mira \(current) is the latest version"
        case .available(let info): "A new version is available \u{00B7} you have \(info.current)"
        case .downloading: "Downloading"
        case .working(_, let status, _): status
        case .installed: "Installed"
        case .savedForManualInstall: "Saved for a manual install"
        case .failed: "The update did not finish"
        }
    }

    private var statusColor: Color {
        switch phase {
        case .available, .downloading, .working: T.lichen
        default: T.paperDim
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch phase {
        case .checking:
            progressBar(fraction: nil).padding(.top, T.rows(3))
        case .upToDate:
            Text("You are running the newest release. Mira checks again about once a day, or any time from Mira \u{25B8} Check for Updates\u{2026}.")
                .bodyText().padding(.top, T.rows(2))
        case .available(let info):
            FFSectionLabel("What\u{2019}s new").padding(.top, T.rows(1))
            notes(info.notes)
        case .downloading(let info, let received, let total):
            FFSectionLabel("What\u{2019}s new").padding(.top, T.rows(1))
            notes(info.notes)
            VStack(alignment: .leading, spacing: 4) {
                progressBar(fraction: total > 0 ? min(Double(received) / Double(total), 1) : nil)
                Text(Self.byteText(received, total)).ffLabel(size: 10, color: T.paperMid)
            }
            .padding(.top, T.rows(1)).padding(.bottom, T.rows(1))
        case .working(let info, _, let detail):
            FFSectionLabel("What\u{2019}s new").padding(.top, T.rows(1))
            notes(info.notes)
            VStack(alignment: .leading, spacing: 4) {
                progressBar(fraction: nil)
                if let detail { Text(detail).bodyText() }
            }
            .padding(.top, T.rows(1)).padding(.bottom, T.rows(1))
        case .installed(_, let note):
            Text("The new version is in place. Relaunch to start using it.").bodyText().padding(.top, T.rows(2))
            if let note { Text(note).bodyText(color: T.paperSoft).padding(.top, T.rows(1)) }
        case .savedForManualInstall(_, let fileName, let reason):
            Text(reason).bodyText().padding(.top, T.rows(2))
            Text(fileName).ffLabel(size: 11, color: T.paperMid).padding(.top, T.rows(1))
            Text("Quit Mira, open the download and drag Mira to Applications, replacing the old copy.")
                .bodyText().padding(.top, T.rows(1))
        case .failed(let message, _):
            Text(message).bodyText().padding(.top, T.rows(2))
        }
    }

    private func notes(_ blocks: [UpdateNoticeBlock]) -> some View {
        FFScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if blocks.isEmpty {
                    Text("No release notes were published for this version.").bodyText()
                }
                ForEach(blocks.indices, id: \.self) { i in
                    switch blocks[i] {
                    case .heading(let text):
                        Text(text).ffLabel(size: 10, color: T.lichen, weight: .medium).padding(.top, i == 0 ? 0 : 8)
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: T.cells(1)) {
                            Text("\u{00B7}").foregroundStyle(T.paperDim)
                            Text(Self.inline(text)).bodyText(color: T.paperSoft)
                        }
                    case .paragraph(let text):
                        Text(Self.inline(text)).bodyText(color: T.paperSoft)
                    }
                }
            }
            .padding(T.cells(2))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { FFPanelBackground() }
        .overlay(Rectangle().strokeBorder(T.hair, lineWidth: 1))
        .padding(.top, T.rows(1) / 2)
    }

    private func progressBar(fraction: Double?) -> some View {
        Rectangle().fill(T.hair).frame(height: 2)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle().fill(T.lichen)
                        .frame(width: proxy.size.width * (fraction ?? 0.18))
                        .opacity(fraction == nil ? 0.6 : 1)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "Working")
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        switch phase {
        case .checking:
            Button("Cancel", action: actions.cancel).buttonStyle(.ff).keyboardShortcut(.cancelAction)
        case .upToDate:
            Button("OK", action: actions.dismiss).buttonStyle(.ffProminent).keyboardShortcut(.defaultAction)
        case .available:
            Button("Skip This Version", action: actions.skip).buttonStyle(.ff)
            Spacer(minLength: 0)
            Button("Later", action: actions.later).buttonStyle(.ff).keyboardShortcut(.cancelAction)
            Button("Download & Install", action: actions.install).buttonStyle(.ffProminent).keyboardShortcut(.defaultAction)
        case .downloading:
            Button("Cancel", action: actions.cancel).buttonStyle(.ff).keyboardShortcut(.cancelAction)
        case .working:
            EmptyView()
        case .installed(_, let note):
            if note != nil { Button("Show in Finder", action: actions.reveal).buttonStyle(.ff) }
            Spacer(minLength: 0)
            Button("Later", action: actions.later).buttonStyle(.ff).keyboardShortcut(.cancelAction)
            Button("Relaunch Now", action: actions.install).buttonStyle(.ffProminent).keyboardShortcut(.defaultAction)
        case .savedForManualInstall:
            Button("Release Page", action: actions.openReleasePage).buttonStyle(.ff)
            Spacer(minLength: 0)
            Button("Show in Finder", action: actions.reveal).buttonStyle(.ffProminent).keyboardShortcut(.defaultAction)
            Button("Done", action: actions.dismiss).buttonStyle(.ff)
        case .failed(_, let info):
            if info != nil { Button("Release Page", action: actions.openReleasePage).buttonStyle(.ff) }
            Spacer(minLength: 0)
            Button("OK", action: actions.dismiss).buttonStyle(.ffProminent).keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Helpers

    /// `**bold**`, `code` and links rendered; anything unparseable stays literal.
    static func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnly)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    static func byteText(_ received: Int64, _ total: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let done = formatter.string(fromByteCount: received)
        guard total > 0 else { return "\(done) downloaded" }
        return "\(done) of \(formatter.string(fromByteCount: total))"
    }
}

private extension Text {
    func bodyText(color: Color = T.paperMid) -> some View {
        font(.system(size: 12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}
