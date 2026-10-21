import AppKit
import CoreText
import SwiftUI

// MARK: Tokens

/// An sRGB colour as 8-bit hex plus alpha. Kept as plain values so tests and docs can read them.
public struct FFRGBA: Equatable, Sendable {
    public let hex: String
    public let alpha: Double

    public init(_ hex: String, alpha: Double = 1) {
        self.hex = hex
        self.alpha = alpha
    }

    public var components: (r: Double, g: Double, b: Double) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    var nsColor: NSColor {
        let c = components
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }
}

/// One entry of the Field Frames palette: a CSS custom property with its dark and light value.
/// Dark is the identity; light is the CSS `light-dark()` light branch.
public struct FFToken: Sendable {
    /// Swift-side name, e.g. `paperDim`.
    public let name: String
    /// CSS custom property, e.g. `--paper-dim`.
    public let css: String
    public let dark: FFRGBA
    public let light: FFRGBA

    /// Dynamic colour following the appearance of the view or window it is drawn in.
    public var nsColor: NSColor {
        let dark = dark.nsColor, light = light.nsColor
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    public var color: Color { Color(nsColor: nsColor) }

    public func value(dark isDark: Bool) -> FFRGBA { isDark ? dark : light }
}

// MARK: Theme

/// The Field Frames look: a quiet gallery. Dark ink ground, warm paper text, one accent (lichen),
/// Cormorant Garamond display, IBM Plex Mono labels, hairlines, grain, a character-cell grid.
public enum FieldFramesTheme {
    // Token table: styles.css lines 25-45.
    public static let inkToken = FFToken(name: "ink", css: "--ink", dark: .init("#15140f"), light: .init("#e9e5d9"))
    public static let inkSoftToken = FFToken(name: "inkSoft", css: "--ink-soft", dark: .init("#1d1b15"), light: .init("#ded9cc"))
    public static let paperToken = FFToken(name: "paper", css: "--paper", dark: .init("#e9e5d9"), light: .init("#15140f"))
    public static let paperSoftToken = FFToken(name: "paperSoft", css: "--paper-soft", dark: .init("#d6d1c4"), light: .init("#2a2820"))
    public static let paperMidToken = FFToken(name: "paperMid", css: "--paper-mid", dark: .init("#c9c4b6"), light: .init("#4a473e"))
    public static let paperDimToken = FFToken(name: "paperDim", css: "--paper-dim", dark: .init("#9c988b"), light: .init("#5c584d"))
    public static let lichenToken = FFToken(name: "lichen", css: "--lichen", dark: .init("#93a382"), light: .init("#54644a"))
    /// `rgb(from var(--paper) r g b / 0.12)`: paper at 12%.
    public static let hairToken = FFToken(name: "hair", css: "--hair", dark: .init("#e9e5d9", alpha: 0.12), light: .init("#15140f", alpha: 0.12))
    public static let backdropToken = FFToken(name: "backdrop", css: "--backdrop", dark: .init("#0c0b08", alpha: 0.96), light: .init("#f0ede5", alpha: 0.96))

    /// Non-flipping colours for type that sits on a photograph (`--on-photo*`): the dark values in both themes.
    public static let onPhotoToken = FFToken(name: "onPhoto", css: "--on-photo", dark: .init("#e9e5d9"), light: .init("#e9e5d9"))
    public static let onPhotoSoftToken = FFToken(name: "onPhotoSoft", css: "--on-photo-soft", dark: .init("#d6d1c4"), light: .init("#d6d1c4"))
    public static let onPhotoMidToken = FFToken(name: "onPhotoMid", css: "--on-photo-mid", dark: .init("#c9c4b6"), light: .init("#c9c4b6"))
    public static let onPhotoDimToken = FFToken(name: "onPhotoDim", css: "--on-photo-dim", dark: .init("#9c988b"), light: .init("#9c988b"))
    public static let onPhotoAccentToken = FFToken(name: "onPhotoAccent", css: "--on-photo-accent", dark: .init("#93a382"), light: .init("#93a382"))
    public static let onPhotoVeilToken = FFToken(name: "onPhotoVeil", css: "--on-photo-veil", dark: .init("#0c0b08", alpha: 0.58), light: .init("#0c0b08", alpha: 0.58))

    /// Every token, for tests and docs.
    public static let tokens: [FFToken] = [
        inkToken, inkSoftToken, paperToken, paperSoftToken, paperMidToken, paperDimToken, lichenToken,
        hairToken, backdropToken,
        onPhotoToken, onPhotoSoftToken, onPhotoMidToken, onPhotoDimToken, onPhotoAccentToken, onPhotoVeilToken,
    ]

    public static func token(named name: String) -> FFToken? { tokens.first { $0.name == name } }

    // Colours (dynamic: they follow the system appearance).
    public static var ink: Color { inkToken.color }
    public static var inkSoft: Color { inkSoftToken.color }
    public static var paper: Color { paperToken.color }
    public static var paperSoft: Color { paperSoftToken.color }
    public static var paperMid: Color { paperMidToken.color }
    public static var paperDim: Color { paperDimToken.color }
    public static var lichen: Color { lichenToken.color }
    public static var hair: Color { hairToken.color }
    public static var backdrop: Color { backdropToken.color }
    public static var onPhoto: Color { onPhotoToken.color }
    public static var onPhotoSoft: Color { onPhotoSoftToken.color }
    public static var onPhotoMid: Color { onPhotoMidToken.color }
    public static var onPhotoDim: Color { onPhotoDimToken.color }
    public static var onPhotoAccent: Color { onPhotoAccentToken.color }
    public static var onPhotoVeil: Color { onPhotoVeilToken.color }

