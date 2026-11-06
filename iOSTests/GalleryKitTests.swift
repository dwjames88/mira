import XCTest
@testable import Mira

final class GalleryKitTests: XCTestCase {
    /// A bare `Task.detached(...).value` ignores the awaiting task's cancellation; `GalleryKit.detached` passes it on,
    /// so a scan batch stops when its album is left.
    func testDetachedPassesCancellationToTheChild() async {
        let parent = Task { () -> Bool in
            await GalleryKit.detached(priority: .utility) { () async -> Bool in
                for _ in 0..<400 {
                    if Task.isCancelled { return true }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return false
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        parent.cancel()
        let childSawCancel = await parent.value
        XCTAssertTrue(childSawCancel)
    }

    func testDetachedReturnsTheResult() async {
        let value = await GalleryKit.detached(priority: .userInitiated) { 6 * 7 }
        XCTAssertEqual(value, 42)
    }

    @MainActor func testBadgeCacheFollowsTheThumbnailVersion() {
        let album = AlbumModel(nodeID: "all")
        XCTAssertNil(album.cachedBadges(id: "a", version: 0))
        album.storeBadges((raw: true, edited: false), id: "a", version: 0)
        XCTAssertEqual(album.cachedBadges(id: "a", version: 0)?.raw, true)
        XCTAssertEqual(album.cachedBadges(id: "a", version: 0)?.edited, false)
        // An edit bumps the asset's version: the EDITED answer is read again.
        XCTAssertNil(album.cachedBadges(id: "a", version: 1))
    }
}
