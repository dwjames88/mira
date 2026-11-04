import Foundation

/// Scalar mirrors of the film-science kernels, used by tests (and as the readable definition of the maths).
enum FilmMath {
    /// Exposure with latitude on one linear channel value (kernel `miraFilmExposure`). A gain above 1
    /// rolls highlights off toward white by `latitude` (0 plain gain, 1 full negative-film shoulder);
    /// a gain of 1 or less, and any negative value, is a plain gain.
    static func exposure(_ x: Double, gain g: Double, latitude: Double) -> Double {
        guard g > 1, x >= 0 else { return g * x }
        let shoulder = x * (g + x) / (1 + g * x)
        return (1 - latitude) * (g * x) + latitude * shoulder
    }
}