    // MARK: Grid

    /// One character cell, in points. The site derives its cell from the viewport; the app fixes it.
    public static let cellW: CGFloat = 8
    public static let cellH: CGFloat = 16

    /// A width of `n` character cells.
    public static func cells(_ n: CGFloat) -> CGFloat { n * cellW }
    /// A height of `n` character rows.
    public static func rows(_ n: CGFloat) -> CGFloat { n * cellH }

    // MARK: Fonts

    public static let displayFamily = "Cormorant Garamond"
    public static let monoFamily = "IBM Plex Mono"

    /// PostScript names the theme uses; the display faces are variable fonts (weight axis 300-700).
    public static let displayRegularName = "CormorantGaramond-Regular"
    public static let displayItalicName = "CormorantGaramond-Italic"
    public static let monoRegularName = "IBMPlexMono-Regular"
    public static let monoMediumName = "IBMPlexMono-Medium"
    public static let monoSemiBoldName = "IBMPlexMono-SemiBold"

    private static let fontsRegistered: Bool = {
        guard let dir = Bundle.module.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return false }
        let urls = files.filter { $0.pathExtension.lowercased() == "ttf" }
        guard !urls.isEmpty else { return false }
        // Errors for faces already registered (kCTFontManagerErrorAlreadyRegistered) are expected and harmless.
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        return true
    }()

    /// Registers the bundled fonts for this process. Idempotent and safe from any thread; call at app
    /// start and when the extension loads its view.
    @discardableResult
    public static func registerFonts() -> Bool { fontsRegistered }

    /// Cormorant Garamond at an exact weight (the font is a variable font).
    public static func displayNSFont(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> NSFont {
        registerFonts()
        let axis = 0x7767_6874 // 'wght'
        let wght = variationWeight(weight)
        let name = italic ? displayItalicName : displayRegularName
        let descriptor = NSFontDescriptor(fontAttributes: [
            .name: name,
            .size: size,
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [axis: wght],
        ])
        return NSFont(descriptor: descriptor, size: size)
            ?? NSFont(name: name, size: size)
            ?? NSFont(name: "Georgia", size: size)
            ?? .systemFont(ofSize: size)
    }

    /// IBM Plex Mono at Regular, Medium or SemiBold (other weights snap to the nearest).
    public static func monoNSFont(_ size: CGFloat, weight: Font.Weight = .regular) -> NSFont {
        registerFonts()
        let name: String
        switch variationWeight(weight) {
        case ..<450: name = monoRegularName
        case ..<550: name = monoMediumName
        default: name = monoSemiBoldName
        }
        return NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Cormorant Garamond display type.
    public static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(displayNSFont(size, weight: weight))
    }

    /// Cormorant Garamond italic.
    public static func displayItalic(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(displayNSFont(size, weight: weight, italic: true))
    }

    /// IBM Plex Mono.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(monoNSFont(size, weight: weight))
    }

    /// Letter spacing of the house label, in em (`styles.css`: 0.08em to 0.14em).
    public static let labelTracking: CGFloat = 0.1

    private static func variationWeight(_ weight: Font.Weight) -> Double {
        switch weight {
        case .ultraLight, .thin, .light: 300
        case .regular: 400
        case .medium: 500
        case .semibold: 600
        default: 700
        }
    }
}

// MARK: Type roles

private struct FFLabelModifier: ViewModifier {
    let size: CGFloat
    let color: Color?
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content
            .font(FieldFramesTheme.mono(size, weight: weight))
            .textCase(.uppercase)
            .tracking(size * FieldFramesTheme.labelTracking)
            .foregroundStyle(color ?? FieldFramesTheme.paperDim)
    }
}

extension View {
    /// The house label: small uppercase tracked IBM Plex Mono in paper-dim.
    public func ffLabel(size: CGFloat = 10, color: Color? = nil, weight: Font.Weight = .regular) -> some View {
        modifier(FFLabelModifier(size: size, color: color, weight: weight))
    }

    /// Cormorant Garamond display type in paper.
    public func ffDisplay(_ size: CGFloat, weight: Font.Weight = .regular, color: Color? = nil) -> some View {
        font(FieldFramesTheme.display(size, weight: weight))
            .foregroundStyle(color ?? FieldFramesTheme.paper)
    }

    /// Window chrome: ink ground with grain behind the content, system appearance, lichen tint.
    /// The grain sits under the content, so a photograph drawn on top is never overlaid.
    public func fieldFramesWindow() -> some View {
        self
            .foregroundStyle(FieldFramesTheme.paper)
            .tint(FieldFramesTheme.lichen)
            .background { FFGroundBackground(base: FieldFramesTheme.ink, grain: 0.07) }
            .preferredColorScheme(nil)
            .onAppear { FieldFramesTheme.registerFonts() }
    }
}
