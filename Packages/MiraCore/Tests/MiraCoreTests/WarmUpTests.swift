import Foundation
import Testing
@testable import MiraCore

@Suite struct WarmUpTests {
    @Test func warmUpRendersWithoutAFilmAndWithOne() throws {
        PreviewEngine.warmUp(library: try emptyLibrary())
    }

    @Test func prewarmConcurrencyIsBounded() {
        let n = FilmLibrary.defaultPrewarmConcurrency
        #expect(n >= 4 && n <= 8)
    }
}
