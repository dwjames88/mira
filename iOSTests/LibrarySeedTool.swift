import Photos
import XCTest

/// Opt-in seeding of the dedicated "Mira QA Library" simulator with a large album tree for the gallery perf probe
/// (TEST_RUNNER_MIRA_SEED_LIBRARY=1). It only ever creates albums and folders (never edits or deletes pictures),
/// and refuses to run on any other device. The pictures themselves come from `xcrun simctl addmedia`
/// (see scripts/make-seed-jpegs.swift and docs/PERFORMANCE.md).
///
/// Layout (deterministic): 4 top-level folders (Trips with a nested year folder, Projects, Family, Archive with two
/// nesting levels), top-level albums, 3 albums of 1,000-2,000 pictures, ~12 of a few hundred, many of 3-60,
/// 6 empty ones. 150 albums in total.
final class LibrarySeedTool: XCTestCase {
    static let deviceName = "Mira QA Library"
    static let totalAlbums = 150

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIRA_SEED_LIBRARY"] == "1",
                          "Opt-in: set TEST_RUNNER_MIRA_SEED_LIBRARY=1")
        let name = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        XCTAssertEqual(name, Self.deviceName, "Refusing to seed any device but \(Self.deviceName)")
        guard name == Self.deviceName else { throw XCTSkip("wrong device") }
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try XCTSkipUnless(s == .authorized, "Photos not authorized (\(s.rawValue))")
    }

    /// How many pictures album `n` (0-based) gets; deterministic.
    static func size(ofAlbum n: Int) -> Int {
        switch n {
        case 0: return 2000
        case 1: return 1500
        case 2: return 1000
        case 3...14: return 150 + (n * 37) % 350
        case 15...20: return 0
        default: return 3 + (n * 17) % 58
        }
    }

    func testSeedAlbumTree() async throws {
        let assetOptions = PHFetchOptions()
        assetOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        assetOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: assetOptions)
        print("SEED library pictures=\(assets.count)")
        XCTAssertGreaterThan(assets.count, 2500, "add the pictures with simctl addmedia first")

        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).count
        guard existing < 100 else { print("SEED already seeded albums=\(existing)"); return }

        // Create the albums (batches of 25), each with its pictures taken from a rolling window of the library.
        var albumIDs: [String] = []
        for batchStart in stride(from: 0, to: Self.totalAlbums, by: 25) {
            var placeholders: [PHObjectPlaceholder] = []
            try await PHPhotoLibrary.shared().performChanges {
                for n in batchStart..<min(batchStart + 25, Self.totalAlbums) {
                    let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: String(format: "Album %03d", n))
                    if let p = request.placeholderForCreatedAssetCollection as PHObjectPlaceholder? { placeholders.append(p) }
                    let size = Self.size(ofAlbum: n)
                    guard size > 0 else { continue }
                    let start = (n * 211) % max(1, assets.count - size)
                    let slice = assets.objects(at: IndexSet(start..<min(assets.count, start + size)))
                    request.addAssets(slice as NSArray)
                }
            }
            albumIDs += placeholders.map(\.localIdentifier)
        }
        XCTAssertEqual(albumIDs.count, Self.totalAlbums)

        // Folders: albums 21...(21+k) move into folders; the rest stay at the top level.
        func collections(_ ids: ArraySlice<String>) -> [PHAssetCollection] {
            let r = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(ids), options: nil)
            return r.objects(at: IndexSet(0..<r.count))
        }
        var folderPlaceholders: [String: PHObjectPlaceholder] = [:]
        try await PHPhotoLibrary.shared().performChanges {
            for name in ["Trips", "Trips 2019", "Projects", "Family", "Archive", "Archive 2018", "Archive 2018 Q4"] {
                let r = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: name)
                folderPlaceholders[name] = r.placeholderForCreatedCollectionList
            }
        }
        func folder(_ name: String) -> PHCollectionList? {
            folderPlaceholders[name].flatMap { PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [$0.localIdentifier], options: nil).firstObject }
        }
        func albumsIn(_ range: Range<Int>) -> [PHAssetCollection] { collections(albumIDs[range]) }
        let plan: [(String, Range<Int>)] = [
            ("Trips", 3..<14), ("Trips 2019", 30..<36), ("Projects", 36..<52), ("Family", 52..<70),
            ("Archive", 70..<80), ("Archive 2018", 80..<86), ("Archive 2018 Q4", 86..<90),
        ]
        try await PHPhotoLibrary.shared().performChanges {
            for (name, range) in plan {
                guard let f = folder(name), let req = PHCollectionListChangeRequest(for: f) else { continue }
                req.addChildCollections(albumsIn(range) as NSArray)
            }
            // Nest the year / quarter folders inside their parents.
            for (child, parent) in [("Trips 2019", "Trips"), ("Archive 2018", "Archive"), ("Archive 2018 Q4", "Archive 2018")] {
                guard let c = folder(child), let p = folder(parent), let req = PHCollectionListChangeRequest(for: p) else { continue }
                req.addChildCollections([c] as NSArray)
            }
        }
        let top = PHCollectionList.fetchTopLevelUserCollections(with: nil).count
        let all = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).count
        print("SEED done pictures=\(assets.count) albums=\(all) topLevelCollections=\(top)")
    }
}
