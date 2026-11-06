import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

/// A name sheet request: a new album, or a rename.
struct AlbumNameRequest: Identifiable, Equatable {
    enum Kind: Equatable { case create, rename(id: String) }
    let id = UUID()
    var kind: Kind
    var initialName: String
}

struct AlbumDeleteRequest: Identifiable, Equatable {
    let id: String
    let title: String
}

/// New / rename / delete album from the album list. Writes go through `LibraryActions`; the library
/// change observer refreshes the list.
@MainActor @Observable
final class AlbumToolsModel {
    var nameRequest: AlbumNameRequest?
    var deleteRequest: AlbumDeleteRequest?
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    func newAlbum(existingTitles: [String]) {
        nameRequest = AlbumNameRequest(kind: .create, initialName: AlbumList.uniqueTitle(existing: existingTitles))
    }

    func rename(id: String, title: String) { nameRequest = AlbumNameRequest(kind: .rename(id: id), initialName: title) }

    func submit(_ request: AlbumNameRequest, name: String) {
        run {
            switch request.kind {
            case .create: _ = try await LibraryActions.createAlbum(title: name)
            case .rename(let id): try await LibraryActions.renameAlbum(id: id, title: name)
            }
        }
    }

    func confirmDelete(_ request: AlbumDeleteRequest) {
        let id = request.id
        run { try await LibraryActions.deleteAlbum(id: id) }
    }

    private func run(_ work: @escaping @Sendable () async throws -> Void) {
        Task { [weak self] in
            do { try await work() } catch {
                if LibraryActions.isUserCancel(error) { return }
                self?.show(error.localizedDescription)
            }
        }
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

/// `+ NEW` in the ALBUMS header.
struct NewAlbumButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("+ NEW").ffLabel(size: 10, color: T.lichen, weight: .medium)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The header keeps its height; only the hit area is 44 pt.
        .padding(.vertical, -14)
        .accessibilityLabel("New album")
        .accessibilityIdentifier("library.newAlbumHeader")
    }
}

/// A small ink-soft sheet with a mono field: NEW ALBUM / RENAME ALBUM.
struct AlbumNameSheet: View {
    let title: String
    let confirmTitle: String
    @State var name: String
    var onSubmit: (String) -> Void
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: T.cells(1.5)) {
            SheetHandle(label: "Close", onClose: onClose)
            Text(title).font(T.display(28, weight: .regular)).foregroundStyle(T.paper)
                .padding(.horizontal, T.cells(2))
            FFMonoField(prompt: "Album name", text: $name, submitLabel: .done, onSubmit: commit, capitalization: .words)
                .focused($focused)
                .padding(.horizontal, T.cells(2))
                .accessibilityIdentifier("library.albumName")
            HStack {
                Spacer()
                Button(action: commit) { Text(confirmTitle) }
                    .buttonStyle(.ffProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("library.albumNameConfirm")
            }
            .padding(.horizontal, T.cells(2))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ffSheet(detents: [.height(230)])
        .onAppear { focused = true }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

extension View {
    /// Hosts the album list's name sheet, delete confirmation and notice.
    func albumTools(_ tools: AlbumToolsModel) -> some View {
        modifier(AlbumToolsModifier(tools: tools))
    }

    /// Long-press RENAME / DELETE ALBUM on a user-album tile. Capabilities are read when the menu opens.
    func albumContextMenu(node: SidebarNode, tools: AlbumToolsModel, limited: Bool) -> some View {
        contextMenu {
            if node.kind == .album, LibraryActionAvailability.canManageAlbums(limitedAccess: limited),
               let caps = LibraryActions.albumCapabilities(id: node.id) {
                if caps.canRename {
                    Button { tools.rename(id: node.id, title: node.title) } label: { Label("RENAME", systemImage: "pencil") }
                }
                if caps.canDelete {
                    Button(role: .destructive) {
                        tools.deleteRequest = AlbumDeleteRequest(id: node.id, title: node.title)
                    } label: { Label("DELETE ALBUM", systemImage: "trash") }
                }
            }
        }
    }
}

private struct AlbumToolsModifier: ViewModifier {
    let tools: AlbumToolsModel

    func body(content: Content) -> some View {
        content
            .sheet(item: Bindable(tools).nameRequest) { request in
                AlbumNameSheet(
                    title: request.kind == .create ? "New album" : "Rename album",
                    confirmTitle: request.kind == .create ? "CREATE" : "RENAME",
                    name: request.initialName,
                    onSubmit: { name in tools.submit(request, name: name); tools.nameRequest = nil },
                    onClose: { tools.nameRequest = nil })
            }
            .confirmationDialog(
                "Delete album?", isPresented: Binding(get: { tools.deleteRequest != nil }, set: { if !$0 { tools.deleteRequest = nil } }),
                titleVisibility: .visible, presenting: tools.deleteRequest
            ) { request in
                Button("Delete \(request.title)", role: .destructive) { tools.confirmDelete(request) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The photos stay in your library.")
            }
            .overlay(alignment: .bottom) {
                if let notice = tools.notice { LibraryNoticeLine(text: notice).padding(.bottom, 16) }
            }
    }
}
