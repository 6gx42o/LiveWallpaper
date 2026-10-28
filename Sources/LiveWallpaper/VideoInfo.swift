import AVFoundation
import AppKit

/// Facts about a video file, read once.
struct VideoInfo {
    /// Pixel size as displayed (rotation applied).
    var size: CGSize
    var duration: Double
    var fps: Double
    /// Bits per second (0 if unknown).
    var bitrate: Double

    static func load(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "No video track found."])
        }
        let (natural, transform, fps, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate)
        let duration = try await asset.load(.duration).seconds
        let rotated = CGRect(origin: .zero, size: natural).applying(transform)
        return VideoInfo(size: CGSize(width: abs(rotated.width), height: abs(rotated.height)),
                         duration: duration.isFinite ? duration : 0, fps: Double(fps), bitrate: Double(rate))
    }

    var resolutionText: String { "\(Int(size.width))×\(Int(size.height))" }
}

/// Something the user should know about how a video will look on their display.
struct QualityIssue: Hashable {
    enum Severity { case warning, note }
    let severity: Severity
    let text: String
    /// Upscaling would help.
    var isLowResolution = false
}

enum Display {
    /// The resolution wallpapers are judged and upscaled against: the display's native resolution
    /// unless another is chosen in Settings.
    static var pixelSize: CGSize { ResolutionChoice.current.size }
}

extension VideoInfo {
    /// How this video will look on a display of `display` pixels with the given framing.
    /// `includeSource` adds checks that only make sense for the original file (bitrate).
    func issues(on display: CGSize, edits: Edits = Edits(), includeSource: Bool = false) -> [QualityIssue] {
        guard size.width > 0, size.height > 0 else { return [] }
        var issues: [QualityIssue] = []
        let displayText = "\(Int(display.width))×\(Int(display.height))"

        let stretch = edits.fill
            ? max(display.width / size.width, display.height / size.height)
            : min(display.width / size.width, display.height / size.height)
        if stretch > 1.5 {
            issues.append(QualityIssue(severity: .warning, text: "Low resolution: \(resolutionText) is stretched \(String(format: "%.1f", stretch))× to fill your \(displayText) display, so it will look soft. Upscaling can help.", isLowResolution: true))
        } else if stretch > 1.15 {
            issues.append(QualityIssue(severity: .note, text: "Slightly below your display's resolution (\(resolutionText) on \(displayText)); expect a little softness.", isLowResolution: true))
        }

        let videoRatio = size.width / size.height, displayRatio = display.width / display.height
        if abs(videoRatio - displayRatio) / displayRatio > 0.03 {
            let ratios = "\(String(format: "%.2f", videoRatio)):1 video on a \(String(format: "%.2f", displayRatio)):1 display"
            if edits.fill {
                let cropped = Int(((1 - min(videoRatio / displayRatio, displayRatio / videoRatio)) * 100).rounded())
                let edge = videoRatio > displayRatio ? "left and right" : "top and bottom"
                issues.append(QualityIssue(severity: .note, text: "Aspect ratio doesn't match: \(ratios). About \(cropped)% is cropped from the \(edge) — adjust Position in Edit, or choose Fit."))
            } else {
                issues.append(QualityIssue(severity: .note, text: "Aspect ratio doesn't match: \(ratios), so it shows with black bars (Fit). Choose Fill to cover the screen."))
            }
        }

        if fps > 0, fps < 20 {
            issues.append(QualityIssue(severity: .note, text: "Low frame rate (\(Int(fps.rounded())) fps); motion may look choppy."))
        }
        if includeSource, bitrate > 0, fps > 0 {
            let bitsPerPixel = bitrate / (size.width * size.height * fps)
            // Bitrate alone can't tell simple content (gradients) from bad compression, so this is only a note.
            if bitsPerPixel < 0.015 {
                issues.append(QualityIssue(severity: .note, text: "Low bitrate (\(String(format: "%.1f", bitrate / 1_000_000)) Mbps for \(resolutionText)): detailed scenes may look blocky. Re-encoding can't restore lost detail."))
            }
        }
        return issues
    }
}

/// Non-destructive per-wallpaper edits, applied at playback time.
struct Edits: Codable, Equatable {
    var trimStart = 0.0
    /// nil = play to the end.
    var trimEnd: Double?
    /// Fill crops to cover the screen; Fit letterboxes.
    var fill = true
    /// Pan within the cropped area: -1 = left/top edge, 0 = centre, 1 = right/bottom edge.
    var offsetX = 0.0
    var offsetY = 0.0
    var speed = 1.0
    /// Seconds into the video used for the lock screen still.
    var lockFrame = 0.0
    /// Colour/finish adjustments (nil = none). Optional so older saved edits still load.
    var look: Look?
    /// Seamless-loop cross-fade length in seconds (nil/0 = off).
    var loopFade: Double?

    var isTrimmed: Bool { trimStart > 0 || trimEnd != nil }

    func timeRange(duration: Double) -> CMTimeRange? {
        guard isTrimmed, duration > 0 else { return nil }
        let end = min(trimEnd ?? duration, duration)
        guard end - trimStart > 0.1 else { return nil }
        return CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
    }

    /// Where to draw a `video`-sized picture inside `bounds` (bottom-left origin) for this framing.
    static func playerFrame(video: CGSize, in bounds: CGRect, edits: Edits) -> CGRect {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = edits.fill
            ? max(bounds.width / video.width, bounds.height / video.height)
            : min(bounds.width / video.width, bounds.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        let excessX = size.width - bounds.width, excessY = size.height - bounds.height
        let panX = edits.fill ? edits.offsetX : 0, panY = edits.fill ? edits.offsetY : 0
        return CGRect(x: bounds.minX - excessX * (panX + 1) / 2,
                      y: bounds.minY - excessY * (1 - panY) / 2,
                      width: size.width, height: size.height)
    }

    /// The part of an `image`-sized still (top-left origin) that this framing shows on a `display`.
    func cropRect(image: CGSize, display: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: image)
        guard fill, image.width > 0, image.height > 0, display.width > 0, display.height > 0 else { return full }
        let imageRatio = image.width / image.height, displayRatio = display.width / display.height
        if imageRatio > displayRatio {
            let width = image.height * displayRatio
            return CGRect(x: (image.width - width) * (offsetX + 1) / 2, y: 0, width: width, height: image.height).integral
        } else {
            let height = image.width / displayRatio
            return CGRect(x: 0, y: (image.height - height) * (offsetY + 1) / 2, width: image.width, height: height).integral
        }
    }
}
