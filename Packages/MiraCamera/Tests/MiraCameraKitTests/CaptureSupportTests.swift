import Foundation
import ImageIO
import Testing
@testable import MiraCameraKit

@Suite struct CaptureSupportTests {
    @Test func gainsClampToDeviceRange() {
        let g = WhiteBalanceGains(red: 0.4, green: 1.2, blue: 9).clamped(maxGain: 4)
        #expect(g == WhiteBalanceGains(red: 1, green: 1.2, blue: 4))
        #expect(WhiteBalanceGains(red: .nan, green: 2, blue: 2).clamped(maxGain: 0).red == 1)
    }

    @Test func gpsDictionaryHemispheres() {
        let d = LocationMetadata.gpsDictionary(
            latitude: -33.5, longitude: -70.25, altitude: -3, timestamp: Date(timeIntervalSince1970: 86_400 + 3_661))
        #expect(d[kCGImagePropertyGPSLatitude as String] as? Double == 33.5)
        #expect(d[kCGImagePropertyGPSLatitudeRef as String] as? String == "S")
        #expect(d[kCGImagePropertyGPSLongitudeRef as String] as? String == "W")
        #expect(d[kCGImagePropertyGPSAltitudeRef as String] as? Int == 1)
        #expect(d[kCGImagePropertyGPSDateStamp as String] as? String == "1970:01:02")
        #expect(d[kCGImagePropertyGPSTimeStamp as String] as? String == "01:01:01")
    }

    @Test func descriptorKeepsConsistentConstituents() {
        let d = LensDescriptor.make(
            fieldOfView: 106.1797, constituentFieldsOfView: [106.1797, 71.5958, 16.4147], switchOverZoomFactors: [2, 10],
            displayZoomMultiplier: 0.5, minZoom: 1, maxZoom: 60, constituentCount: 3)
        #expect(d.constituentFieldsOfView.count == 3)
    }

    @Test func descriptorDropsInconsistentConstituents() {
        let d = LensDescriptor.make(
            fieldOfView: 106, constituentFieldsOfView: [106, 90, 16], switchOverZoomFactors: [2, 10],
            displayZoomMultiplier: 0.5, minZoom: 1, maxZoom: 60, constituentCount: 3)
        #expect(d.constituentFieldsOfView.isEmpty)
        let wrongCount = LensDescriptor.make(
            fieldOfView: 70, constituentFieldsOfView: [70], switchOverZoomFactors: [],
            displayZoomMultiplier: 1, minZoom: 1, maxZoom: 10, constituentCount: 2)
        #expect(wrongCount.constituentFieldsOfView.isEmpty)
    }
}
