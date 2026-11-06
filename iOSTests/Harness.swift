import SwiftUI
import UIKit
import XCTest
@testable import Mira

/// A phone screen the layout is rendered at, in points. Insets stand in for the status bar / Dynamic
/// Island and home indicator, which an offscreen host does not have.
struct TestDevice: Sendable {
    let name: String
    let size: CGSize
    let scale: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    static let iPhone16Pro = TestDevice(name: "iPhone16Pro", size: CGSize(width: 402, height: 874), scale: 3,
                                        topInset: 62, bottomInset: 34)
    static let iPhoneSE = TestDevice(name: "iPhoneSE", size: CGSize(width: 375, height: 667), scale: 2,
                                     topInset: 20, bottomInset: 0)
    static let iPhone16ProLandscape = TestDevice(name: "iPhone16ProLandscape", size: CGSize(width: 874, height: 402), scale: 3,
                                                 topInset: 0, bottomInset: 21)
    static let all = [iPhone16Pro, iPhoneSE]
}

enum Snapshot {
    /// Repository root, from this file's compile-time path (iOSTests/Harness.swift).
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// build/snapshots/ios-tests/<set>/ ; set comes from MIRA_SNAPSHOT_SET (before | after), default "after".
    static var outputDir: URL {
        let set = ProcessInfo.processInfo.environment["MIRA_SNAPSHOT_SET"] ?? "after"
        let dir = root.appendingPathComponent("build/snapshots/ios-tests/\(set)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Hosts `content` in a window at the device's point size, lets SwiftUI settle, writes a PNG and returns the image.
    @MainActor
    @discardableResult
    static func render<V: View>(_ content: V, device: TestDevice, name: String, settle: Duration = .milliseconds(900)) async -> UIImage {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: device.size))
        window.frame = CGRect(origin: .zero, size: device.size)
        // The content gets the full device frame; insets are applied by shrinking it.
        let host = UIHostingController(rootView: AnyView(
            ZStack {
                Color(red: 0.082, green: 0.078, blue: 0.059)
                content.padding(.top, device.topInset).padding(.bottom, device.bottomInset)
            }
            .frame(width: device.size.width, height: device.size.height)
            .preferredColorScheme(.dark)))
        host.safeAreaRegions = []
        host.view.frame = CGRect(origin: .zero, size: device.size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: settle)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = device.scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: device.size, format: format).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: device.size), afterScreenUpdates: true)
        }
        window.isHidden = true
        if let png = image.pngData() {
            try? png.write(to: outputDir.appendingPathComponent("\(name)-\(device.name).png"))
        }
        return image
    }
}

extension EditorViewModel {
    /// Round 3: waits until the histogram of the open photo has been computed and has stopped changing, so a Develop panel
    /// snapshot does not catch the empty or the previous histogram (it is recomputed off the main actor after every
    /// recipe change, 100 ms after the change at the earliest). Test code only.
    @MainActor
    func settleHistogram(quiet: Duration = .milliseconds(400), timeout: Duration = .seconds(30)) async {
        let start = ContinuousClock.now
        var last = histogram
        var stableSince = ContinuousClock.now
        while start.duration(to: .now) < timeout {
            try? await Task.sleep(for: .milliseconds(50))
            if histogram != last { last = histogram; stableSince = .now }
            if last != .empty, stableSince.duration(to: .now) >= quiet { return }
        }
    }
}
