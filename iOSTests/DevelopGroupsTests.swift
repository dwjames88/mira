import MiraCore
import MiraUI
import SwiftUI
import XCTest
@testable import Mira

@MainActor
final class DevelopGroupsTests: XCTestCase {
    private var allSupported: RawSupportedControls {
        var s = RawSupportedControls()
        s.localToneMap = true; s.luminanceNoiseReduction = true; s.colorNoiseReduction = true
        s.sharpness = true; s.lensCorrection = true
        return s
    }

    private func rawModel(asShot: (temperature: Double, tint: Double) = (5200, 8)) -> EditorViewModel {
        let m = EditorViewModel()
        m.setRawInfoForTesting(asShot: asShot, supported: allSupported)
        return m
    }

    private func grouped(_ items: [Adjustment]) -> [(String, [String])] {
        var out: [(String, [String])] = []
        for i in items {
            if out.last?.0 == i.group { out[out.count - 1].1.append(i.id) } else { out.append((i.group, [i.id])) }
        }
        return out
    }

    func testNonRawChipGroupsFollowSectionOrderWithoutRawChips() {
        let g = grouped(Adjustment.all(raw: .none))
        XCTAssertEqual(g.map(\.0), ["Light", "White balance", "Color", "Detail", "Lens", "Film", "Frame"])
        XCTAssertEqual(g.map(\.0), DevelopSection.allCases.map(\.title))
        XCTAssertEqual(g[0].1, ["exposure", "contrast", "highlights", "shadows", "whites", "blacks"])
        XCTAssertEqual(g[1].1, ["temperature", "tint"])
        XCTAssertEqual(g[2].1, ["vibrance", "saturation", "curves", "mixer"])
        XCTAssertEqual(g[3].1, ["texture", "clarity"])
        XCTAssertEqual(g[4].1, ["vignette"])
        XCTAssertEqual(g[5].1, ["grain", "grainSize", "halation", "halationRadius", "bloom"])
        XCTAssertEqual(g[6].1, ["border"])
    }

    func testRawChipsAppearOnlyForRawAndOnlyWhenSupported() {
        let g = grouped(Adjustment.all(raw: RawControlVisibility(isRaw: true, supported: allSupported)))
        XCTAssertEqual(g.map(\.0), DevelopSection.allCases.map(\.title))
        XCTAssertEqual(g[0].1.suffix(3), ["boost", "highlightRecovery", "localToneMap"])
        XCTAssertEqual(g[3].1, ["texture", "clarity", "sharpness", "lumNoise", "colorNoise"])
        XCTAssertEqual(g[4].1, ["lensCorrection", "vignette"])
        XCTAssertEqual(g[1].1, ["temperature", "tint"], "one white balance pair")

        let minimal = Adjustment.all(raw: RawControlVisibility(isRaw: true, supported: RawSupportedControls())).map(\.id)
        XCTAssertTrue(minimal.contains("boost") && minimal.contains("highlightRecovery"))
        XCTAssertFalse(minimal.contains("localToneMap") || minimal.contains("sharpness") || minimal.contains("lensCorrection"))
    }

    func testNoRawOrOldGroupNamesInChipsOrTitles() {
        for raw in [RawControlVisibility.none, RawControlVisibility(isRaw: true, supported: allSupported)] {
            for i in Adjustment.all(raw: raw) {
                XCTAssertFalse(i.group.localizedCaseInsensitiveContains("raw"))
                XCTAssertFalse(i.title.localizedCaseInsensitiveContains("raw"))
                XCTAssertFalse(["Presence", "Effects"].contains(i.group))
            }
        }
    }

    func testRawInfoOnlyForRawAndClearedByPresentAndClose() {
        let m = EditorViewModel()
        XCTAssertFalse(m.rawControls.isRaw)
        XCTAssertNil(m.rawAsShot)
        m.setRawInfoForTesting(asShot: (5200, 8), supported: allSupported)
        XCTAssertTrue(m.rawControls.isRaw)
        XCTAssertEqual(m.rawAsShot?.temperature, 5200)
        m.closePhoto()
        XCTAssertFalse(m.rawControls.isRaw)
        XCTAssertNil(m.rawAsShot)
    }

