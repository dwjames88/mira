import CoreImage
import Foundation
import ImageIO
import Testing
@testable import MiraCore

@Suite struct ImageSourceLoadingTests {
    static let sample: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Fixtures/sample.jpg")
    }()
    let context = Renderer.sharedContext

    @Test func thumbnailIsSmallAndUpright() throws {
        let thumb = try #require(ImageSource.loadThumbnail(url: Self.sample, maxPixelSize: 600))
        #expect(max(thumb.extent.width, thumb.extent.height) <= 600)
        #expect(thumb.extent.width > thumb.extent.height) // sample.jpg is 3:2 landscape
        let rotated = try #require(ImageSource.loadThumbnail(url: Self.sample, orientation: .right, maxPixelSize: 600))
        #expect(rotated.extent.height > rotated.extent.width)
    }

    @Test func decodedMatchesLazyLoad() throws {
        let lazy = try #require(ImageSource.load(url: Self.sample))
        let decoded = try #require(ImageSource.loadDecoded(url: Self.sample))
        #expect(lazy.extent == decoded.extent)
        let a = Pixels(lazy, context: context).rgba
        let b = Pixels(decoded, context: context).rgba
        #expect(a == b)
    }

    @Test func decodedAppliesExplicitOrientationOnce() throws {
        let plain = try #require(ImageSource.loadDecoded(url: Self.sample))
        let turned = try #require(ImageSource.loadDecoded(url: Self.sample, orientation: .right))
        #expect(turned.extent.size == CGSize(width: plain.extent.height, height: plain.extent.width))
        let lazyTurned = try #require(ImageSource.load(url: Self.sample, orientation: .right))
        #expect(lazyTurned.extent.size == turned.extent.size)
    }

    @Test func orientedPixelSizeReadsTheHeader() throws {
        #expect(ImageSource.orientedPixelSize(url: Self.sample) == CGSize(width: 2400, height: 1600))
        #expect(ImageSource.orientedPixelSize(url: Self.sample, orientation: .left) == CGSize(width: 1600, height: 2400))
        #expect(ImageSource.orientedPixelSize(url: URL(fileURLWithPath: "/nonexistent.jpg")) == nil)
    }

    @Test func thumbnailOfMissingFileIsNil() {
        #expect(ImageSource.loadThumbnail(url: URL(fileURLWithPath: "/nonexistent.jpg"), maxPixelSize: 100) == nil)
        #expect(ImageSource.loadDecoded(url: URL(fileURLWithPath: "/nonexistent.jpg")) == nil)
    }
}
