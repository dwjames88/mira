import CoreImage
import MiraCamera
import MiraCameraKit
import MiraCore
import XCTest
@testable import Mira

/// Opt-in finder timing on the simulator host's GPU (a proxy, like docs/PERFORMANCE.md "Camera finder"):
/// TEST_RUNNER_MIRA_PERF=1 xcodebuild test ... -only-testing:MiraiOSTests/FinderBudgetSimTests
final class FinderBudgetSimTests: XCTestCase {
    func testFinderBudget() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIRA_PERF"] == "1", "set TEST_RUNNER_MIRA_PERF=1")
        let library = try XCTUnwrap(PhotoEngine.library)
        let renderer = Renderer(library: library)
        let id = try XCTUnwrap(library.films.first { $0.id.contains("portra-400") }?.id ?? library.films.first?.id)
        let recipe = Recipe(filmID: id).applyingNativeTexture(filmID: id)
        let picture = try XCTUnwrap(CIImage(contentsOf: CameraFixtures.sampleURL))
        let fit = picture.transformed(by: CGAffineTransform(scaleX: 1920 / picture.extent.width, y: 1920 / picture.extent.width))
        let cases: [(String, FinderQualityMode)] = [("full", .full), ("half texture", .halfTexture), ("grain off", .grainOff), ("reduced", .reduced)]
        var table = "| Case | 1920x1440 median / p95 ms |\n|---|---|\n"
        for (name, mode) in cases {
            let result = FinderBenchmark.run(
                frameImage: { i in
                    fit.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.0004 * Double(i % 7)])
                        .cropped(to: fit.extent).withMiraExposureTime(1.0 / 60)
                },
                size: (1920, 1440), mode: mode, recipe: recipe, renderer: renderer)
            let r = try XCTUnwrap(result, "no Metal device")
            table += String(format: "| %@ | %.1f / %.1f |\n", name, r.medianMS, r.p95MS)
        }
        print("\n\(table)")
    }
}
