import MiraCamera
import MiraCameraKit
import MiraCore
import SwiftUI
import XCTest
@testable import Mira

private struct TestOriginKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

@MainActor
final class CameraLayoutTests: XCTestCase {
    func makeModel() -> CameraModel {
        let log = CallRecorder()
        let model = CameraModel(
            printWriter: StubPrintWriter(log: log), renderer: nil, initialRecipe: Recipe(),
            backend: (FakeCaptureDevice(fixtureURL: CameraFixtures.sampleURL), FakeFrameSource(fixtureURL: CameraFixtures.sampleURL)),
            library: StubLibrary(level: .full, log: log), baker: StubBaker(),
            settingsStore: CameraSettingsStore(defaults: UserDefaults(suiteName: "mira.camera.layout.\(UUID().uuidString)")!),
            pendingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("cam-\(UUID().uuidString)"))
        model.lenses = LensCatalog.lenses(for: FakeCaptureDevice.sixteenPro)
        model.selectedLens = model.lenses[1]
        model.readiness = .ready
        model.readoutText = "1/125 \u{00B7} ISO 64 \u{00B7} \u{0192}1.8"
        model.needle = -0.2
        model.latitude = LatitudeReadout(reading: LatitudeReading(under: 0.04, over: 0.03, underStops: 0.2, overStops: 0.1))
        model.developingCount = 2
        model.evBias = 1.0 / 3
        return model
    }

    func render(_ device: TestDevice, name: String) async -> [String: CGRect] {
        let box = FrameBox()
        let model = makeModel()
        let view = CameraView(model: model, filmName: "Kodak Portra 400", onClose: {}, onLayout: { box.frames = $0 }) { _ in
            Color.clear
        }
        await Snapshot.render(view, device: device, name: name, settle: .milliseconds(1500))
        await model.stop()
        return box.frames
    }

    func assertNoOverlap(_ f: [String: CGRect], _ ids: [String], file: StaticString = #filePath, line: UInt = #line) {
        for (i, a) in ids.enumerated() {
            for b in ids[(i + 1)...] {
                guard let ra = f[a], let rb = f[b] else { return XCTFail("missing \(a) or \(b): \(f.keys.sorted())", file: file, line: line) }
                XCTAssertFalse(ra.insetBy(dx: 0.5, dy: 0.5).intersects(rb.insetBy(dx: 0.5, dy: 0.5)), "\(a) overlaps \(b): \(ra) \(rb)", file: file, line: line)
            }
        }
    }

    func testPortrait() async {
        for d in TestDevice.all {
            let f = await render(d, name: "camera")
            let usable = CGSize(width: d.size.width, height: d.size.height - d.topInset - d.bottomInset)
            XCTAssertEqual(f["header"]?.height ?? 0, 48, accuracy: 0.5, "header is 48 pt on \(d.name)")
            XCTAssertEqual(f["shutter"]?.width ?? 0, 72, accuracy: 0.5)
            XCTAssertEqual(f["shutter"]?.height ?? 0, 72, accuracy: 0.5)
            guard let finder = f["finder"] else { return XCTFail("no finder frame") }
            XCTAssertEqual(finder.width, d.size.width, accuracy: 0.5, "finder spans the width")
            XCTAssertGreaterThan(finder.height, usable.height * 0.4, "finder keeps real room on \(d.name)")
            // The frame is shown 3:4 upright: the picture fits the finder without cropping.
            let fit = FinderGeometry.fitRect(aspect: 3.0 / 4, in: finder.size)
            XCTAssertLessThanOrEqual(fit.width, finder.width + 0.5)
            XCTAssertLessThanOrEqual(fit.height, finder.height + 0.5)
            assertNoOverlap(f, ["header", "meter", "finder", "lenses", "ev", "wb", "bottom"])
            XCTAssertEqual(f["wb"]!.height, f["ev"]!.height, accuracy: 0.5, "WB row as tall as the EV row on \(d.name)")
            XCTAssertLessThanOrEqual(f["bottom"]!.maxY, usable.height + 0.5, "bottom row stays on screen on \(d.name)")
            XCTAssertLessThanOrEqual(f["thumb"]!.maxX, f["shutter"]!.minX, "thumb left of the shutter")
            XCTAssertEqual(f["shutter"]!.midX, usable.width / 2, accuracy: 1, "shutter centered")
            for id in ["header", "meter", "finder", "lenses", "ev", "wb", "bottom"] {
                XCTAssertGreaterThanOrEqual(f[id]!.minX, -0.5)
                XCTAssertLessThanOrEqual(f[id]!.maxX, usable.width + 0.5, "\(id) inside the width")
            }
        }
    }

