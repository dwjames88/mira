#!/usr/bin/env swift
// Generates the Mira app icon and the Photos-extension icon (Field Frames palette).
// Usage: swift scripts/make-icons.swift   (run from anywhere; paths resolve from this file)
//
// Art: ink ground (#15140f), a lichen (#93a382) Cormorant Garamond "M", a thin paper hairline
// inset frame, on the macOS icon grid (824/1024 body, ~185 px corner radius at 1024).
// The extension variant adds a small lichen dot under the M.
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fontURL = root.appendingPathComponent("Packages/MiraUI/Sources/MiraUI/Resources/Fonts/CormorantGaramond-VF.ttf")
var regError: Unmanaged<CFError>?
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &regError)

let ink = CGColor(red: 0x15 / 255, green: 0x14 / 255, blue: 0x0f / 255, alpha: 1)
let lichen = CGColor(red: 0x93 / 255, green: 0xa3 / 255, blue: 0x82 / 255, alpha: 1)
let paper = CGColor(red: 0xea / 255, green: 0xe6 / 255, blue: 0xda / 255, alpha: 1)

func makeFont(size: CGFloat) -> CTFont {
    let base = CTFontDescriptorCreateWithNameAndSize("Cormorant Garamond" as CFString, size)
    let wght = 0x77676874 // 'wght'
    let desc = CTFontDescriptorCreateCopyWithVariation(base, wght as CFNumber, 500)
    return CTFontCreateWithFontDescriptor(desc, size, nil)
}

func render(pixels: Int, dot: Bool) -> CGImage {
    let s = CGFloat(pixels) / 1024
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high

    // Body: 824 x 824 centred in 1024.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow like the system template.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
    ctx.setFillColor(ink)
    ctx.addPath(shape)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.setFillColor(ink)
    ctx.fill(body)

    // Hairline inset frame.
    let frame = body.insetBy(dx: 58, dy: 58)
    ctx.setStrokeColor(paper.copy(alpha: 0.22)!)
    ctx.setLineWidth(3)
    ctx.stroke(frame)

    // The M, centred by its glyph outline.
    let font = makeFont(size: 560)
    let glyph = CTFontGetGlyphWithName(font, "M" as CFString)
    if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
        let b = path.boundingBoxOfPath
        let yOffset: CGFloat = dot ? 22 : 0
        let tx = body.midX - b.midX
        let ty = body.midY - b.midY + yOffset
        ctx.saveGState()
        ctx.translateBy(x: tx, y: ty)
        ctx.setFillColor(lichen)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        if dot {
            let r: CGFloat = 20
            let cy = body.midY - b.height / 2 + yOffset - 70
            ctx.setFillColor(lichen)
            ctx.fillEllipse(in: CGRect(x: body.midX - r, y: cy - r, width: r * 2, height: r * 2))
        }
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let sizes: [(pt: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                      (256, 1), (256, 2), (512, 1), (512, 2)]

func emit(to dir: URL, dot: Bool) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for (pt, scale) in sizes {
        let name = "icon_\(pt)x\(pt)@\(scale)x.png"
        write(render(pixels: pt * scale, dot: dot), to: dir.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: dir.appendingPathComponent("Contents.json"))
    write(render(pixels: 1024, dot: dot), to: dir.appendingPathComponent("preview-1024.png"))
}

let appSet = root.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")
let extCatalog = root.appendingPathComponent("PhotosExtension/Assets.xcassets")
let extSet = extCatalog.appendingPathComponent("AppIcon.appiconset")
try emit(to: appSet, dot: false)
try emit(to: extSet, dot: true)
try FileManager.default.createDirectory(at: extCatalog, withIntermediateDirectories: true)
try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: extCatalog.appendingPathComponent("Contents.json"))
// preview-1024.png is for eyeballing only; keep it out of the asset sets.
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
for (set, name) in [(appSet, "mira-icon-app.png"), (extSet, "mira-icon-ext.png")] {
    let dst = tmp.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: dst)
    try? FileManager.default.moveItem(at: set.appendingPathComponent("preview-1024.png"), to: dst)
}
print("Icons written. Previews in \(NSTemporaryDirectory())")
