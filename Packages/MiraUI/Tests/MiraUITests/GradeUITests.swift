import AppKit
import CoreImage
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

@Suite("Curve editing") struct CurveEditingTests {
    private func p(_ x: Double, _ y: Double) -> CurvePoint { CurvePoint(x: x, y: y) }

    @Test func addPointLandsOnTheCurve() {
        var pts = [p(0, 0), p(1, 1)]
        let i = CurveEditing.addPoint(&pts, atX: 0.5)
        #expect(i == 1 && pts.count == 3)
        #expect(abs(pts[1].y - 0.5) < 1e-9)
        // Adding again at the same place reuses the point.
        #expect(CurveEditing.addPoint(&pts, atX: 0.5) == 1 && pts.count == 3)
    }

    @Test func pointsKeepOrderWhenInserted() {
        var pts = [p(0, 0), p(0.8, 0.9), p(1, 1)]
        let i = CurveEditing.addPoint(&pts, atX: 0.3)
        #expect(i == 1)
        #expect(pts.map(\.x) == pts.map(\.x).sorted())
    }

    @Test func interiorPointStaysBetweenNeighbours() {
        var pts = [p(0, 0), p(0.4, 0.4), p(0.7, 0.7), p(1, 1)]
        CurveEditing.move(&pts, index: 1, to: CGPoint(x: 0.9, y: 0.2))
        #expect(pts[1].x < pts[2].x && pts[1].x > pts[0].x)
        #expect(pts[1].y == 0.2)
        CurveEditing.move(&pts, index: 1, to: CGPoint(x: -0.5, y: 2))
        #expect(pts[1].x > 0 && pts[1].y == 1)
    }

    @Test func endpointsMoveOnlyVertically() {
        var pts = [p(0, 0), p(0.5, 0.5), p(1, 1)]
        CurveEditing.move(&pts, index: 0, to: CGPoint(x: 0.3, y: 0.2))
        CurveEditing.move(&pts, index: 2, to: CGPoint(x: 0.6, y: 0.9))
        #expect(pts[0] == p(0, 0.2) && pts[2] == p(1, 0.9))
    }

    @Test func endpointsCannotBeDeleted() {
        var pts = [p(0, 0), p(0.5, 0.6), p(1, 1)]
        #expect(!CurveEditing.delete(&pts, index: 0))
        #expect(!CurveEditing.delete(&pts, index: 2))
        #expect(CurveEditing.delete(&pts, index: 1))
        #expect(pts == CurvesSettings.identityPoints)
    }

    @Test func nudgeAndHit() {
        var pts = [p(0, 0), p(0.5, 0.5), p(1, 1)]
        CurveEditing.nudge(&pts, index: 1, dx: 0.1, dy: -0.1)
        #expect(abs(pts[1].x - 0.6) < 1e-9 && abs(pts[1].y - 0.4) < 1e-9)
        let size = CGSize(width: 200, height: 200)
        #expect(CurveEditing.hit(pts, at: CGPoint(x: 121, y: 121), size: size, radius: 9) == 1)
        #expect(CurveEditing.hit(pts, at: CGPoint(x: 60, y: 60), size: size, radius: 9) == nil)
        #expect(CurveEditing.isOutside(CGPoint(x: -20, y: 50), size: size))
        #expect(!CurveEditing.isOutside(CGPoint(x: 100, y: 50), size: size))
        #expect(CurveEditing.readout(p(0.5, 141.0 / 255)) == "IN 128 \u{00B7} OUT 141")
    }

    @Test func clickMapsThroughAspectFit() {
        // 300x100 picture in a 400x400 pane with 20 pt inset: shown 360x120, centred.
        let pane = CGSize(width: 400, height: 400), image = CGSize(width: 300, height: 100)
        let mid = PreviewHitMapping.normalizedPoint(CGPoint(x: 200, y: 200), pane: pane, inset: 20, image: image)
        #expect(mid == CGPoint(x: 0.5, y: 0.5))
        #expect(PreviewHitMapping.normalizedPoint(CGPoint(x: 200, y: 100), pane: pane, inset: 20, image: image) == nil)
        let corner = PreviewHitMapping.normalizedPoint(CGPoint(x: 20, y: 140), pane: pane, inset: 20, image: image)
        #expect(corner == CGPoint(x: 0, y: 0))
    }

    @Test func collapseStateRoundTrips() {
        let ids = InspectorCollapse.ids("curves,colorMixer")
        #expect(ids == ["curves", "colorMixer"])
        #expect(InspectorCollapse.ids(InspectorCollapse.raw(ids)) == ids)
        #expect(InspectorCollapse.ids("").isEmpty)
    }
}

@MainActor
@Suite("Grade model", .serialized) struct GradeModelTests {
    static func model(color: (CGFloat, CGFloat, CGFloat)) async throws -> EditorModel {
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        let model = EditorModel(library: library)
        let c = CIColor(red: color.0, green: color.1, blue: color.2, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        model.setSource(CIImage(color: c).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300)))
        let deadline = Date().addingTimeInterval(30)
        while model.displayedFrame == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.displayedFrame != nil)
        return model
    }

    @Test func eyedropperSelectsNearestRangeAndTurnsOff() async throws {
        let model = try await Self.model(color: (1, 0.55, 0))
        model.eyedropperActive = true
        #expect(model.sampleRange(atImagePoint: CGPoint(x: 0.5, y: 0.5)) == .orange)
        #expect(model.mixerRange == .orange)
        #expect(!model.eyedropperActive)
        model.cancelWork()
    }

    @Test func eyedropperIgnoresGreys() async throws {
        let model = try await Self.model(color: (0.5, 0.5, 0.5))
        model.mixerRange = .blue
        model.eyedropperActive = true
        #expect(model.sampleRange(atImagePoint: CGPoint(x: 0.2, y: 0.2)) == nil)
        #expect(model.mixerRange == .blue && !model.eyedropperActive)
        model.cancelWork()
    }

    @Test func histogramFollowsTheDisplayedFrame() async throws {
        let model = try await Self.model(color: (0, 0, 0))
        model.histogramFrameChanged(model.displayedFrame)
        let deadline = Date().addingTimeInterval(10)
        while model.histogram == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let h = try #require(model.histogram)
        #expect(h.luminance[0] > 0.99 && h.isClippingLow)
        model.cancelWork()
    }
}
