import Foundation

/// Scalar mirrors of the film-science kernels, used by tests (and as the readable definition of the maths).
enum FilmMath {
    /// Knee of the scene-referred shoulder (below it the curve is the identity).
    static let shoulderKnee = 0.6

    /// Exposure with latitude on one linear channel value (kernel `miraFilmExposure`), gain `g`.
    ///
    /// SDR source (`headroom` 1): a gain above 1 rolls highlights off toward white by `latitude`
    /// (0 plain gain, 1 full negative-film shoulder) with x (g + x) / (1 + g x); a gain of 1 or
    /// less, and any negative value, is a plain gain.
    ///
    /// Scene-referred source (`headroom` H > 1, values up to H): when the white point W = g H
    /// exceeds 1, with u = g x and knee k = 0.6, u <= k is the identity and
    /// y = k + (1 - k) f(t), t = (u - k) / (W - k), f(t) = t (1 + a) / (1 + a t), a = (W - 1) / (1 - k)
    /// for u > k. f(1) = 1 (W maps to white), f is monotone and concave, and the slope is 1 at the
    /// knee (C1). The result is blended with the plain gain u by `latitude`.
    static func exposure(_ x: Double, gain g: Double, latitude: Double, headroom: Double = 1) -> Double {
        let w = g * headroom
        if headroom > 1, w > 1 {
            guard x >= 0 else { return g * x }
            let k = shoulderKnee
            let u = g * x
            guard u > k else { return u }
            let a = (w - 1) / (1 - k)
            let t = (u - k) / (w - k)
            let shoulder = k + (1 - k) * (t * (1 + a) / (1 + a * t))
            return (1 - latitude) * u + latitude * shoulder
        }
        guard g > 1, x >= 0 else { return g * x }
        let shoulder = x * (g + x) / (1 + g * x)
        return (1 - latitude) * (g * x) + latitude * shoulder
    }

    /// Reciprocity on one linear channel value (kernel `miraReciprocity`): a gain `gain`, then, when
    /// `contrast` != 1, a power around 18 % grey: 0.18 (x / 0.18)^contrast for x >= 0.
    static func reciprocity(_ x: Double, gain: Double, contrast: Double) -> Double {
        let y = x * gain
        guard contrast != 1, y >= 0 else { return y }
        return 0.18 * pow(y / 0.18, contrast)
    }

    /// Weight of the shadow grain gain at sRGB-encoded luminance `l` for tonal centre `center`
    /// (kernel `miraGrain`): 1 at and above the centre, 0 at black, smooth in between.
    static func shadowWeight(luma l: Double, center: Double) -> Double {
        let t = min(max(l / max(center, 1e-6), 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }
}
