import CoreGraphics
import Foundation
import Testing
@testable import MiraCore

private func floats(_ lut: LUT) -> [Float] {
    lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

private func identityCubeText(size: Int, header: String = "") -> String {
    var s = header + "LUT_3D_SIZE \(size)\n"
    for b in 0..<size { for g in 0..<size { for r in 0..<size {
        let d = Double(size - 1)
        s += "\(Double(r) / d) \(Double(g) / d) \(Double(b) / d)\n"
    } } }
    return s
}

private func expectIdentity(_ lut: LUT, tolerance: Float) {
    let n = lut.dimension
    let f = floats(lut)
    #expect(f.count == n * n * n * 4)
    var worst: Float = 0
    for b in 0..<n { for g in 0..<n { for r in 0..<n {
        let i = ((b * n + g) * n + r) * 4
        let exp = [Float(r), Float(g), Float(b)].map { $0 / Float(n - 1) }
        for c in 0..<3 { worst = max(worst, abs(f[i + c] - exp[c])) }
        #expect(f[i + 3] == 1)
    } } }
    #expect(worst <= tolerance, "worst deviation \(worst)")
}

/// Identity Hald of the given level, 8-bit RGBA, r fastest.
private func identityHald(level: Int) -> CGImage {
    let n = level * level, side = level * level * level
    var bytes = [UInt8](repeating: 255, count: side * side * 4)
    for i in 0..<(n * n * n) {
        let r = i % n, g = (i / n) % n, b = i / (n * n)
        let d = Double(n - 1)
        bytes[i * 4 + 0] = UInt8((Double(r) / d * 255).rounded())
        bytes[i * 4 + 1] = UInt8((Double(g) / d * 255).rounded())
        bytes[i * 4 + 2] = UInt8((Double(b) / d * 255).rounded())
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

@Suite struct LUTTests {
    @Test func parseIdentityCube() throws {
        for size in [2, 3] {
            let lut = try LUT.parseCube(identityCubeText(size: size, header: "# comment\nTITLE \"x\"\n\n"))
            #expect(lut.dimension == size)
            expectIdentity(lut, tolerance: 1e-6)
        }
    }

    @Test func cubeDomainIsNormalised() throws {
        let text = """
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 2 2 2
        LUT_3D_SIZE 2
        0 0 0
        2 0 0
        0 2 0
        2 2 0
        0 0 2
        2 0 2
        0 2 2
        2 2 2
        """
        expectIdentity(try LUT.parseCube(text), tolerance: 1e-6)
    }

    @Test func cubeRejectsBadInput() {
        #expect(throws: LUTError.self) { try LUT.parseCube("hello world\nnot a lut") }
        #expect(throws: LUTError.self) { try LUT.parseCube("LUT_3D_SIZE 2\n0 0 0\n") }
        #expect(throws: LUTError.oneDimensionalNotSupported) {
            try LUT.parseCube("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        }
    }

    @Test func haldIdentity() throws {
        for level in [2, 4] {
            let lut = try LUT.loadHald(cgImage: identityHald(level: level))
            #expect(lut.dimension == level * level)
            expectIdentity(lut, tolerance: 1.0 / 255)
        }
    }

    @Test func haldRejectsBadSize() {
        #expect(throws: LUTError.self) { try LUT.loadHald(cgImage: identityHald(level: 2).cropping(to: CGRect(x: 0, y: 0, width: 7, height: 7))!) }
    }

    @Test func resampledIdentityStaysIdentity() throws {
        let lut = try LUT.parseCube(identityCubeText(size: 17))
        for m in [5, 9, 33, 64] {
            let r = lut.resampled(to: m)
            #expect(r.dimension == m)
            expectIdentity(r, tolerance: 1e-5)
        }
    }

    @Test func largeHaldIsCappedAt64() throws {
        let lut = try LUT.loadHald(cgImage: identityHald(level: 9)) // 81^3 -> 64^3
        #expect(lut.dimension == 64)
        expectIdentity(lut, tolerance: 1.5 / 255)
    }
}
