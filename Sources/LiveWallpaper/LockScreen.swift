import AVFoundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import os

/// macOS doesn't let apps draw on the lock screen; it shows the desktop picture there.
/// So the lock screen wallpaper is a full-quality still from a video, set as the desktop picture
/// (the video window covers it on the home screen). The user's own picture is saved and restored.
@MainActor
enum LockScreen {
    private static let originalsKey = "originalDesktopPictures"
    private static let log = Logger(subsystem: "LiveWallpaper", category: "lockscreen")
    static let dir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "LiveWallpaper/LockScreen", directoryHint: .isDirectory)
    }()

    /// Saves the frame at `edits.lockFrame` (framed like the wallpaper) and makes it the desktop/lock screen picture.
    static func apply(video: URL, edits: Edits) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (frame, _) = try await generator.image(at: CMTime(seconds: edits.lockFrame, preferredTimescale: 600))
        let crop = edits.cropRect(image: CGSize(width: frame.width, height: frame.height), display: Display.pixelSize)
        var still = frame.cropping(to: crop) ?? frame
        // The lock screen gets the same look as the wallpaper.
        if !edits.lookOrNeutral.isNeutral,
           let adjusted = CIContext().createCGImage(edits.lookOrNeutral.apply(to: CIImage(cgImage: still)), from: CGRect(x: 0, y: 0, width: still.width, height: still.height)) {
            still = adjusted
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A new file name each time, otherwise macOS keeps showing its cached copy.
        let file = dir.appending(path: "lock-\(Int(Date().timeIntervalSince1970)).heic")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, still, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }

        saveOriginals()
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: edits.fill,
            .fillColor: NSColor.black,
        ]
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: options)
        }
        removeStills(except: file)
        log.notice("lock screen set to \(video.lastPathComponent, privacy: .public) @ \(edits.lockFrame)s")
    }

    /// Puts the user's own desktop picture back.
    static func restore() {
        let originals = UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: [String: Any]] ?? [:]
        for screen in NSScreen.screens {
            guard let saved = originals[key(for: screen)] ?? originals.values.first,
                  let path = saved["path"] as? String else { continue }
            var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
            if let scaling = saved["scaling"] as? Int { options[.imageScaling] = scaling }
            if let clipping = saved["clipping"] as? Bool { options[.allowClipping] = clipping }
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: options)
        }
        UserDefaults.standard.removeObject(forKey: originalsKey)
        removeStills(except: nil)
        log.notice("restored original desktop picture")
    }

    /// Remembers the user's pictures the first time we replace them.
    private static func saveOriginals() {
        guard UserDefaults.standard.dictionary(forKey: originalsKey) == nil else { return }
        var originals: [String: [String: Any]] = [:]
        for screen in NSScreen.screens {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            var entry: [String: Any] = ["path": url.path]
            if let scaling = options[.imageScaling] as? NSNumber { entry["scaling"] = scaling.intValue }
            if let clipping = options[.allowClipping] as? NSNumber { entry["clipping"] = clipping.boolValue }
            originals[key(for: screen)] = entry
        }
        UserDefaults.standard.set(originals, forKey: originalsKey)
    }

    private static func key(for screen: NSScreen) -> String {
        "\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0)"
    }

    private static func removeStills(except keep: URL?) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("lock-") && file != keep {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
