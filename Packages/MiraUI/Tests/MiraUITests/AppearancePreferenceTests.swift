import AppKit
import Testing
@testable import MiraUI

@Suite("Appearance preference")
struct AppearancePreferenceTests {
    @Test func keyAndRawValues() {
        #expect(AppearancePreference.key == "mira.appearance")
        #expect(AppearancePreference.allCases.map(\.rawValue) == ["system", "light", "dark"])
    }

    @Test func unknownOrMissingIsSystem() {
        #expect(AppearancePreference(storedValue: nil) == .system)
        #expect(AppearancePreference(storedValue: "sepia") == .system)
        #expect(AppearancePreference(storedValue: "dark") == .dark)
    }

    @Test func nsAppearanceMapping() {
        #expect(AppearancePreference.system.nsAppearance == nil)
        #expect(AppearancePreference.light.nsAppearance?.name == .aqua)
        #expect(AppearancePreference.dark.nsAppearance?.name == .darkAqua)
    }

    @Test func toggleFlipsEffectiveAppearance() {
        #expect(AppearancePreference.next(toggleFrom: true) == .light)
        #expect(AppearancePreference.next(toggleFrom: false) == .dark)
    }

    @Test func storedReadsOnlyValidValues() throws {
        let defaults = try #require(UserDefaults(suiteName: "mira.appearance.tests"))
        defaults.removePersistentDomain(forName: "mira.appearance.tests")
        #expect(AppearancePreference.stored(in: defaults) == nil)
        defaults.set("light", forKey: AppearancePreference.key)
        #expect(AppearancePreference.stored(in: defaults) == .light)
        defaults.set("junk", forKey: AppearancePreference.key)
        #expect(AppearancePreference.stored(in: defaults) == nil)
        defaults.removePersistentDomain(forName: "mira.appearance.tests")
    }

    @Test func darkAquaDetection() {
        #expect(NSAppearance(named: .darkAqua)?.isDarkAqua == true)
        #expect(NSAppearance(named: .aqua)?.isDarkAqua == false)
    }
}
