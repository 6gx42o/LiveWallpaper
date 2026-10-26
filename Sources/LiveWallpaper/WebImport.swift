import Foundation
import UniformTypeIdentifiers

/// Fetches videos/GIFs from the web (browser drags, links) and from YouTube via yt-dlp, into a temporary folder.
enum WebImport {
    static let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appending(path: "LiveWallpaper-imports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Largest file accepted from a link.
    static let maxBytes: Int64 = 2_000_000_000

    static func failure(_ text: String) -> Error { CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: text]) }

    static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "youtu.be" || host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com")
    }

    // MARK: Plain downloads (dragged links, images from a browser)

    /// Downloads `url` (http/https only) into a unique temp folder, naming the file from the server's answer.
    static func download(_ url: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { throw failure("Only web (http/https) links can be downloaded.") }
        // A delegate-driven task: the async convenience API doesn't report progress.
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (file, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(URL, URLResponse), Error>) in
                delegate.continuation = cont
                let task = session.downloadTask(with: url)
                delegate.task = task
                task.resume()
            }
        } onCancel: { delegate.task?.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw failure("The website answered with an error (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxBytes else { throw failure("The file is larger than \(TransferProgress.size(maxBytes)).") }

        // Name it from the server, with an extension that matches what it actually is.
        var name = response.suggestedFilename ?? url.lastPathComponent
        if name.isEmpty { name = "Download" }
        if let mime = response.mimeType, let type = UTType(mimeType: mime), let ext = type.preferredFilenameExtension,
           URL(fileURLWithPath: name).pathExtension.lowercased() != ext {
            name = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + "." + ext
        }
        let folder = tempDir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: name)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Int64, Int64?) -> Void
        var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        var task: URLSessionDownloadTask?
        init(progress: @escaping @Sendable (Int64, Int64?) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
            if totalBytesWritten > WebImport.maxBytes { downloadTask.cancel() }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The temp file is deleted when this returns, so keep it.
            let kept = WebImport.tempDir.appending(path: UUID().uuidString + ".download")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                if let response = downloadTask.response { continuation?.resume(returning: (kept, response)) }
                else { continuation?.resume(throwing: WebImport.failure("No response from the website.")) }
            } catch { continuation?.resume(throwing: error) }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    // MARK: YouTube (yt-dlp)

    static var ytDlpPath: String? {
        ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"].first(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// Downloads the best video stream up to `maxHeight` (no audio — wallpapers are silent).
    /// `progress` gets (title, bytes received, total). Returns the downloaded file.
    static func downloadYouTube(_ url: URL, maxHeight: Int, process: Process,
                                progress: @escaping @Sendable (String?, Int64, Int64?) -> Void) async throws -> URL {
        guard let ytDlp = ytDlpPath else {
            throw failure("YouTube links need yt-dlp. Install it with: brew install yt-dlp")
        }
        let folder = tempDir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: ytDlp)
        // Passed as an argument array (no shell), so the link can't inject commands.
        process.arguments = [
            "--no-playlist", "--no-warnings", "--newline", "--progress", "--restrict-filenames",
            "-f", "bv*[height<=\(maxHeight)][ext=mp4]/bv*[height<=\(maxHeight)]/b[height<=\(maxHeight)]/b",
            "--print", "before_dl:LWTITLE %(title)s",
            "--print", "after_move:LWFILE %(filepath)s",
            "--progress-template", "download:LWPROGRESS %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
            "-o", folder.path + "/%(title).80B.%(ext)s",
            "--", url.absoluteString,
        ]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        final class State: @unchecked Sendable { var title: String?; var file: String?; var buffer = "" }
        let state = State()
        output.fileHandleForReading.readabilityHandler = { handle in
            state.buffer += String(decoding: handle.availableData, as: UTF8.self)
            while let newline = state.buffer.firstIndex(of: "\n") {
                let line = String(state.buffer[..<newline])
                state.buffer.removeSubrange(...newline)
                if line.hasPrefix("LWTITLE ") { state.title = String(line.dropFirst(8)) }
                if line.hasPrefix("LWFILE ") { state.file = String(line.dropFirst(7)) }
                if line.hasPrefix("LWPROGRESS ") {
                    let parts = line.split(separator: " ").dropFirst().map { Int64(Double($0) ?? 0) }
                    let total = parts.count > 2 ? (parts[1] > 0 ? parts[1] : (parts[2] > 0 ? parts[2] : nil)) : nil
                    progress(state.title, parts.first ?? 0, total)
                }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                output.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0 { return cont.resume() }
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let last = message.split(whereSeparator: \.isNewline).last.map(String.init) ?? "yt-dlp stopped (exit \(p.terminationStatus))"
                cont.resume(throwing: failure(p.terminationReason == .uncaughtSignal ? "Cancelled." : last))
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
        if let file = state.file, FileManager.default.fileExists(atPath: file) { return URL(fileURLWithPath: file) }
        // Fall back to whatever landed in the folder.
        guard let any = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first else {
            throw failure("yt-dlp finished but no video was saved.")
        }
        return any
    }
}