    func testLandscape() async {
        let d = TestDevice.iPhone16ProLandscape
        let f = await render(d, name: "camera")
        let usable = CGSize(width: d.size.width, height: d.size.height - d.topInset - d.bottomInset)
        guard let finder = f["finder"], let shutter = f["shutter"], let meter = f["meter"] else { return XCTFail("missing frames \(f.keys.sorted())") }
        XCTAssertEqual(shutter.width, 72, accuracy: 0.5)
        XCTAssertGreaterThan(finder.width, finder.height, "the finder takes the long side")
        XCTAssertLessThan(meter.maxX, finder.minX + 0.5, "meter on the left edge")
        XCTAssertGreaterThan(shutter.minX, finder.maxX - 0.5, "shutter column on the right")
        assertNoOverlap(f, ["header", "meter", "lenses", "ev", "wb"])
        XCTAssertLessThanOrEqual(f["wb"]!.maxY, usable.height + 0.5)
        XCTAssertEqual(f["wb"]!.height, f["ev"]!.height, accuracy: 0.5, "WB row as tall as the EV row")
        XCTAssertGreaterThan(f["wb"]!.minY, f["ev"]!.minY, "WB under EV")
        XCTAssertLessThanOrEqual(f["wb"]!.maxX, 210.5, "WB in the left column")
        XCTAssertLessThanOrEqual(shutter.maxY, usable.height + 0.5)
    }

    /// The header (and everything else) sits below the status bar / Dynamic Island: hosted with a real top safe-area
    /// inset (not padding), the content must respect it while the background may extend under it.
    func testChromeClearsTheTopSafeArea() async {
        for d in [TestDevice.iPhone16Pro] {
            let box = FrameBox()
            let model = makeModel()
            let origin = FrameBox()
            let view = CameraView(model: model, filmName: "Kodak Portra 400", onClose: {}, onLayout: { box.frames = $0 }) { _ in
                Color.clear
            }
            // The camera view's own frame in window coordinates; the part frames are relative to it.
            .background(GeometryReader { geo in
                Color.clear.preference(key: TestOriginKey.self, value: ["self": geo.frame(in: .global)])
            })
            .onPreferenceChange(TestOriginKey.self) { frames in
                MainActor.assumeIsolated { if let r = frames["self"] { origin.frames = ["self": r] } }
            }
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: d.size))
            window.frame = CGRect(origin: .zero, size: d.size)
            let host = UIHostingController(rootView: view)
            host.additionalSafeAreaInsets = UIEdgeInsets(top: d.topInset, left: 0, bottom: d.bottomInset, right: 0)
            host.view.frame = window.bounds
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(1200))
            host.view.layoutIfNeeded()
            let f = box.frames
            window.isHidden = true
            await model.stop()
            XCTAssertGreaterThan(host.view.safeAreaInsets.top, d.topInset - 0.5, "the host carries the inset")
            let top = host.view.safeAreaInsets.top
            guard let base = origin.frames["self"] else { return XCTFail("no camera view frame") }
            for id in ["header", "meter", "finder"] {
                guard let r = f[id] else { return XCTFail("missing \(id): \(f.keys.sorted())") }
                XCTAssertGreaterThanOrEqual(base.minY + r.minY, top - 0.5, "\(id) starts below the top safe area (\(top)) on \(d.name)")
            }
        }
    }
}