    func testWhiteBalanceDrivesPipelineForNonRaw() {
        let m = EditorViewModel()
        XCTAssertEqual(m.bindTemperature().wrappedValue, PipelineWhiteBalance.neutralKelvin)
        m.bindTemperature().wrappedValue = 7000
        XCTAssertNotEqual(m.recipe.warmth, 0)
        XCTAssertNil(m.recipe.raw.temperature)
        XCTAssertEqual(m.bindTemperature().wrappedValue, 7000, accuracy: 1)
        m.bindTint().wrappedValue = 10
        XCTAssertNotEqual(m.recipe.tint, 0)
        XCTAssertEqual(m.bindTint().wrappedValue, 10, accuracy: 0.5)
    }

    func testWhiteBalanceDrivesDecoderForRaw() {
        let m = rawModel()
        XCTAssertEqual(m.bindTemperature().wrappedValue, 5200)
        XCTAssertEqual(m.bindTint().wrappedValue, 8)
        m.bindTemperature().wrappedValue = 4300
        m.bindTint().wrappedValue = -12
        XCTAssertEqual(m.recipe.raw.temperature, 4300)
        XCTAssertEqual(m.recipe.raw.tint, -12)
        XCTAssertEqual(m.recipe.warmth, 0)
        XCTAssertEqual(m.recipe.tint, 0)
        // Moving back onto the as-shot value clears the setting.
        m.bindTemperature().wrappedValue = 5200
        XCTAssertNil(m.recipe.raw.temperature)
    }

    func testAsShotClearsBothAndResetAllDropsRawSettings() {
        let m = rawModel()
        m.bindTemperature().wrappedValue = 4300
        m.bindTint().wrappedValue = 20
        m.recipe.warmth = 0.3
        XCTAssertFalse(m.whiteBalance.isAsShot(m.recipe))
        XCTAssertFalse(m.whiteBalance.temperatureIsAsShot(m.recipe))
        m.resetWhiteBalance()
        XCTAssertTrue(m.whiteBalance.isAsShot(m.recipe))
        XCTAssertNil(m.recipe.raw.temperature)
        XCTAssertNil(m.recipe.raw.tint)
        XCTAssertEqual(m.recipe.warmth, 0)

        m.recipe.raw.boostAmount = 0.9
        m.recipe.raw.lensCorrection = true
        m.resetDevelop()
        XCTAssertEqual(m.recipe.raw, RawSettings.identity)
    }

    func testDecodeBindingIsNilOnFallback() {
        let m = rawModel()
        let b = m.bindRaw(\.boostAmount, fallback: 0.5)
        XCTAssertEqual(b.wrappedValue, 0.5)
        b.wrappedValue = 0.8
        XCTAssertEqual(m.recipe.raw.boostAmount, 0.8)
        b.wrappedValue = 0.5
        XCTAssertNil(m.recipe.raw.boostAmount)
    }

    // MARK: Snapshots

    private let wide = TestDevice(name: "wide", size: CGSize(width: 2700, height: 260), scale: 1, topInset: 0, bottomInset: 0)

    func testDevelopPanelSnapshots() async {
        for d in TestDevice.all {
            let plain = EditorViewModel()
            await Snapshot.render(DevelopPanel(model: plain, focus: "temperature").frame(maxHeight: .infinity, alignment: .bottom),
                                  device: d, name: "develop-groups-nonraw-temperature")
            let raw = rawModel()
            raw.recipe.raw.temperature = 4300
            await Snapshot.render(DevelopPanel(model: raw, focus: "temperature").frame(maxHeight: .infinity, alignment: .bottom),
                                  device: d, name: "develop-groups-raw-temperature")
            await Snapshot.render(DevelopPanel(model: raw, focus: "boost").frame(maxHeight: .infinity, alignment: .bottom),
                                  device: d, name: "develop-groups-raw-boost")
        }
        let plain = EditorViewModel()
        await Snapshot.render(DevelopPanel(model: plain, focus: "tint").frame(maxHeight: .infinity, alignment: .bottom),
                              device: wide, name: "develop-groups-strip-nonraw")
        let raw = rawModel()
        await Snapshot.render(DevelopPanel(model: raw, focus: "lensCorrection").frame(maxHeight: .infinity, alignment: .bottom),
                              device: wide, name: "develop-groups-strip-raw")
    }
}
