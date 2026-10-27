import AppKit
import AVFoundation
import UniformTypeIdentifiers
import os

/// Imported videos are converted to muted HEVC .mp4 (hardware-decoded, original resolution up to 4K/display size)
/// and stored in Application Support, where they become selectable wallpapers.
@MainActor
final class Library {
    /// A message for the user: an error (import failed), a warning (quality) or info (finished upscaling).
    /// Has a headline, a plain reason, technical detail to help diagnose it, and optionally a video to upscale.
    struct Notice: Error, Identifiable {
        enum Kind { case error, warning, info }
        let id = UUID()
        var kind = Kind.error
        let title: String
        let reason: String
        var details: String?
        /// Offer an "Upscale" button for this library video.
        var upscale: URL?
    }

    private enum Job {
        case importFile(URL)
        case upscale(URL, allowModelDownload: Bool)
        /// A link dragged in from a browser (image, GIF or video file).
        case download(URL)
        /// A YouTube link, fetched with yt-dlp.
        case youtube(URL)
    }

    static let supportedFormats = "MP4, MOV, M4V, GIF, animated WebP/PNG and still images work out of the box. With ffmpeg installed: WebM, MKV, AVI, FLV, WMV, MPEG, OGV and 3GP."
    /// Formats macOS can't decode itself but ffmpeg can.
    nonisolated static let ffmpegExtensions: Set<String> = ["webm", "mkv", "avi", "flv", "wmv", "mpg", "mpeg", "ts", "m2ts", "ogv", "3gp", "vob"]
    /// Looked up each time, so installing ffmpeg works without restarting the app.
    static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile(atPath:))
    }

    let dir: URL
    private(set) var videos: [URL] = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    private(set) var infos: [URL: VideoInfo] = [:]
    /// Library videos that can't be played, with a user-facing reason.
    private(set) var broken: [URL: String] = [:]
    /// The running job's label and progress.
    private(set) var converting: TransferProgress?
    private(set) var notices: [Notice] = []
    var onChange: (() -> Void)?
    var onConverted: ((URL) -> Void)?
    /// (original, upscaled copy, method used)
    var onUpscaled: ((URL, URL, Upscaler.Method) -> Void)?
    private var inspecting: Set<URL> = []
    private var queue: [Job] = []
    /// The running job, so it can be cancelled.
    private var currentTask: Task<Void, Never>?
    private var currentProcess: Process?
    private var allEdits: [String: Edits] = {
        guard let data = UserDefaults.standard.data(forKey: "edits") else { return [:] }
        return (try? JSONDecoder().decode([String: Edits].self, from: data)) ?? [:]
    }()
    private var busy = false
    private static let tmpSuffix = ".tmp.mp4"
    private let log = Logger(subsystem: "LiveWallpaper", category: "library")

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = support.appending(path: "LiveWallpaper/Videos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Drop leftovers from a conversion interrupted by quitting.
        for url in contents() where url.lastPathComponent.contains(".tmp.") {
            try? FileManager.default.removeItem(at: url)
        }
        reload()
    }

    /// Re-scans the folder; new videos get a thumbnail, or are marked broken if no frame can be decoded.
    func reload() {
        videos = contents()
            .filter { $0.pathExtension == "mp4" && !$0.lastPathComponent.hasSuffix(Self.tmpSuffix) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        thumbnails = thumbnails.filter { videos.contains($0.key) }
        infos = infos.filter { videos.contains($0.key) }
        broken = broken.filter { videos.contains($0.key) }
        for url in videos where thumbnails[url] == nil && broken[url] == nil && !inspecting.contains(url) {
            inspect(url)
        }
        onChange?()
    }

    func markBroken(_ url: URL) {
        broken[url] = "This video is damaged and can't be played. Remove it and add the original again."
        onChange?()
    }

    func post(_ notice: Notice) {
        notices.append(notice)
        onChange?()
    }

    func dismiss(_ notice: Notice) {
        notices.removeAll { $0.id == notice.id }
        onChange?()
    }

    func edits(for url: URL) -> Edits { allEdits[url.lastPathComponent] ?? Edits() }

    func setEdits(_ edits: Edits, for url: URL) {
        allEdits[url.lastPathComponent] = edits == Edits() ? nil : edits
        saveEdits()
        onChange?()
    }

    private func saveEdits() {
        UserDefaults.standard.set(try? JSONEncoder().encode(allEdits), forKey: "edits")
    }

    /// How a library video will look on the current display with its edits.
    func issues(for url: URL) -> [QualityIssue] {
        infos[url]?.issues(on: Display.pixelSize, edits: edits(for: url)) ?? []
    }

    private func inspect(_ url: URL) {
        inspecting.insert(url)
        Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 225)
            do {
                let (image, _) = try await generator.image(at: .zero)
                thumbnails[url] = NSImage(cgImage: image, size: .zero)
                infos[url] = try await VideoInfo.load(url)
            } catch {
                log.error("broken \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                broken[url] = "This video is damaged and can't be played. Remove it and add the original again."
            }
            inspecting.remove(url)
            onChange?()
        }
    }

    func add(_ urls: [URL]) {
        queue += urls.map(Job.importFile)
        next()
    }

    /// Downloads a link (from a browser drag or pasted) and imports it; YouTube links go through yt-dlp.
    func addFromWeb(_ url: URL) {
        queue.append(WebImport.isYouTube(url) ? .youtube(url) : .download(url))
        next()
    }

    /// Stops the running conversion, download or upscale.
    func cancelCurrentJob() {
        currentProcess?.terminate()
        currentTask?.cancel()
    }

    /// Queues an upscaled copy of a library video that covers the display.
    func upscale(_ url: URL, allowModelDownload: Bool) {
        queue.append(.upscale(url, allowModelDownload: allowModelDownload))
        next()
    }

    func remove(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        allEdits[url.lastPathComponent] = nil
        saveEdits()
        reload()
    }

    /// A free "<name>.mp4" (or "<name> 2.mp4"…) in the library.
    private func freeURL(for name: String) -> URL {
        var out = dir.appending(path: name + ".mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = dir.appending(path: "\(name) \(n).mp4")
            n += 1
        }
        return out
    }

    private func contents() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    /// Rejects anything that can't be a video before spending time converting it.
    private func compatibilityProblem(_ src: URL) -> Notice? {
        let file = src.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDirectory) else {
            return Notice(title: "“\(file)” wasn't found", reason: "The file may have been moved or deleted.", details: src.path)
        }
        if isDirectory.boolValue {
            return Notice(title: "“\(file)” is a folder", reason: "Drop the video files themselves, not a folder. " + Self.supportedFormats)
        }
        let ext = src.pathExtension.lowercased()
        let isMovie = UTType(filenameExtension: ext)?.conforms(to: .movie) ?? false
        if Self.ffmpegExtensions.contains(ext) {
            if Self.ffmpegPath == nil {
                return Notice(
                    title: "“\(file)” isn't compatible yet",
                    reason: "macOS can't play .\(ext) files on its own. Install ffmpeg (brew install ffmpeg) and add it again — it will then be converted automatically.",
                    details: Self.supportedFormats
                )
            }
            return nil
        }
        if !isMovie && !AnimatedImage.isImage(src) {
            let what = ext.isEmpty
                ? "This file has no extension and isn't a video."
                : "This is a .\(ext) file" + (UTType(filenameExtension: ext)?.localizedDescription.map { " (\($0))" } ?? "") + ", not a video."
            return Notice(title: "“\(file)” isn't compatible", reason: what + " " + Self.supportedFormats)
        }
        return nil
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        switch queue.removeFirst() {
        case .importFile(let src): runImport(src)
        case .upscale(let url, let allowModelDownload): runUpscale(url, allowModelDownload: allowModelDownload)
        case .download(let url): runDownload(url)
        case .youtube(let url): runYouTube(url)
        }
    }

    private func runDownload(_ url: URL) {
        busy = true
        let title = "Downloading from \(url.host() ?? "the web")"
        setProgress(title, nil)
        currentTask = Task {
            do {
                let file = try await WebImport.download(url) { received, total in
                    Task { @MainActor in self.setProgress(title, total.map { Double(received) / Double($0) }, received, total) }
                }
                queue.insert(.importFile(file), at: 0)
            } catch {
                notices.append(Notice(title: "Couldn't download “\(url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent)”",
                                      reason: Task.isCancelled ? "Cancelled." : "The link couldn't be downloaded, so nothing was added.",
                                      details: "\(url.absoluteString)\n\(error.localizedDescription)"))
            }
            finishJob()
        }
    }

    private func runYouTube(_ url: URL) {
        busy = true
        setProgress("Downloading from YouTube", nil)
        let process = Process()
        currentProcess = process
        let maxHeight = Prefs.shared.youTubeQuality.maxHeight
            ?? Int(max(Display.pixelSize.width, Display.pixelSize.height) >= 3000 ? 2160 : 1440)
        currentTask = Task {
            do {
                let file = try await WebImport.downloadYouTube(url, maxHeight: maxHeight, process: process) { title, received, total in
                    Task { @MainActor in
                        self.setProgress("Downloading “\(title ?? "YouTube video")”", total.map { Double(received) / Double($0) }, received, total)
                    }
                }
                queue.insert(.importFile(file), at: 0)
            } catch {
                notices.append(Notice(title: "Couldn't get the YouTube video",
                                      reason: WebImport.ytDlpPath == nil ? "YouTube links need yt-dlp. Install it with: brew install yt-dlp"
                                                                         : "yt-dlp couldn't download it (private, removed, age-restricted, or not a video link).",
                                      details: "\(url.absoluteString)\n\(error.localizedDescription)"))
            }
            finishJob()
        }
    }

    private func finishJob() {
        currentTask = nil
        currentProcess = nil
        converting = nil
        busy = false
        onChange?()
        next()
    }

    private func runImport(_ src: URL) {
        if let problem = compatibilityProblem(src) {
            log.error("rejected \(src.lastPathComponent, privacy: .public): \(problem.title, privacy: .public)")
            notices.append(problem)
            onChange?()
            return next()
        }
        busy = true
        let name = src.deletingPathExtension().lastPathComponent
        let out = freeURL(for: name)
        let tmp = dir.appending(path: out.deletingPathExtension().lastPathComponent + Self.tmpSuffix)
        setProgress("Converting “\(name)”", nil)

        currentTask = Task {
            // Downloads land in a temp folder; tidy them up once imported.
            defer { if src.path.hasPrefix(WebImport.tempDir.path) { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) } }
            do {
                if AnimatedImage.isImage(src) {
                    try await AnimatedImage.convert(src, to: tmp) { self.setProgress("Converting “\(name)”", $0) }
                } else {
                    try await convert(src, to: tmp, name: name)
                }
                try FileManager.default.moveItem(at: tmp, to: out)
                log.notice("converted \(src.lastPathComponent, privacy: .public) -> \(out.lastPathComponent, privacy: .public)")
                await warnAboutQuality(source: src, converted: out)
                reload()
                onConverted?(out)
            } catch let notice as Notice {
                try? FileManager.default.removeItem(at: tmp)
                log.error("failed \(src.lastPathComponent, privacy: .public): \(notice.reason, privacy: .public) \(notice.details ?? "", privacy: .public)")
                notices.append(notice)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                log.error("failed \(src.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                notices.append(Notice(
                    title: "“\(src.lastPathComponent)” couldn't be added",
                    reason: "The video was converted but couldn't be saved. Check that your disk isn't full.",
                    details: error.localizedDescription
                ))
            }
            finishJob()
        }
    }

    /// After import: tells the user if the source will look bad on their display (resolution, aspect, bitrate, fps).
    private func warnAboutQuality(source: URL, converted: URL) async {
        // The original has the real bitrate; formats only ffmpeg reads fall back to the converted file.
        let info: VideoInfo?
        if let original = try? await VideoInfo.load(source) { info = original } else { info = try? await VideoInfo.load(converted) }
        guard let info else { return }
        let issues = info.issues(on: Display.pixelSize, includeSource: true)
        guard !issues.isEmpty else { return }
        let hasWarning = issues.contains { $0.severity == .warning }
        guard hasWarning || Prefs.shared.showImportTips else { return }
        let lowResolution = issues.contains { $0.isLowResolution && $0.severity == .warning }
        // Settings › Upscale low-resolution imports: only when no download is needed (downloads always ask first).
        if lowResolution, Prefs.shared.autoUpscale, !Upscaler.needsModelDownload(engine: ModelAdvisor.engine(for: info.size), video: info.size) {
            upscale(converted, allowModelDownload: false)
            notices.append(Notice(kind: .info, title: "Upscaling “\(source.lastPathComponent)” automatically",
                                  reason: issues.map { "• " + $0.text }.joined(separator: "\n")))
            return
        }
        notices.append(Notice(
            kind: hasWarning ? .warning : .info,
            title: hasWarning ? "“\(source.lastPathComponent)” may not look great" : "“\(source.lastPathComponent)” added — heads up",
            reason: issues.map { "• " + $0.text }.joined(separator: "\n"),
            details: "Source: \(info.resolutionText), \(Int(info.fps.rounded())) fps, \(String(format: "%.1f", info.bitrate / 1_000_000)) Mbps · Display: \(Int(Display.pixelSize.width))×\(Int(Display.pixelSize.height))",
            upscale: lowResolution ? converted : nil
        ))
    }

    private func runUpscale(_ url: URL, allowModelDownload: Bool) {
        busy = true
        let name = url.deletingPathExtension().lastPathComponent
        setProgress("Upscaling “\(name)”", nil)
        currentTask = Task {
            do {
                let info = try await VideoInfo.load(url)
                let target = Upscaler.targetSize(for: info.size, display: Display.pixelSize)
                guard target.width > info.size.width else {
                    throw Notice(kind: .info, title: "“\(name)” is already sharp enough",
                                 reason: "It already covers your display at \(info.resolutionText), so there's nothing to upscale.")
                }
                let out = freeURL(for: "\(name) (Upscaled)")
                let tmp = dir.appending(path: out.deletingPathExtension().lastPathComponent + Self.tmpSuffix)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let engine = ModelAdvisor.engine(for: info.size)
                let result = try await Upscaler.upscale(url, to: tmp, target: target, engine: engine, allowModelDownload: allowModelDownload) { label, fraction, received, total in
                    self.setProgress(label, fraction, received, total)
                }
                try FileManager.default.moveItem(at: tmp, to: out)
                allEdits[out.lastPathComponent] = allEdits[url.lastPathComponent]
                saveEdits()
                log.notice("upscaled \(url.lastPathComponent, privacy: .public) -> \(out.lastPathComponent, privacy: .public) via \(result.method.name, privacy: .public)")
                notices.append(Notice(
                    kind: .info,
                    title: "Upscaled “\(name)” to \(Int(target.width))×\(Int(target.height))",
                    reason: "Used \(result.method.name). The original is kept; the upscaled copy is now in your library.",
                    details: result.fallbackReason.map { "\(engine.title) wasn't used: \($0)" }
                ))
                reload()
                onUpscaled?(url, out, result.method)
            } catch let notice as Notice {
                notices.append(notice)
            } catch {
                log.error("upscale failed \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                notices.append(Notice(title: "Couldn't upscale “\(name)”", reason: "Upscaling failed, so the original is unchanged.",
                                      details: error.localizedDescription))
            }
            finishJob()
        }
    }

    private func setProgress(_ title: String, _ fraction: Double?, _ received: Int64? = nil, _ total: Int64? = nil) {
        if let current = converting, current.title == title {
            converting = current.updated(fraction: fraction, received: received, total: total)
        } else {
            converting = TransferProgress(title: title, fraction: fraction, receivedBytes: received, totalBytes: total)
        }
        onChange?()
    }

    /// Longest edge we keep (Settings › Import size): by default 4K, or the display if it's bigger.
    /// Anything larger can't be seen and costs battery.
    private var maxEdge: CGFloat {
        switch Prefs.shared.importLimit {
        case .display: max(3840, Display.pixelSize.width, Display.pixelSize.height)
        case .uhd: 3840
        case .hd: 1920
        }
    }

    private func convert(_ src: URL, to dst: URL, name: String) async throws {
        let file = src.lastPathComponent
        do {
            try await exportWithAVFoundation(src, to: dst, name: name)
        } catch let avError {
            log.notice("AVFoundation export failed (\(avError.localizedDescription, privacy: .public)); trying ffmpeg")
            guard let ffmpeg = Self.ffmpegPath else {
                throw Notice(
                    title: "“\(file)” couldn't be converted",
                    reason: "The file looks damaged, or uses a codec macOS can't decode. Installing ffmpeg (brew install ffmpeg) lets LiveWallpaper try harder.",
                    details: "macOS: \(avError.localizedDescription)"
                )
            }
            // ffmpeg only decodes into ProRes (built into every ffmpeg, read natively by macOS);
            // the final HEVC encode stays on the AVFoundation hardware path.
            let intermediate = dst.deletingPathExtension().appendingPathExtension("mov")
            defer { try? FileManager.default.removeItem(at: intermediate) }
            do {
                try await decodeWithFFmpeg(ffmpeg, src, to: intermediate)
            } catch {
                throw Notice(
                    title: "“\(file)” is broken",
                    reason: "Neither macOS nor ffmpeg could read a video from it — the file is damaged or isn't really a video.",
                    details: "macOS: \(avError.localizedDescription)\nffmpeg: \(error.localizedDescription)"
                )
            }
            try? FileManager.default.removeItem(at: dst)
            do {
                try await exportWithAVFoundation(intermediate, to: dst, name: name)
            } catch {
                throw Notice(
                    title: "“\(file)” couldn't be converted",
                    reason: "It was decoded, but re-encoding it for playback failed.",
                    details: error.localizedDescription
                )
            }
        }
    }

    private func exportWithAVFoundation(_ src: URL, to dst: URL, name: String) async throws {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "No video track found."])
        }
        // Video-only composition so the output carries no audio track.
        let comp = AVMutableComposition()
        guard let videoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Couldn't prepare the video track."])
        }
        let (duration, transform) = try await (asset.load(.duration), track.load(.preferredTransform))
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        videoTrack.preferredTransform = transform

        // Keep the original resolution at the highest HEVC quality; only shrink sources larger than we can show.
        let natural = try await track.load(.naturalSize)
        let preset = max(natural.width, natural.height) <= maxEdge ? AVAssetExportPresetHEVCHighestQuality
            : maxEdge <= 1920 ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPresetHEVC3840x2160
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "HEVC export isn't available on this Mac."])
        }
        let watcher = Task { [weak self] in
            for await state in session.states(updateInterval: 0.5) {
                if case .exporting(let p) = state { self?.setProgress("Converting “\(name)”", p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: dst, as: .mp4)
    }

    private func decodeWithFFmpeg(_ ffmpeg: String, _ src: URL, to dst: URL) async throws {
        let edge = Int(maxEdge)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        // Arguments go straight to execve (no shell), so file names can't inject anything.
        process.arguments = [
            "-nostdin", "-v", "error", "-y", "-i", src.path,
            // ProRes 422 HQ keeps quality for the final HEVC encode; only oversized sources are scaled down.
            "-an", "-vf", "scale='if(gt(iw,ih),min(iw,\(edge)),-2)':'if(gt(iw,ih),-2,min(ih,\(edge)))'",
            "-c:v", "prores_ks", "-profile:v", "3", "-f", "mov", dst.path,
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 { return cont.resume() }
                let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                // The last line of ffmpeg's output is usually the actual cause.
                let lastLine = message.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit code \(p.terminationStatus)"
                cont.resume(throwing: CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: lastLine]))
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}
