import Foundation
import Testing
@testable import MiraCore

@Suite struct HistogramTests {
    private func histogram(_ pixel: [UInt8], width: Int = 64, height: Int = 48) -> HistogramData {
        var bytes = [UInt8]()
        for _ in 0..<(width * height) { bytes += pixel }
        return bytes.withUnsafeBytes {
            HistogramData.compute(bgra: $0.baseAddress!, width: width, height: height, rowBytes: width * 4)
        }
    }

    @Test func allBlackFillsBinZeroAndClips() {
        let h = histogram([0, 0, 0, 255])
        #expect(h.luminance[0] == 1 && h.red[0] == 1 && h.green[0] == 1 && h.blue[0] == 1)
        #expect(h.isClippingLow && !h.isClippingHigh)
    }

    @Test func allWhiteFillsBin255() {
        let h = histogram([255, 255, 255, 255])
        #expect(h.luminance[255] == 1)
        #expect(h.isClippingHigh && !h.isClippingLow)
    }

    @Test func midGreyIsNotClipped() {
        let h = histogram([128, 128, 128, 255])
        #expect(h.luminance[128] == 1)
        #expect(!h.isClippingLow && !h.isClippingHigh)
        #expect(abs(h.red.reduce(0, +) - 1) < 1e-4)
    }

    @Test func channelsBinSeparately() {
        // BGRA: B=10, G=100, R=200
        let h = histogram([10, 100, 200, 255])
        #expect(h.red[200] == 1 && h.green[100] == 1 && h.blue[10] == 1)
    }

    @Test func clippingNeedsHalfAPercent() {
        var bytes = [UInt8](repeating: 128, count: 100 * 100 * 4)
        for i in 0..<30 { for c in 0..<3 { bytes[i * 4 + c] = 255 } } // 0.3 %
        let h = bytes.withUnsafeBytes { HistogramData.compute(bgra: $0.baseAddress!, width: 100, height: 100, rowBytes: 400, maxSamples: 10_000) }
        #expect(!h.isClippingHigh)
        for i in 0..<80 { for c in 0..<3 { bytes[i * 4 + c] = 255 } } // 0.8 %
        let h2 = bytes.withUnsafeBytes { HistogramData.compute(bgra: $0.baseAddress!, width: 100, height: 100, rowBytes: 400, maxSamples: 10_000) }
        #expect(h2.isClippingHigh)
    }
}
