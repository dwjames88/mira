import CoreImage
import Foundation
import ImageIO
import Testing
@testable import MiraCore

@Suite struct ContactSheetTests {
    @Test func layoutGridSize() {
        let l = ContactSheetLayout(columns: 4, rows: 6, tileWidth: 900, tileHeight: 600)
        #expect(l.sheetWidth == l.pad + 4 * (900 + l.pad))
        #expect(l.sheetHeight == l.pad + 6 * (600 + l.labelHeight + l.pad))
        #expect(ContactSheetLayout.tileHeight(width: 900, sourceSize: CGSize(width: 2400, height: 1600)) == 600)
    }

    @Test func rendersExpectedGridFromSyntheticLibrary() throws {
        let lib = try SyntheticFilms.library([
            .init(id: "a", family: .colorNegative), .init(id: "b", family: .blackAndWhite),
        ])
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mira-cs-\(UUID().uuidString)")
        let source = Fixture.gradientAndPatches(size: 600)   // 600 x 600
        let config = ContactSheet.Config(
            films: ["a", "b", "missing"], states: [.film, .grain, .pushFrontier, .original],
            tileWidth: 100, outDir: out)
        var warnings: [String] = []
        let result = try ContactSheet.run(config: config, library: lib, warn: { warnings.append($0) }) { _ in source }
        #expect(result.films == ["a", "b"])
        #expect(warnings.count == 1)
        let layout = ContactSheetLayout(columns: 4, rows: 2, tileWidth: 100, tileHeight: 100)
        #expect(result.gridSize.width == layout.sheetWidth && result.gridSize.height == layout.sheetHeight)
        func size(_ name: String) throws -> (Int, Int) {
            let src = try #require(CGImageSourceCreateWithURL(out.appendingPathComponent(name) as CFURL, nil))
            let p = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
            return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int)
        }
        let grid = try size("contact-sheet.png")
        #expect(grid.0 == layout.sheetWidth && grid.1 == layout.sheetHeight)
        let row = try size("a.png")
        #expect(row.0 == layout.sheetWidth && row.1 == layout.pad + layout.cellHeight + layout.pad)
        _ = try size("crops.png")
        try? FileManager.default.removeItem(at: out)
    }
}
