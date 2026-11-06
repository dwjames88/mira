import AppKit
import MiraCore
import Testing
@testable import MiraUI

/// The brush ring is redrawn by invalidating only the old and the new spot (`ringRect`). That is right only if
/// `draw` never paints outside it.
@MainActor
@Suite("Dodge and burn brush ring", .serialized)
struct DodgeBurnRingTests {
    /// The bounding box, in view points, of every pixel `draw` touched with the ring centred on `pointer`.
    private static func inked(_ view: DodgeBurnPaintView, at pointer: CGPoint) throws -> NSRect? {
        view.pointer = pointer
        let scale = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let s = CGFloat(scale)
        return NSRect(x: CGFloat(minX) / s, y: CGFloat(minY) / s,
                      width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
    }

    @Test func theRingNeverPaintsOutsideItsInvalidationRect() async throws {
        let model = try await DodgeBurnUITests.model()
        model.setDodgeBurnTool(true)
        let view = DodgeBurnPaintView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.model = model
        view.backingScale = 2

        var checked = 0
        for mode in DodgeBurnMode.allCases {
            for (size, feather) in [(0.01, 0.0), (0.08, 0.6), (0.2, 1.0), (0.5, 0.3)] {
                model.setPaint(\.mode, mode)
                model.setPaint(\.size, size)
                model.setPaint(\.feather, feather)
                for point in [CGPoint(x: 300, y: 200), CGPoint(x: 40, y: 30), CGPoint(x: 590, y: 390)] {
                    let rect = try #require(view.ringRect(at: point))
                    guard let box = try Self.inked(view, at: point) else {
                        Issue.record("nothing drawn for \(mode) size \(size) at \(point)")
                        continue
                    }
                    let visible = rect.intersection(view.bounds)
                    #expect(visible.insetBy(dx: -0.01, dy: -0.01).contains(box),
                            "\(mode) size \(size) feather \(feather) at \(point): drew \(box), invalidates \(visible)")
                    checked += 1
                }
            }
        }
        #expect(checked == 3 * 4 * 3)
        model.cancelWork()
    }
}
