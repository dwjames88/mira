import MiraCore
import Photos
import UIKit
import XCTest
@testable import Mira

/// PhotoKit integration for the Photos-library actions. Opt-in: TEST_RUNNER_MIRA_LIBRARY_PROBE=1 on a
/// Photos-granted simulator. It only touches the one asset it imports into the album "Emulsion Test",
/// and the scratch albums "Emulsion Test Scratch" / "Emulsion Test Scratch 2" (created once, reused).
///
/// Not covered: asset delete, album delete and hide/unhide. Photos raises a system confirmation for each, which a
/// unit test cannot answer, so `LibraryActions.delete` / `deleteAlbum` / `setHidden` are not called here. The scratch
/// albums and the imported asset are left in place for manual cleanup.
final class LibraryActionsSimTests: XCTestCase {
    static let testAlbum = "Emulsion Test"
    static let scratch = "Emulsion Test Scratch"
    static let scratch2 = "Emulsion Test Scratch 2"

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIRA_LIBRARY_PROBE"] == "1",
                          "Opt-in: set TEST_RUNNER_MIRA_LIBRARY_PROBE=1")
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try XCTSkipUnless(s == .authorized, "Photos not fully authorized (\(s.rawValue))")
    }

    // MARK: helpers

    nonisolated static func albumID(titled title: String) -> String? {
        let o = PHFetchOptions()
        o.predicate = NSPredicate(format: "title = %@", title)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: o).firstObject?.localIdentifier
    }

    static func ensureAlbum(_ title: String) async throws -> String {
        if let id = albumID(titled: title) { return id }
        return try await LibraryActions.createAlbum(title: title)
    }

    /// Imports sample.jpg into "Emulsion Test" and returns the new asset's id.
    static func importAsset() async throws -> String {
        let url = Snapshot.root.appendingPathComponent("Fixtures/sample.jpg")
        let album = try await ensureAlbum(testAlbum)
        let slot = Slot()
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
            let placeholder = request.placeholderForCreatedAsset!
            slot.set(placeholder.localIdentifier)
            if let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject {
                PHAssetCollectionChangeRequest(for: collection)?.addAssets([placeholder] as NSArray)
            }
        }
        return try XCTUnwrap(slot.value)
    }

    nonisolated static func albumContains(_ albumID: String, _ assetID: String) -> Bool {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return false }
        let o = PHFetchOptions()
        o.includeHiddenAssets = true
        o.predicate = NSPredicate(format: "localIdentifier = %@", assetID)
        return PHAsset.fetchAssets(in: album, options: o).count > 0
    }

    nonisolated static func asset(_ id: String) -> PHAsset? {
        let o = PHFetchOptions()
        o.includeHiddenAssets = true
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: o).firstObject
    }

    // MARK: test

    func testLibraryActionsRoundTrip() async throws {
        let asset = try await Self.importAsset()
        let a = try await Self.ensureAlbum(Self.scratch)
        let b = try await Self.ensureAlbum(Self.scratch2)

        // Favorite on / off.
        try await LibraryActions.setFavorite([asset], true)
        XCTAssertEqual(LibraryActions.isFavorite(id: asset), true)
        try await LibraryActions.setFavorite([asset], false)
        XCTAssertEqual(LibraryActions.isFavorite(id: asset), false)

        // Hide / unhide are not exercised: Photos asks "Allow Mira to hide this photo?" (a system alert).

        // Album list reads.
        let albums = LibraryActions.userAlbums()
        XCTAssertTrue(albums.contains { $0.id == a } && albums.contains { $0.id == b })
        XCTAssertEqual(LibraryActions.albumCapabilities(id: a)?.canRemove, true)

        // Add, move between the scratch albums, remove.
        try await LibraryActions.add([asset], toAlbum: a)
        XCTAssertTrue(Self.albumContains(a, asset))
        XCTAssertTrue(LibraryActions.albumIDs(containing: asset).contains(a))
        try await LibraryActions.move([asset], from: a, to: b)
        XCTAssertFalse(Self.albumContains(a, asset))
        XCTAssertTrue(Self.albumContains(b, asset))
        try await LibraryActions.remove([asset], fromAlbum: b)
        XCTAssertFalse(Self.albumContains(b, asset))

        // Rename and put it back.
        try await LibraryActions.renameAlbum(id: b, title: "Emulsion Test Scratch 2 renamed")
        XCTAssertEqual(LibraryActions.userAlbums().first { $0.id == b }?.title, "Emulsion Test Scratch 2 renamed")
        try await LibraryActions.renameAlbum(id: b, title: Self.scratch2)
        XCTAssertEqual(LibraryActions.userAlbums().first { $0.id == b }?.title, Self.scratch2)

        // Duplicate: a new asset, same pixel size.
        let copies = try await LibraryActions.duplicate([asset])
        XCTAssertEqual(copies.count, 1)
        if let copy = copies.first, let original = Self.asset(asset), let made = Self.asset(copy) {
            XCTAssertEqual(made.pixelWidth, original.pixelWidth)
            XCTAssertNotEqual(copy, asset)
        }

        // Info read.
        let info = await AssetInfoReader.read(id: asset)
        let read = try XCTUnwrap(info)
        XCTAssertGreaterThan(read.pixelWidth, 0)
        XCTAssertGreaterThan(read.pixelHeight, 0)
        XCTAssertFalse(read.formats.isEmpty, "format is read")
        XCTAssertFalse(read.filename.isEmpty)
    }
}

private final class Slot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ v: String) { lock.lock(); stored = v; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
}
