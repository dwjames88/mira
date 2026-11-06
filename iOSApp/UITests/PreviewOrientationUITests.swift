import CoreGraphics
import XCTest

/// On-screen ground truth for the editor's main preview. The FILMS cards and the main photo come from different render
/// paths (an engine thumbnail, a Metal drawable) and must show the sunset fixture the same way up: bright sky above,
/// dark trees and water below. A screenshot of the Films tab (launch environment only, no taps) is cut into the main
/// photo and the selected film's card by their accessibility frames, both reduced to a 12 x 8 luma grid, and the photo
/// must correlate with the card upright better than with the card flipped vertically.
/// Simulator input only; nothing here touches the host.
@MainActor final class PreviewOrientationUITests: XCTestCase {
    /// 12 x 8 luma grid of `rect` (screenshot pixels) in `image`.
    private func grid(_ image: CGImage, rect: CGRect) -> [Double] {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var out = [Double](repeating: 0, count: 96)
        for gy in 0..<8 {
            for gx in 0..<12 {
                let x0 = Int(rect.minX + rect.width * Double(gx) / 12), x1 = Int(rect.minX + rect.width * Double(gx + 1) / 12)
                let y0 = Int(rect.minY + rect.height * Double(gy) / 8), y1 = Int(rect.minY + rect.height * Double(gy + 1) / 8)
                var sum = 0.0, n = 0.0
                for y in y0..<max(y1, y0 + 1) {
                    for x in x0..<max(x1, x0 + 1) {
                        let i = (min(y, h - 1) * w + min(x, w - 1)) * 4
                        sum += 0.3 * Double(px[i]) + 0.59 * Double(px[i + 1]) + 0.11 * Double(px[i + 2]); n += 1
                    }
                }
                out[gy * 12 + gx] = sum / n
            }
        }
        return out
    }

    private func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in a.indices { sab += (a[i] - ma) * (b[i] - mb); saa += (a[i] - ma) * (a[i] - ma); sbb += (b[i] - mb) * (b[i] - mb) }
        return sab / max((saa * sbb).squareRoot(), 1e-9)
    }

    func testMainPreviewIsUprightLikeTheFilmCard() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MIRA_SNAPSHOT"] = "1"
        app.launchEnvironment["MIRA_SNAPSHOT_TAB"] = "films"
        app.launch()

        // The selected film's card (not the preset card, whose title carries " - nickname") once its thumbnail is drawn.
        let selected = app.buttons.matching(NSPredicate(format: "isSelected == true AND NOT label CONTAINS ' - ' AND label CONTAINS ','"))
        let tabs = app.buttons["film"]
        let hide = app.buttons["chevron.down"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 20) && hide.waitForExistence(timeout: 20), "the Films tab did not appear")
        let deadline = Date().addingTimeInterval(30)
        var card: XCUIElement?
        while Date() < deadline, card == nil {
            for i in 0..<selected.count {
                let b = selected.element(boundBy: i)
                if b.frame.minY > hide.frame.maxY, b.images.count > 0 { card = b; break }
            }
            if card == nil { Thread.sleep(forTimeInterval: 0.5) }
        }
        let cardElement = try XCTUnwrap(card, "the selected film card never showed a thumbnail")
        Thread.sleep(forTimeInterval: 1)   // the main preview has long since drawn; settle any animation

        let screenshot = XCUIScreen.main.screenshot()
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "films-tab"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let out = ProcessInfo.processInfo.environment["MIRA_SNAPSHOT_OUT"], !out.isEmpty {
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: out).appendingPathComponent("films-tab.png"))
        }

        // Frames are in points of the app's window, whose origin is the screen's; the screenshot is in pixels.
        let scale = Double(image.width) / Double(screenshot.image.size.width)
        func pixels(_ r: CGRect) -> CGRect { CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale) }
        // The main photo fills the canvas between the tab bar and the panel's hide-controls button: inset a little to stay inside it.
        let canvas = CGRect(x: 8, y: tabs.frame.maxY + 8, width: app.frame.width - 16, height: hide.frame.minY - tabs.frame.maxY - 16)
        let thumbnail = cardElement.images.element(boundBy: 0).frame.insetBy(dx: 2, dy: 2)
        XCTAssertGreaterThan(thumbnail.width, 40, "the card's thumbnail frame")

        let main = grid(image, rect: pixels(canvas))
        let card12 = grid(image, rect: pixels(thumbnail))
        var flipped = [Double](repeating: 0, count: 96)
        for i in 0..<96 { flipped[i] = card12[(7 - i / 12) * 12 + i % 12] }
        let upright = correlation(main, card12), mirrored = correlation(main, flipped)
        print("UI main vs card: upright \(upright), flipped \(mirrored)")
        XCTAssertGreaterThan(upright, 0.5, "the main photo matches its film card")
        XCTAssertGreaterThan(upright, mirrored + 0.2, "the main photo is upside down against its film card (upright \(upright), flipped \(mirrored))")
    }
}
