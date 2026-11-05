import Foundation
import Testing
@testable import MiraCameraKit

private struct LensFixture: Decodable {
    var device: String
    var source: String
    var descriptor: LensDescriptor
    var expectedLabels: [String]
    var expectedZoomFactors: [Double]
    var expectedCropIndex: Int

    static func load(_ name: String) throws -> LensFixture {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(LensFixture.self, from: Data(contentsOf: url))
    }
}

@Suite struct LensCatalogTests {
    @Test(arguments: ["lenses-15pro", "lenses-16pro", "lenses-17pro"])
    func fixtureDevices(_ name: String) throws {
        let f = try LensFixture.load(name)
        #expect(f.source.contains("[ASSUMPTION]"))
        let lenses = LensCatalog.lenses(for: f.descriptor)
        #expect(lenses.map(\.label) == f.expectedLabels)
        #expect(lenses.map(\.zoomFactor) == f.expectedZoomFactors)
        #expect(lenses.map(\.isCrop) == f.expectedLabels.indices.map { $0 == f.expectedCropIndex })
    }

    @Test func sixteenProChips() throws {
        let lenses = LensCatalog.lenses(for: try LensFixture.load("lenses-16pro").descriptor)
        #expect(lenses.map(\.equivalentMM) == [13, 24, 48, 120])
        #expect(lenses.map(\.zoomFactor) == [1, 2, 4, 10])
        #expect(lenses[2].isCrop && lenses[2].accessibilityLabel.contains("cropped"))
        #expect(lenses[3].accessibilityLabel == "120 millimeter lens")
    }

    @Test func equivalentFromFieldOfView() {
        // A 24 mm equivalent on a 4:3 sensor, by the diagonal convention.
        let h = 71.5958
        #expect(abs(LensCatalog.equivalentMM(horizontalFOVDegrees: h) - 24) < 0.01)
    }

    @Test func singleWideDevice() {
        // One wide camera, zoom 1 is the main lens (display multiplier 1): 24 mm, plus a 2x crop.
        let d = LensDescriptor(fieldOfViewDegrees: 71.5958, displayZoomMultiplier: 1, minZoom: 1, maxZoom: 10, constituentCount: 1)
        let lenses = LensCatalog.lenses(for: d)
        #expect(lenses.map(\.equivalentMM) == [24, 48])
        #expect(lenses.map(\.zoomFactor) == [1, 2])
        #expect(lenses.map(\.isCrop) == [false, true])
    }

    @Test func dualWideDevice() {
        // Ultra-wide + wide: zoom 1 is the ultra-wide, the wide at 2, its crop at 4.
        let d = LensDescriptor(
            fieldOfViewDegrees: 106.1797, constituentFieldsOfView: [106.1797, 71.5958], switchOverZoomFactors: [2],
            displayZoomMultiplier: 0.5, minZoom: 1, maxZoom: 10, constituentCount: 2)
        let lenses = LensCatalog.lenses(for: d)
        #expect(lenses.map(\.equivalentMM) == [13, 24, 48])
        #expect(lenses.map(\.zoomFactor) == [1, 2, 4])
        #expect(lenses.map(\.isCrop) == [false, false, true])
    }

    @Test func cropIsDroppedWhenBeyondMaxZoomOrNextToATele() {
        var d = LensDescriptor(fieldOfViewDegrees: 71.5958, minZoom: 1, maxZoom: 1.5, constituentCount: 1)
        #expect(LensCatalog.lenses(for: d).map(\.equivalentMM) == [24])
        // A 2x tele (48 mm) makes the 2x crop redundant.
        d = LensDescriptor(
            fieldOfViewDegrees: 71.5958, constituentFieldsOfView: [71.5958, 40.5], switchOverZoomFactors: [2],
            displayZoomMultiplier: 1, minZoom: 1, maxZoom: 10, constituentCount: 2)
        let eq = LensCatalog.lenses(for: d)
        #expect(eq.count == 2 && !eq.contains(where: \.isCrop))
        #expect(LensCatalog.lenses(for: LensDescriptor(fieldOfViewDegrees: 0)).isEmpty)
    }

    @Test func equivalentAtZoomForPinch() throws {
        let d = try LensFixture.load("lenses-16pro").descriptor
        #expect(LensCatalog.equivalent(atZoom: 1, for: d) == 13)
        #expect(LensCatalog.equivalent(atZoom: 2, for: d) == 24)
        #expect(LensCatalog.equivalent(atZoom: 4, for: d) == 48)
        #expect(LensCatalog.equivalent(atZoom: 10, for: d) == 120)
        #expect(LensCatalog.equivalent(atZoom: 20, for: d) == 240)
        #expect(LensCatalog.equivalent(atZoom: 0.5, for: d) == 13)
        #expect(LensCatalog.displayZoom(2, for: d) == 1)
    }
}

