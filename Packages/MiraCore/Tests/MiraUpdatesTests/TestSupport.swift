import Foundation
import Testing
@testable import MiraUpdates

/// Every suite that uses `StubProtocol` nests here: the stub is process-wide, so they must not run in parallel.
@Suite("Stubbed network", .serialized)
struct StubbedNetwork {}

/// A `URLProtocol` that answers from a closure, so no test touches the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case data(Data, status: Int)
        case failure(URLError)
    }
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Reply)?
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    private static let lock = NSLock()

    static func install(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        lock.lock(); self.handler = handler; seen = []; lock.unlock()
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }
    static var session: URLSession { URLSession(configuration: configuration) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        switch handler?(request) ?? .failure(URLError(.notConnectedToInternet)) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .data(let data, let status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "\(data.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try fixtureURL(name)
        return try Data(contentsOf: url)
    }
    private static func fixtureURL(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mira-updates-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func scratchDefaults() -> UserDefaults {
    let suite = "mira.updates.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

/// A minimal app bundle: Info.plist, a copy of `/usr/bin/true` as the executable, and a resource file.
@discardableResult
func makeApp(at directory: URL, name: String = "Mira.app", identifier: String = "com.fieldframes.mira",
             version: String = "0.2.0", marker: String = "original") throws -> URL {
    let fm = FileManager.default
    let app = directory.appendingPathComponent(name, isDirectory: true)
    let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
    try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleVersion": "1",
        "CFBundleExecutable": "Mira", "CFBundlePackageType": "APPL", "CFBundleName": "Mira",
    ]
    try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
    try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Mira"))
    try marker.write(to: resources.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
    return app
}

@discardableResult
func shell(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
