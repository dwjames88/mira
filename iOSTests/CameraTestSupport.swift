import Foundation
import MiraCamera
import MiraCameraKit
import MiraCore

actor CallRecorder {
    private(set) var attached: [(recipe: Recipe, id: String, rawBase: Bool)] = []
    private(set) var created: [String] = []
    func attach(_ r: Recipe, _ id: String, _ raw: Bool) { attached.append((r, id, raw)) }
    func create(_ s: String) { created.append(s) }
}

struct StubPrintWriter: PrintWriting {
    let log: CallRecorder
    func attach(recipe: Recipe, toAsset id: String, rawBase: Bool) async throws { await log.attach(recipe, id, rawBase) }
}

struct StubLibrary: PhotoLibraryWriting {
    let level: LibraryAccess
    let log: CallRecorder
    func access() async -> LibraryAccess { level }
    func createAsset(photo: URL, alternateRaw: URL?) async throws -> String {
        await log.create("asset")
        return "stub-asset"
    }
    func createBakedCopy(jpeg: URL) async throws -> String {
        await log.create("baked")
        return "stub-baked"
    }
}

struct StubBaker: PrintBaking {
    func bake(recipe: Recipe, photo: URL, raw: URL?) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stub-\(UUID().uuidString).jpg")
        try Data("jpeg".utf8).write(to: url)
        return url
    }
}

enum CameraFixtures {
    static var sampleURL: URL { Snapshot.root.appendingPathComponent("Fixtures/sample.jpg") }
}