@Suite struct CaptureFormatPolicyTests {
    let sizes = [PixelSize(width: 4032, height: 3024), PixelSize(width: 8064, height: 6048), PixelSize(width: 2016, height: 1512)]

    @Test func twelveMegapixelAndProRAW() {
        let caps = CaptureCapabilities(supportedPhotoDimensions: sizes, isProRAWSupported: true, isShutterSoundSuppressionSupported: true)
        let f = CaptureFormatPolicy.format(for: caps, settings: CameraSettings())
        #expect(f.maxDimensions == PixelSize(width: 4032, height: 3024))
        #expect(f.useProRAW && f.rawBase)
        #expect(f.prioritization == .balanced)
        #expect(f.zeroShutterLag)
    }

    @Test func heicOnlyWithoutProRAW() {
        let f = CaptureFormatPolicy.format(for: CaptureCapabilities(supportedPhotoDimensions: sizes), settings: CameraSettings())
        #expect(!f.useProRAW && !f.rawBase)
    }

    @Test func silentShutterNeedsSettingAndSupport() {
        var s = CameraSettings()
        let supported = CaptureCapabilities(supportedPhotoDimensions: sizes, isShutterSoundSuppressionSupported: true)
        let unsupported = CaptureCapabilities(supportedPhotoDimensions: sizes, isShutterSoundSuppressionSupported: false)
        #expect(!CaptureFormatPolicy.format(for: supported, settings: s).suppressShutterSound)
        s.silentShutter = true
        #expect(CaptureFormatPolicy.format(for: supported, settings: s).suppressShutterSound)
        #expect(!CaptureFormatPolicy.format(for: unsupported, settings: s).suppressShutterSound)
    }

    @Test func dimensionFallbacks() {
        #expect(CaptureFormatPolicy.twelveMegapixelDimensions(in: []) == PixelSize(width: 4032, height: 3024))
        #expect(CaptureFormatPolicy.twelveMegapixelDimensions(in: [PixelSize(width: 4000, height: 3000)]) == PixelSize(width: 4000, height: 3000))
        let big = [PixelSize(width: 8064, height: 6048), PixelSize(width: 6048, height: 4032)]
        #expect(CaptureFormatPolicy.twelveMegapixelDimensions(in: big) == PixelSize(width: 6048, height: 4032))
        #expect(PixelSize(width: 4032, height: 3024).megapixels > 12 && PixelSize(width: 4032, height: 3024).megapixels < 12.2)
    }
}

@Suite struct WhiteBalanceTests {
    @Test func presets() {
        #expect(WhiteBalancePreset.allCases.map(\.kelvin) == [nil, 5500, 6500, 3200, 4000])
        #expect(WhiteBalancePreset.allCases.map(\.label) == ["AUTO", "DAYLIGHT 5500", "CLOUDY 6500", "TUNGSTEN 3200", "FLUOR. 4000"])
        #expect(WhiteBalancePreset.allCases.allSatisfy { !$0.accessibilityLabel.isEmpty })
    }

    @Test func state() {
        #expect(!WhiteBalanceState().isFixed)
        #expect(WhiteBalanceState(preset: .auto, locked: true).isFixed)
        #expect(WhiteBalanceState(preset: .tungsten).isFixed)
    }
}

@Suite struct ReadinessTests {
    @Test func dimmingAndPress() {
        #expect(ShutterReadiness.notReadyWaitingForProcessing.dimsShutter)
        #expect(ShutterReadiness.sessionNotRunning.dimsShutter)
        #expect(!ShutterReadiness.ready.dimsShutter)
        #expect(!ShutterReadiness.notReadyMomentarily.dimsShutter)
        #expect(!ShutterReadiness.notReadyWaitingForCapture.dimsShutter)
        #expect(ShutterReadiness.ready.acceptsPress)
        #expect(!ShutterReadiness.notReadyMomentarily.acceptsPress)
        #expect(!ShutterReadiness.sessionNotRunning.acceptsPress)
    }

    @Test func hardwareShutterFiresOnEndedOnly() {
        #expect(HardwareShutter.shouldFire(phase: .ended))
        #expect(!HardwareShutter.shouldFire(phase: .began))
        #expect(!HardwareShutter.shouldFire(phase: .cancelled))
    }
}
