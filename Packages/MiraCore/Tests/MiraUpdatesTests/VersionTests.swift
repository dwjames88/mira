import Testing
@testable import MiraUpdates

@Suite("SemanticVersion")
struct VersionTests {
    @Test func parsesTagsAndLenientForms() {
        #expect(SemanticVersion("v0.2.0") == SemanticVersion(major: 0, minor: 2, patch: 0))
        #expect(SemanticVersion("V1.2") == SemanticVersion(major: 1, minor: 2, patch: 0))
        #expect(SemanticVersion("3") == SemanticVersion(major: 3, minor: 0, patch: 0))
        #expect(SemanticVersion("1.2.3+build5") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion(" 0.2.0\n")?.description == "0.2.0")
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("latest") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
        #expect(SemanticVersion("1.x") == nil)
    }

    @Test func ordersNumerically() throws {
        let v020 = try #require(SemanticVersion("0.2.0"))
        let v021 = try #require(SemanticVersion("v0.2.1"))
        let v0100 = try #require(SemanticVersion("0.10.0"))
        let v100 = try #require(SemanticVersion("1.0.0"))
        #expect(v020 < v021)
        #expect(v021 < v0100)   // not string order
        #expect(v0100 < v100)
        #expect(!(v020 < v020))
        #expect(SemanticVersion("v0.2.0") == SemanticVersion("0.2.0"))
    }

    @Test func prereleaseSortsBelowItsRelease() throws {
        let beta1 = try #require(SemanticVersion("0.3.0-beta.1"))
        let beta2 = try #require(SemanticVersion("0.3.0-beta.2"))
        let beta10 = try #require(SemanticVersion("0.3.0-beta.10"))
        let release = try #require(SemanticVersion("0.3.0"))
        let previous = try #require(SemanticVersion("0.2.9"))
        #expect(previous < beta1)
        #expect(beta1 < beta2)
        #expect(beta2 < beta10)
        #expect(beta10 < release)
    }
}
