import AppKit
import SwiftUI
import Testing
@testable import EmulsionUI

@Suite("Field Frames theme")
struct ThemeTests {
    /// The CSS values, `[name: (dark, light)]`, written out independently of the implementation.
    static let expected: [String: (dark: String, light: String)] = [
        "ink": ("#15140f", "#e9e5d9"),
        "inkSoft": ("#1d1b15", "#ded9cc"),
        "paper": ("#e9e5d9", "#15140f"),
        "paperSoft": ("#d6d1c4", "#2a2820"),
        "paperMid": ("#c9c4b6", "#4a473e"),
        "paperDim": ("#9c988b", "#5c584d"),
        "lichen": ("#93a382", "#54644a"),
        "hair": ("#e9e5d9", "#15140f"),
        "backdrop": ("#0c0b08", "#f0ede5"),
        "onPhoto": ("#e9e5d9", "#e9e5d9"),
        "onPhotoSoft": ("#d6d1c4", "#d6d1c4"),
        "onPhotoMid": ("#c9c4b6", "#c9c4b6"),
        "onPhotoDim": ("#9c988b", "#9c988b"),
        "onPhotoAccent": ("#93a382", "#93a382"),
        "onPhotoVeil": ("#0c0b08", "#0c0b08"),
    ]
    static let alphas: [String: Double] = ["hair": 0.12, "backdrop": 0.96, "onPhotoVeil": 0.58]

    private func resolve(_ color: NSColor, _ name: NSAppearance.Name) -> (hex: String, alpha: Double) {
        var out = (hex: "", alpha: 0.0)
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            func b(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
            out = (String(format: "#%02x%02x%02x", b(c.redComponent), b(c.greenComponent), b(c.blueComponent)),
                   Double(c.alphaComponent))
        }
        return out
    }

    @Test func everyTokenHasExactValuesInBothAppearances() {
        #expect(FieldFramesTheme.tokens.count == Self.expected.count)
        for (name, values) in Self.expected {
            let token = FieldFramesTheme.token(named: name)
            #expect(token != nil, "missing token \(name)")
            guard let token else { continue }
            let alpha = Self.alphas[name] ?? 1
            #expect(token.dark.hex == values.dark && token.light.hex == values.light, "table \(name)")
            let dark = resolve(token.nsColor, .darkAqua)
            let light = resolve(token.nsColor, .aqua)
            #expect(dark.hex == values.dark, "\(name) dark: \(dark.hex)")
            #expect(light.hex == values.light, "\(name) light: \(light.hex)")
            #expect(abs(dark.alpha - alpha) < 0.005 && abs(light.alpha - alpha) < 0.005, "\(name) alpha")
        }
    }

    @Test func cssNamesAreCustomProperties() {
        for t in FieldFramesTheme.tokens { #expect(t.css.hasPrefix("--")) }
    }

    @Test func fontsRegisterAndResolve() {
        #expect(FieldFramesTheme.registerFonts())
        #expect(FieldFramesTheme.registerFonts()) // idempotent
        for name in [FieldFramesTheme.displayRegularName, FieldFramesTheme.displayItalicName,
                     FieldFramesTheme.monoRegularName, FieldFramesTheme.monoMediumName,
                     FieldFramesTheme.monoSemiBoldName] {
            #expect(NSFont(name: name, size: 12) != nil, "\(name) did not resolve")
        }
        #expect(FieldFramesTheme.displayNSFont(26, weight: .medium).familyName == "Cormorant Garamond")
        #expect(FieldFramesTheme.monoNSFont(10).familyName == "IBM Plex Mono")
        #expect(FieldFramesTheme.monoNSFont(10, weight: .semibold).fontName == "IBMPlexMono-SemiBold")
    }

    @Test func displayWeightAxisApplies() {
        func weight(_ w: Font.Weight) -> Double {
            let f = FieldFramesTheme.displayNSFont(40, weight: w)
            let vars = CTFontCopyVariation(f) as? [Int: Double]
            return vars?[0x7767_6874] ?? -1
        }
        #expect(weight(.regular) == 400)
        #expect(weight(.semibold) == 600)
    }

    @Test func cellGrid() {
        #expect(FieldFramesTheme.cellW == 8 && FieldFramesTheme.cellH == 16)
        #expect(FieldFramesTheme.cells(3) == 24)
        #expect(FieldFramesTheme.rows(2) == 32)
    }

    @Test func grainTileIsGeneratedAndNotUniform() {
        let n = FFGrain.tileSize
        #expect(n == 256)
        for white in [true, false] {
            let tile = FFGrain.tile(white: white)
            #expect(tile.width == n && tile.height == n)
        }
        let mask = FFGrain.alphaMask
        #expect(mask.count == n * n)
        let mean = Double(mask.reduce(0) { $0 + Int($1) }) / Double(mask.count)
        let variance = mask.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(mask.count)
        #expect(variance.squareRoot() > 8, "grain is flat")
        #expect(Set(mask).count > 32)
        #expect(mean > 20 && mean < 90, "mean alpha \(mean)")
        // Deterministic.
        #expect(FFGrain.alphaMask == mask)
    }
}
