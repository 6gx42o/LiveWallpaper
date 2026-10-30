import AVFoundation
import AppKit
import os

/// A moving lock screen. Apps can't draw on the lock screen, but macOS plays Apple's aerial wallpapers
/// there. So when your wallpaper (System Settings › Wallpaper) is an aerial, LiveWallpaper swaps that
/// aerial's video for yours. Apple's original is kept and put back when you switch this off.
/// The video lives in a system folder, so macOS asks for your password each time it's replaced.
@MainActor
enum LiveLockScreen {
    enum Failure: LocalizedError {
        case noAerial, notDownloaded(String), cancelled, failed(String)
        var errorDescription: String? {
            switch self {
            case .noAerial:
                "Your wallpaper isn't an aerial yet. In System Settings › Wallpaper, choose an aerial (New York is already downloaded) for your wallpaper, then try again."
            case .notDownloaded(let id):
                "The aerial you chose (\(id)) hasn't finished downloading. Wait for it in System Settings › Wallpaper, then try again."
            case .cancelled: "Cancelled."
            case .failed(let message): message
            }
        }
    }

    /// Tests point these at a fake aerial folder and wallpaper store and run without a password.
    private nonisolated static let testing = ProcessInfo.processInfo.environment["LW_TEST_AERIALS_DIR"] != nil
    nonisolated static let aerialsDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LW_TEST_AERIALS_DIR"]
        ?? "/Library/Application Support/com.apple.idleassetsd/Customer")
    nonisolated static let wallpaperStore = ProcessInfo.processInfo.environment["LW_TEST_WALLPAPER_STORE"].map(URL.init(fileURLWithPath:))
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    /// The aerial whose video is currently ours (its original is in `backup(for:)`).
    private static let replacedKey = "liveLockAerial"
    private static let log = Logger(subsystem: "LiveWallpaper", category: "lockscreen")

    static var replacedAerial: String? { UserDefaults.standard.string(forKey: replacedKey) }

    /// Puts `video` (with `edits`' trim) on the lock screen in place of the desktop aerial's video.
    static func apply(video: URL, edits: Edits) async throws {
        guard let id = desktopAerial(in: wallpaperStore) else { throw Failure.noAerial }
        guard let slot = aerialFile(id, in: aerialsDir) else { throw Failure.notDownloaded(id) }
        try FileManager.default.createDirectory(at: LockScreen.dir, withIntermediateDirectories: true)

        // The clip, trimmed like the wallpaper, as a QuickTime movie (no re-encoding).
        let clip = LockScreen.dir.appending(path: "live.mov")
        try? FileManager.default.removeItem(at: clip)
        let asset = AVURLAsset(url: video)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.failed("This video can't be prepared for the lock screen.")
        }
        let duration = try await asset.load(.duration).seconds
        let end = min(edits.trimEnd ?? duration, duration)
        session.timeRange = CMTimeRange(start: CMTime(seconds: edits.trimStart, preferredTimescale: 600),
                                        end: CMTime(seconds: end, preferredTimescale: 600))
        try await session.export(to: clip, as: .mov)

        // Keep Apple's original once (it's readable by everyone, so no password needed for this).
        var commands: [String] = []
        if let previous = replacedAerial, previous != id, let previousSlot = aerialFile(previous, in: aerialsDir),
           FileManager.default.fileExists(atPath: backup(for: previous).path) {
            commands.append(copyCommand(from: backup(for: previous), to: previousSlot)) // a different aerial is chosen now
        }
        if !FileManager.default.fileExists(atPath: backup(for: id).path) {
            try FileManager.default.copyItem(at: slot, to: backup(for: id))
        }
        commands.append(copyCommand(from: clip, to: slot))
        try await runAsAdmin(commands, prompt: "LiveWallpaper needs your password to play your wallpaper on the lock screen. It replaces the video of the aerial you chose in System Settings; Apple's original is kept.")
        if let previous = replacedAerial, previous != id { try? FileManager.default.removeItem(at: backup(for: previous)) }
        UserDefaults.standard.set(id, forKey: replacedKey)
        try? FileManager.default.removeItem(at: clip)
        reloadWallpaper()
        log.notice("moving lock screen: \(video.lastPathComponent, privacy: .public) in aerial \(id, privacy: .public)")
    }

    /// Puts Apple's aerial video back.
    static func restore() async throws {
        guard let id = replacedAerial else { return }
        if let slot = aerialFile(id, in: aerialsDir), FileManager.default.fileExists(atPath: backup(for: id).path) {
            try await runAsAdmin([copyCommand(from: backup(for: id), to: slot)],
                                 prompt: "LiveWallpaper needs your password to put Apple's aerial video back on your lock screen.")
            try? FileManager.default.removeItem(at: backup(for: id))
        }
        UserDefaults.standard.removeObject(forKey: replacedKey)
        reloadWallpaper()
        log.notice("restored aerial \(id, privacy: .public)")
    }

    private static func backup(for id: String) -> URL { LockScreen.dir.appending(path: "aerial-original-\(id).mov") }

    /// Restarts macOS's aerial player so it picks up the new video (it starts again by itself).
    private static func reloadWallpaper() {
        guard !testing else { return }
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["WallpaperAerialsExtension", "WallpaperAgent"]
        try? kill.run()
    }

    // MARK: Privileged copy

    /// Root writes the bytes; reading happens as you (`sudo -u`), so a swapped-in link can't make it copy a
    /// file you can't read. Destinations are aerial files in a folder only root can change.
    private static func copyCommand(from source: URL, to destination: URL) -> String {
        (testing ? "" : "/usr/bin/sudo -u '#\(getuid())' ") + "/bin/cat \(shellQuoted(source.path)) > \(shellQuoted(destination.path)) && /bin/chmod 644 \(shellQuoted(destination.path))"
    }

    private static func runAsAdmin(_ commands: [String], prompt: String) async throws {
        let shell = commands.joined(separator: " && ")
        let script = "do shell script \(appleScriptQuoted(shell))" + (testing ? "" : " with administrator privileges with prompt \(appleScriptQuoted(prompt))")
        let (status, message) = await withCheckedContinuation { (done: CheckedContinuation<(Int32, String), Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { p in
                done.resume(returning: (p.terminationStatus, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)))
            }
            do { try process.run() } catch { done.resume(returning: (-1, error.localizedDescription)) }
        }
        guard status == 0 else {
            throw message.contains("-128") ? Failure.cancelled : Failure.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    nonisolated static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    nonisolated static func appleScriptQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Reading macOS's wallpaper choice (read-only)

    /// The aerial most recently chosen as a desktop wallpaper, from macOS's wallpaper store.
    nonisolated static func desktopAerial(in store: URL) -> String? {
        guard let data = try? Data(contentsOf: store),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        var best: (id: String, date: Date)?
        func visit(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let desktop = dict["Desktop"] as? [String: Any], let id = aerialID(in: desktop) {
                    let date = desktop["LastSet"] as? Date ?? .distantPast
                    if best == nil || date > best!.date { best = (id, date) }
                }
                dict.values.forEach(visit)
            } else if let array = node as? [Any] {
                array.forEach(visit)
            }
        }
        visit(root)
        return best?.id
    }

    private nonisolated static func aerialID(in desktop: [String: Any]) -> String? {
        guard let content = desktop["Content"] as? [String: Any], let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first, choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
              let configuration = choice["Configuration"] as? Data,
              let decoded = try? PropertyListSerialization.propertyList(from: configuration, format: nil) as? [String: Any],
              let id = decoded["assetID"] as? String, UUID(uuidString: id) != nil else { return nil }
        return id
    }

    /// The downloaded video for aerial `id` (any quality folder), or nil.
    nonisolated static func aerialFile(_ id: String, in dir: URL) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appending(path: "\(id).mov") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
