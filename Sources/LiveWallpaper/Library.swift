import AppKit
import AVFoundation
import os

/// Imported videos are converted to muted HEVC .mp4 (hardware-decoded, capped near screen size)
/// and stored in Application Support, where they become selectable wallpapers.
@MainActor
final class Library {
    struct Failure: LocalizedError { let errorDescription: String? }
    /// An import that couldn't be converted, shown to the user until dismissed.
    struct ImportFailure: Identifiable { let id = UUID(); let name: String; let reason: String }

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

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let src = queue.removeFirst()
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
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                log.error("failed \(src.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failures.append(ImportFailure(name: src.lastPathComponent, reason: error.localizedDescription))
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
        do {
            try await exportWithAVFoundation(src, to: dst, name: name)
        } catch {
            log.notice("AVFoundation export failed (\(error.localizedDescription, privacy: .public)); trying ffmpeg")
            guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
                .first(where: FileManager.default.isExecutableFile(atPath:)) else {
                throw Failure(errorDescription: "It's damaged, or in a format macOS can't read. For WebM, MKV or AVI, install ffmpeg (brew install ffmpeg) and try again.")
            }
            // ffmpeg only decodes into ProRes (built into every ffmpeg, read natively by macOS);
            // the final HEVC encode stays on the AVFoundation hardware path.
            let intermediate = dst.deletingPathExtension().appendingPathExtension("mov")
            defer { try? FileManager.default.removeItem(at: intermediate) }
            try await decodeWithFFmpeg(ffmpeg, src, to: intermediate)
            try? FileManager.default.removeItem(at: dst)
            try await exportWithAVFoundation(intermediate, to: dst, name: name)
        }
    }

    private func exportWithAVFoundation(_ src: URL, to dst: URL, name: String) async throws {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(errorDescription: "macOS can't read a video track from this file.")
        }
        // Video-only composition so the output carries no audio track.
        let comp = AVMutableComposition()
        guard let videoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure(errorDescription: "Couldn't prepare the video track.")
        }
        let (duration, transform) = try await (asset.load(.duration), track.load(.preferredTransform))
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        videoTrack.preferredTransform = transform

        let preset = maxPixelWidth > 1920 ? AVAssetExportPresetHEVC3840x2160 : AVAssetExportPresetHEVC1920x1080
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else {
            throw Failure(errorDescription: "HEVC export isn't available.")
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
                Logger(subsystem: "LiveWallpaper", category: "library").error("ffmpeg: \(message.suffix(500), privacy: .public)")
                cont.resume(throwing: Failure(errorDescription: "The file is damaged or isn't a video, so it couldn't be converted."))
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}
