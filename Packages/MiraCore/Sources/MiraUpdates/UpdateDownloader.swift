import CryptoKit
import Foundation

/// Streams one release asset to disk with progress, then checks it against the size and SHA-256 GitHub published.
public enum UpdateDownloader {
    /// Downloads `asset` to `destination` (replacing any file there). `progress` gets (received, expected)
    /// bytes; expected is the asset's published size when the server does not say.
    public static func download(
        _ asset: ReleaseAsset, to destination: URL,
        configuration: URLSessionConfiguration = .ephemeral,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        guard Release.isTrustedDownloadURL(asset.downloadURL) else { throw UpdateError.noInstallableAsset }
        let job = DownloadJob(destination: destination, expected: asset.size, progress: progress)
        try await withTaskCancellationHandler {
            try await job.run(url: asset.downloadURL, configuration: configuration)
        } onCancel: {
            job.cancel()
        }
        try verify(fileAt: destination, against: asset)
    }

    /// Size first (cheap), then the digest when GitHub published one. Deletes the file on mismatch.
    public static func verify(fileAt url: URL, against asset: ReleaseAsset) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let actual = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if asset.size > 0, actual != asset.size { throw UpdateError.sizeMismatch(expected: asset.size, actual: actual) }
            if let expected = asset.sha256, try sha256Hex(ofFileAt: url) != expected.lowercased() { throw UpdateError.digestMismatch }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One download task with its delegate session. State is guarded by a lock; delegate callbacks arrive on the
/// session's serial queue.
private final class DownloadJob: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expected: Int64
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var failure: UpdateError?
    private var lastReported: Int64 = -1

    init(destination: URL, expected: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.expected = expected
        self.progress = progress
    }

    func run(url: URL, configuration: URLSessionConfiguration) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if cancelled { lock.unlock(); cont.resume(throwing: UpdateError.cancelled); return }
            continuation = cont
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.setValue("Mira-Updater", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<Void, any Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        cont?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        // At most ~100 updates over a download.
        let step = max(total / 100, 64 * 1024)
        lock.lock()
        let report = lastReported < 0 || totalBytesWritten - lastReported >= step || totalBytesWritten == total
        if report { lastReported = totalBytesWritten }
        lock.unlock()
        if report { progress(totalBytesWritten, total) }
    }

    // The temporary file is deleted when this returns, so the move happens here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            lock.lock(); failure = .httpStatus(http.statusCode); lock.unlock()
            return
        }
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: destination)
        } catch {
            lock.lock(); failure = .installFailed("Cannot save the download: \(error.localizedDescription)"); lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let failure = self.failure
        let wasCancelled = cancelled
        lock.unlock()
        if let failure { finish(.failure(failure)); return }
        if let error {
            if wasCancelled || (error as? URLError)?.code == .cancelled { finish(.failure(UpdateError.cancelled)) }
            else { finish(.failure(UpdateError.network(error.localizedDescription))) }
            return
        }
        finish(.success(()))
    }
}
