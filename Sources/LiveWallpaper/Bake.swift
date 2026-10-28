import AVFoundation
import CoreImage

/// Colour and finish adjustments for a wallpaper. Neutral by default.
struct Look: Codable, Equatable, Sendable {
    /// −0.5…0.5 (0 = unchanged).
    var brightness = 0.0
    /// 0.5…1.5 (1 = unchanged).
    var contrast = 1.0
    /// 0…2 (1 = unchanged, 0 = black and white).
    var saturation = 1.0
    /// −1 (cooler) … 1 (warmer).
    var warmth = 0.0
    /// 0…1, a soft focus (0 = sharp).
    var blur = 0.0
    /// 0…1, darkens the corners.
    var vignette = 0.0

    var isNeutral: Bool { self == Look() }

    /// The adjusted picture, same extent as `image`.
    func apply(to image: CIImage) -> CIImage {
        guard !isNeutral else { return image }
        let extent = image.extent
        var out = image.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation,
        ])
        if warmth != 0 {
            // Shifting the neutral point the other way warms (or cools) the picture.
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - warmth * 2500, y: 0),
            ])
        }
        if blur > 0 {
            // Radius scales with the picture so the look is the same at any resolution.
            let radius = blur * extent.height / 80
            out = out.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        }
        if vignette > 0 {
            out = out.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: vignette * 1.5, kCIInputRadiusKey: 2.0])
        }
        return out.cropped(to: extent)
    }
}

/// What a baked copy was made from; a new bake is needed when any of it changes.
struct BakeKey: Codable, Equatable {
    var look: Look
    var loopFade: Double
    var trimStart: Double
    var trimEnd: Double?
}

extension Edits {
    var lookOrNeutral: Look { look ?? Look() }
    var loopFadeSeconds: Double { loopFade ?? 0 }
    /// A baked copy is played instead of the original when there's a look or a seamless loop.
    var needsBake: Bool { !lookOrNeutral.isNeutral || loopFadeSeconds > 0 }
    var bakeKey: BakeKey { BakeKey(look: lookOrNeutral, loopFade: loopFadeSeconds, trimStart: trimStart, trimEnd: trimEnd) }
}

/// Renders a wallpaper's look and seamless loop into a file once, so playback costs nothing extra.
enum Baker {
    /// Writes `src` with `edits`' trim, loop crossfade and look applied to `dst` (HEVC).
    static func bake(_ src: URL, edits: Edits, to dst: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw failure("No video track found.") }
        let duration = try await asset.load(.duration).seconds
        let start = min(edits.trimStart, max(duration - 0.2, 0)), end = min(edits.trimEnd ?? duration, duration)
        let look = edits.lookOrNeutral
        var source = asset
        var range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        var temp: URL?
        defer { temp.map { try? FileManager.default.removeItem(at: $0) } }

        if edits.loopFadeSeconds > 0 {
            // Seamless loop: drop the first d seconds and cross-fade them over the last d seconds, so the
            // final frame becomes the (new) first frame and the jump disappears.
            let fade = min(edits.loopFadeSeconds, (end - start) / 3)
            let length = end - start - fade
            let composition = AVMutableComposition()
            guard let main = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let head = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw failure("Couldn't prepare the loop.") }
            let t = { (s: Double) in CMTime(seconds: s, preferredTimescale: 600) }
            try main.insertTimeRange(CMTimeRange(start: t(start + fade), end: t(end)), of: track, at: .zero)
            try head.insertTimeRange(CMTimeRange(start: t(start), duration: t(fade)), of: track, at: t(length - fade))
            let transform = try await track.load(.preferredTransform)
            main.preferredTransform = transform
            head.preferredTransform = transform

            let plain = AVMutableVideoCompositionInstruction()
            plain.timeRange = CMTimeRange(start: .zero, end: t(length - fade))
            let mainOnly = AVMutableVideoCompositionLayerInstruction(assetTrack: main)
            mainOnly.setTransform(transform, at: .zero)
            plain.layerInstructions = [mainOnly]
            let blend = AVMutableVideoCompositionInstruction()
            blend.timeRange = CMTimeRange(start: t(length - fade), end: t(length))
            let fadeIn = AVMutableVideoCompositionLayerInstruction(assetTrack: head)
            fadeIn.setTransform(transform, at: .zero)
            fadeIn.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: blend.timeRange)
            let under = AVMutableVideoCompositionLayerInstruction(assetTrack: main)
            under.setTransform(transform, at: .zero)
            blend.layerInstructions = [fadeIn, under]

            let video = AVMutableVideoComposition()
            video.instructions = [plain, blend]
            let natural = try await track.load(.naturalSize).applying(transform)
            video.renderSize = CGSize(width: abs(natural.width), height: abs(natural.height))
            video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(try await track.load(.nominalFrameRate).rounded(), 1)))

            let looped = look.isNeutral ? dst : dst.deletingLastPathComponent().appending(path: UUID().uuidString + ".loop.mp4")
            if !look.isNeutral { temp = looped }
            try await export(composition, video: video, range: nil, to: looped) { await progress(look.isNeutral ? $0 : $0 / 2) }
            guard !look.isNeutral else { return }
            source = AVURLAsset(url: looped)
            range = CMTimeRange(start: .zero, duration: t(length))
        }

        // Look: each frame through the same Core Image adjustments the editor previews.
        let video = try await AVMutableVideoComposition.videoComposition(with: source) { request in
            let image = request.sourceImage
            request.finish(with: look.apply(to: image).cropped(to: image.extent), context: nil)
        }
        let half = edits.loopFadeSeconds > 0
        try await export(source, video: video, range: range, to: dst) { await progress(half ? 0.5 + $0 / 2 : $0) }
    }

    private static func export(_ asset: AVAsset, video: AVVideoComposition, range: CMTimeRange?, to dst: URL,
                               progress: @escaping @Sendable (Double) async -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw failure("HEVC export isn't available on this Mac.")
        }
        session.videoComposition = video
        if let range { session.timeRange = range }
        let watcher = Task {
            for await state in session.states(updateInterval: 0.5) {
                if case .exporting(let p) = state { await progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try? FileManager.default.removeItem(at: dst)
        try await session.export(to: dst, as: .mp4)
    }

    static func failure(_ text: String) -> Error {
        CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
