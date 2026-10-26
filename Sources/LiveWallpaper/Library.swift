import AppKit
import AVFoundation
import UniformTypeIdentifiers
import os

/// Imported videos are converted to muted HEVC .mp4 (hardware-decoded, capped near screen size)
/// and stored in Application Support, where they become selectable wallpapers.
@MainActor
final class Library {
    /// Why an import failed, written for the user: a headline, a plain reason, and the technical
    /// detail (error text, ffmpeg output) to help diagnose it. Shown until dismissed.
    struct ImportFailure: Error, Identifiable {
        let id = UUID()
        let title: String
        let reason: String
        var details: String?
    }

    static let supportedFormats = "MP4, MOV and M4V work out of the box. With ffmpeg installed: WebM, MKV, AVI, FLV, WMV, MPEG, OGV and 3GP."
    /// Formats macOS can't decode itself but ffmpeg can.
    static let ffmpegExtensions: Set<String> = ["webm", "mkv", "avi", "flv", "wmv", "mpg", "mpeg", "ts", "m2ts", "ogv", "3gp", "vob"]
    /// Looked up each time, so installing ffmpeg works without restarting the app.
    static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile(atPath:))
    }

    let dir: URL
    private(set) var videos: [URL] = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    /// Library videos that can't be played, with a user-facing reason.
    private(set) var broken: [URL: String] = [:]
    private(set) var converting: (name: String, fraction: Double?)?
    private(set) var failures: [ImportFailure] = []
    var onChange: (() -> Void)?
    var onConverted: ((URL) -> Void)?
    private var inspecting: Set<URL> = []
    private var queue: [URL] = []
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

    func dismissFailure(_ failure: ImportFailure) {
        failures.removeAll { $0.id == failure.id }
        onChange?()
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
            } catch {
                log.error("broken \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                broken[url] = "This video is damaged and can't be played. Remove it and add the original again."
            }
            inspecting.remove(url)
            onChange?()
        }
    }

    func add(_ urls: [URL]) {
        queue += urls
        next()
    }

    func remove(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
    }

    private func contents() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    /// Rejects anything that can't be a video before spending time converting it.
    private func compatibilityProblem(_ src: URL) -> ImportFailure? {
        let file = src.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDirectory) else {
            return ImportFailure(title: "“\(file)” wasn't found", reason: "The file may have been moved or deleted.", details: src.path)
        }
        if isDirectory.boolValue {
            return ImportFailure(title: "“\(file)” is a folder", reason: "Drop the video files themselves, not a folder. " + Self.supportedFormats)
        }
        let ext = src.pathExtension.lowercased()
        let isMovie = UTType(filenameExtension: ext)?.conforms(to: .movie) ?? false
        if Self.ffmpegExtensions.contains(ext) {
            if Self.ffmpegPath == nil {
                return ImportFailure(
                    title: "“\(file)” isn't compatible yet",
                    reason: "macOS can't play .\(ext) files on its own. Install ffmpeg (brew install ffmpeg) and add it again — it will then be converted automatically.",
                    details: Self.supportedFormats
                )
            }
            return nil
        }
        if !isMovie {
            let what = ext.isEmpty
                ? "This file has no extension and isn't a video."
                : "This is a .\(ext) file" + (UTType(filenameExtension: ext)?.localizedDescription.map { " (\($0))" } ?? "") + ", not a video."
            return ImportFailure(title: "“\(file)” isn't compatible", reason: what + " " + Self.supportedFormats)
        }
        return nil
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        let src = queue.removeFirst()
        if let problem = compatibilityProblem(src) {
            log.error("rejected \(src.lastPathComponent, privacy: .public): \(problem.title, privacy: .public)")
            failures.append(problem)
            onChange?()
            return next()
        }
        busy = true
        let name = src.deletingPathExtension().lastPathComponent
        var out = dir.appending(path: name + ".mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = dir.appending(path: "\(name) \(n).mp4")
            n += 1
        }
        let tmp = dir.appending(path: out.deletingPathExtension().lastPathComponent + Self.tmpSuffix)
        setProgress(name, nil)

        Task {
            do {
                try await convert(src, to: tmp, name: name)
                try FileManager.default.moveItem(at: tmp, to: out)
                log.notice("converted \(src.lastPathComponent, privacy: .public) -> \(out.lastPathComponent, privacy: .public)")
                reload()
                onConverted?(out)
            } catch let failure as ImportFailure {
                try? FileManager.default.removeItem(at: tmp)
                log.error("failed \(src.lastPathComponent, privacy: .public): \(failure.reason, privacy: .public) \(failure.details ?? "", privacy: .public)")
                failures.append(failure)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                log.error("failed \(src.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failures.append(ImportFailure(
                    title: "“\(src.lastPathComponent)” couldn't be added",
                    reason: "The video was converted but couldn't be saved. Check that your disk isn't full.",
                    details: error.localizedDescription
                ))
            }
            converting = nil
            busy = false
            onChange?()
            next()
        }
    }

    private func setProgress(_ name: String, _ fraction: Double?) {
        converting = (name, fraction)
        onChange?()
    }

    /// Largest connected screen width in pixels; picks the export ceiling.
    private var maxPixelWidth: CGFloat {
        NSScreen.screens.map { $0.frame.width * $0.backingScaleFactor }.max() ?? 1920
    }

    private func convert(_ src: URL, to dst: URL, name: String) async throws {
        let file = src.lastPathComponent
        do {
            try await exportWithAVFoundation(src, to: dst, name: name)
        } catch let avError {
            log.notice("AVFoundation export failed (\(avError.localizedDescription, privacy: .public)); trying ffmpeg")
            guard let ffmpeg = Self.ffmpegPath else {
                throw ImportFailure(
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
                throw ImportFailure(
                    title: "“\(file)” is broken",
                    reason: "Neither macOS nor ffmpeg could read a video from it — the file is damaged or isn't really a video.",
                    details: "macOS: \(avError.localizedDescription)\nffmpeg: \(error.localizedDescription)"
                )
            }
            try? FileManager.default.removeItem(at: dst)
            do {
                try await exportWithAVFoundation(intermediate, to: dst, name: name)
            } catch {
                throw ImportFailure(
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

        let preset = maxPixelWidth > 1920 ? AVAssetExportPresetHEVC3840x2160 : AVAssetExportPresetHEVC1920x1080
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "HEVC export isn't available on this Mac."])
        }
        let watcher = Task { [weak self] in
            for await state in session.states(updateInterval: 0.5) {
                if case .exporting(let p) = state { self?.setProgress(name, p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: dst, as: .mp4)
    }

    private func decodeWithFFmpeg(_ ffmpeg: String, _ src: URL, to dst: URL) async throws {
        let width = maxPixelWidth > 1920 ? 3840 : 1920
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        // Arguments go straight to execve (no shell), so file names can't inject anything.
        process.arguments = [
            "-nostdin", "-v", "error", "-y", "-i", src.path,
            "-an", "-vf", "scale='min(iw,\(width))':-2",
            "-c:v", "prores_ks", "-profile:v", "0", "-f", "mov", dst.path,
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
