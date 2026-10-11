import Foundation
import SenderProtocol

/// The free game data this Mac has fetched, in Application Support: the
/// counterpart of tools/fetch_game_data.sh, from the same mirrors and pinned
/// to the same size and SHA-256.
///
/// A download goes to a work directory beside the cache, is unpacked there
/// with the system's bsdtar (which reads the LHA archives inside id's original
/// zips), is checked, and only then moves into place, so the cache never holds
/// a partial or unverified file.
struct GameDataCache: Sendable {
    let directory: URL

    static var standard: GameDataCache? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            .map {
                GameDataCache(directory: $0
                    .appendingPathComponent("ESPDisplaySender", isDirectory: true)
                    .appendingPathComponent("GameData", isDirectory: true))
            }
    }

    func url(for download: GameData.Download) -> URL {
        directory
            .appendingPathComponent(download.kind == .quakePak ? "quake" : "doom",
                                    isDirectory: true)
            .appendingPathComponent(download.filename)
    }

    /// The cached file, checked against its pin, or nil.
    func cached(_ download: GameData.Download) -> GameData.Identified? {
        let url = url(for: download)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == download.byteCount,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              FirmwareBundle.sha256Hex(data) == download.sha256
        else { return nil }
        return try? GameData.identify(data, filename: download.filename, kind: download.kind)
    }

    /// Bytes the cache holds now.
    func usedBytes() -> Int {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Free space on the cache's volume, for files a person would keep.
    func availableBytes() -> Int? {
        var probe = directory
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int($0) }
    }

    enum FetchError: Error, LocalizedError {
        case noSpace(needed: Int, available: Int)
        case allMirrorsFailed([String])

        var errorDescription: String? {
            switch self {
            case .noSpace(let needed, let available):
                return "The download needs about \(GameStore.byteText(needed)) free on this Mac, "
                    + "but only \(GameStore.byteText(available)) is."
            case .allMirrorsFailed(let reasons):
                return "No mirror gave the pinned file. " + reasons.joined(separator: " ")
            }
        }
    }

    /// Fetch `download` into the cache, trying each mirror in turn until one
    /// gives exactly the pinned file. `progress` gets a fraction and a line.
    func fetch(
        _ download: GameData.Download,
        progress: @escaping @Sendable (Double?, String) -> Void
    ) async throws -> GameData.Identified {
        if let cached = cached(download) { return cached }
        let target = url(for: download)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The archive, its unpacked parts and the file: about three times over.
        let needed = download.byteCount * 3
        if let available = availableBytes(), available < needed {
            throw FetchError.noSpace(needed: needed, available: available)
        }
        var reasons: [String] = []
        for mirror in download.mirrors {
            let work = target.deletingLastPathComponent()
                .appendingPathComponent(".fetch-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                progress(0, "Downloading from \(mirror.name)")
                let archive = work.appendingPathComponent("download")
                try await Self.download(mirror.url, to: archive) { fraction in
                    progress(fraction, "Downloading from \(mirror.name)")
                }
                progress(nil, "Unpacking and checking")
                let file = work.appendingPathComponent("file")
                try Self.unpack(mirror.unpack, archive: archive, to: file, work: work)
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                let sha = FirmwareBundle.sha256Hex(data)
                guard data.count == download.byteCount, sha == download.sha256 else {
                    reasons.append("\(mirror.name) gave \(data.count) bytes, sha256 \(sha), "
                        + "not the pinned \(download.byteCount) bytes, sha256 \(download.sha256).")
                    continue
                }
                let identified = try GameData.identify(
                    data, filename: download.filename, kind: download.kind)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: file, to: target)
                progress(1, "Verified \(download.filename)")
                return identified
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reasons.append("\(mirror.name): \(error.localizedDescription)")
            }
        }
        throw FetchError.allMirrorsFailed(reasons)
    }

    // MARK: download and unpack

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<Void, Error>?

        init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            if totalBytesExpectedToWrite > 0 {
                progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            }
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                finish(URLError(.badServerResponse, userInfo: [
                    NSLocalizedDescriptionKey: "the server answered HTTP \(status)"]))
                return
            }
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                finish(nil)
            } catch {
                finish(error)
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
        ) {
            finish(error)
        }

        private func finish(_ error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }

    /// HTTPS only, redirects included: URLSession refuses a plain-HTTP
    /// redirect under App Transport Security, the counterpart of curl's
    /// --proto-redir '=https'.
    private static func download(
        _ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static let bsdtar = "/usr/bin/bsdtar"

    /// Write the wanted file from `archive` to `file`, as fetch_game_data.sh's
    /// extract() does.
    static func unpack(_ kind: GameData.Unpack, archive: URL, to file: URL, work: URL) throws {
        switch kind {
        case .raw:
            try FileManager.default.moveItem(at: archive, to: file)
        case .quake106:
            let resource = work.appendingPathComponent("resource.1")
            try extract(member: "resource.1", from: archive, to: resource)
            try extract(member: "ID1/PAK0.PAK", from: resource, to: file)
        case .sdlTarGz:
            try extract(member: "id1/pak0.pak", from: archive, to: file)
        }
    }

    private static func extract(member: String, from archive: URL, to output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bsdtar)
        process.arguments = ["-xOf", archive.path, member]
        process.standardOutput = handle
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GameDataCache", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "could not unpack \(member): "
                    + String(decoding: message, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }
}
