import AVFoundation
import CoreImage
import VideoToolbox
import os

/// Upscales a low-resolution wallpaper to cover the display, with the engine chosen in Settings.
/// Model-based engines download their model only when an upscale is requested; anything that
/// can't run falls back to Lanczos and says why.
enum Upscaler {
    /// The user's choice in Settings.
    /// Smallest to largest model; `realESRGAN` keeps its old name so saved settings carry over.
    enum Engine: String, CaseIterable {
        case realESRGANSmall, realESRGAN, realESRGANLarge2x, realESRGANLarge, appleSuperResolution, basic

        var title: String {
            switch self {
            case .realESRGANSmall: "Real-ESRGAN Small"
            case .realESRGAN: "Real-ESRGAN Medium"
            case .realESRGANLarge2x: "Real-ESRGAN Large 2×"
            case .realESRGANLarge: "Real-ESRGAN Large 4×"
            case .appleSuperResolution: "Apple Super Resolution"
            case .basic: "Basic (no download)"
            }
        }

        /// What it's good at, in a sentence (shown behind the ⓘ button).
        var summary: String {
            switch self {
            case .realESRGANSmall: "The lightest Real-ESRGAN network (16 layers, 2.5 MB). Fastest of the ML upscalers and gentlest on older or 8 GB Macs. Trained on animation, so it's best for cartoons, anime, games and graphics."
            case .realESRGAN: "The general-purpose Real-ESRGAN video network (32 layers, 4.9 MB). A good balance of sharpness and speed for real-world footage on most Apple silicon Macs."
            case .realESRGANLarge2x: "The full Real-ESRGAN network (23 dense blocks, 64 MB) at 2×. Much more detail than Medium for videos that are only a little too small, like 1080p on a Retina display. Several times slower."
            case .realESRGANLarge: "The full Real-ESRGAN network (23 dense blocks, 64 MB) at 4×. The sharpest results for very small videos, and by far the slowest — best on Pro, Max or Ultra chips with plenty of memory."
            case .appleSuperResolution: "Apple's own video upscaler, built into macOS 26. Light on memory and keeps motion smooth between frames. macOS downloads and manages its model, so apps can't delete it."
            case .basic: "Classic Lanczos resizing with a little sharpening. Needs no download and is instant, but can't add real detail."
            }
        }

        /// The Real-ESRGAN network this engine runs, if it's one of them.
        var esrgan: RealESRGAN.Model? {
            switch self {
            case .realESRGANSmall: RealESRGAN.small
            case .realESRGAN: RealESRGAN.medium
            case .realESRGANLarge2x: RealESRGAN.large2x
            case .realESRGANLarge: RealESRGAN.large
            case .appleSuperResolution, .basic: nil
            }
        }

        static var current: Engine {
            get { UserDefaults.standard.string(forKey: "upscaler").flatMap(Engine.init) ?? .realESRGAN }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: "upscaler") }
        }
    }

    /// What actually did the upscaling.
    enum Method: Equatable {
        case realESRGAN(Engine), superResolution, lanczos
        var name: String {
            switch self {
            case .realESRGAN(let engine): "\(engine.title) (on-device ML)"
            case .superResolution: "Apple Super Resolution (on-device ML)"
            case .lanczos: "Lanczos scaling"
            }
        }
    }

    struct Result {
        let method: Method
        /// Why the chosen ML engine wasn't used, if it wasn't.
        var fallbackReason: String?
    }

    private static let log = Logger(subsystem: "LiveWallpaper", category: "upscale")

    /// Size that covers `display` with `video`'s aspect ratio: never smaller than the video, at most 4×, even dimensions.
    static func targetSize(for video: CGSize, display: CGSize) -> CGSize {
        guard video.width > 0, video.height > 0 else { return video }
        let scale = min(max(display.width / video.width, display.height / video.height, 1), 4)
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded() * 2 }
        return CGSize(width: even(video.width * scale), height: even(video.height * scale))
    }

    /// The method `engine` would use for a video of this size on this Mac.
    static func method(for engine: Engine, video: CGSize) -> Method {
        if let model = engine.esrgan { return fits(video, model) ? .realESRGAN(engine) : .lanczos }
        switch engine {
        case .appleSuperResolution: return superResolutionSupported(for: video) ? .superResolution : .lanczos
        default: return .lanczos
        }
    }

    /// Whether a Real-ESRGAN model takes a source this size.
    static func fits(_ video: CGSize, _ model: RealESRGAN.Model) -> Bool {
        max(video.width, video.height) <= model.maxInput.width && min(video.width, video.height) <= model.maxInput.height
    }

    /// Whether Apple's Super Resolution can handle this source size on this Mac.
    static func superResolutionSupported(for video: CGSize) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return configuration(for: video) != nil
    }

    /// Whether upscaling this video with `engine` needs a model download first.
    static func needsModelDownload(engine: Engine, video: CGSize) -> Bool {
        switch method(for: engine, video: video) {
        case .realESRGAN(let engine): return engine.esrgan?.isDownloaded == false
        case .superResolution:
            guard #available(macOS 26.0, *), let config = configuration(for: video) else { return false }
            return config.configurationModelStatus != .ready
        case .lanczos: return false
        }
    }

    /// Upscales `src` to `target` with `engine`. `allowModelDownload` permits fetching the engine's model.
    static func upscale(_ src: URL, to dst: URL, target: CGSize, engine: Engine, allowModelDownload: Bool,
                        progress: @escaping @MainActor (String, Double?, Int64?, Int64?) -> Void) async throws -> Result {
        var reason: String?
        do {
            switch engine {
            case .realESRGANSmall, .realESRGAN, .realESRGANLarge2x, .realESRGANLarge:
                try await realESRGAN(src, to: dst, target: target, engine: engine, allowModelDownload: allowModelDownload, progress: progress)
                return Result(method: .realESRGAN(engine))
            case .appleSuperResolution:
                guard #available(macOS 26.0, *) else { throw failure("Apple Super Resolution needs macOS 26 or later.") }
                try await superResolve(src, to: dst, target: target, allowModelDownload: allowModelDownload, progress: progress)
                return Result(method: .superResolution)
            case .basic:
                break
            }
        } catch {
            reason = describe(error)
            log.notice("\(engine.rawValue, privacy: .public) unavailable, using Lanczos: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: dst)
        }
        try await lanczos(src, to: dst, target: target, progress: progress)
        return Result(method: .lanczos, fallbackReason: reason)
    }

    /// Plain-language reason for an ML upscaling failure.
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == "VTFrameProcessorErrorDomain" else { return error.localizedDescription }
        switch nsError.code {
        case -19743: return "Apple's upscaling model couldn't be downloaded (check your internet connection, then try again)."
        default: return "Super Resolution failed (VideoToolbox error \(nsError.code))."
        }
    }

    private static func failure(_ text: String) -> Error {
        CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: text])
    }

    // MARK: Shared frame pipeline

    /// Reads every frame, lets `process` upscale it, resizes the result to exactly `target` with Lanczos,
    /// and encodes high-quality HEVC. `readerFormat` is the pixel format the engine wants.
    private static func transcode(_ asset: AVURLAsset, track: AVAssetTrack, to dst: URL, target: CGSize,
                                  readerFormat: Any, label: String,
                                  progress: @escaping @MainActor (String, Double?, Int64?, Int64?) -> Void,
                                  process: (CVPixelBuffer, CMTime) async throws -> CIImage) async throws {
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: readerFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        // The target is in display orientation; frames are in the track's own orientation.
        let quarterTurn = abs(transform.b) > 0.5
        let outSize = quarterTurn ? CGSize(width: target.height, height: target.width) : target
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(outSize.width),
            AVVideoHeightKey: Int(outSize.height),
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: UpscaleSettings.snapshot().quality],
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outSize.width),
            kCVPixelBufferHeightKey as String: Int(outSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? failure("Couldn't start upscaling.") }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let frame = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let image = try await process(frame, time)

            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? failure("The encoder stopped.") }
            var outBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
            guard let outBuffer else { throw failure("Out of memory while upscaling.") }
            let scaleY = outSize.height / image.extent.height
            let resized = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleY,
                kCIInputAspectRatioKey: (outSize.width / image.extent.width) / scaleY,
            ])
            context.render(resized.cropped(to: CGRect(origin: .zero, size: outSize)), to: outBuffer)

            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard adaptor.append(outBuffer, withPresentationTime: time) else { throw writer.error ?? failure("Couldn't write the upscaled video.") }
            if duration > 0 { await progress(label, time.seconds / duration, nil, nil) }
        }
        if reader.status == .failed { throw reader.error ?? failure("Couldn't read the video.") }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? failure("Couldn't finish the upscaled video.") }
    }

    // MARK: Real-ESRGAN

    private static func realESRGAN(_ src: URL, to dst: URL, target: CGSize, engine: Engine, allowModelDownload: Bool,
                                   progress: @escaping @MainActor (String, Double?, Int64?, Int64?) -> Void) async throws {
        guard let model = engine.esrgan else { return }
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw failure("No video track found.") }
        let natural = try await track.load(.naturalSize)
        guard fits(natural, model) else {
            throw failure("\(engine.title) handles videos up to \(Int(model.maxInput.width))×\(Int(model.maxInput.height)); this one is \(Int(natural.width))×\(Int(natural.height)).")
        }
        if !model.isDownloaded {
            guard allowModelDownload else { throw failure("The \(engine.title) model isn't downloaded.") }
            try await RealESRGAN.download(model) { received, total in
                Task { @MainActor in progress("Downloading the \(engine.title) model…", Double(received) / Double(total), received, total) }
            }
        }
        let settings = UpscaleSettings.snapshot()
        let network = try RealESRGAN.Network(model: model, width: Int(natural.width), height: Int(natural.height),
                                             tile: settings.tile(for: model), fullPrecision: settings.fullPrecision)
        var big: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(natural.width) * model.scale, Int(natural.height) * model.scale, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &big)
        guard let big else { throw failure("Out of memory while upscaling.") }
        try await transcode(asset, track: track, to: dst, target: target, readerFormat: kCVPixelFormatType_32BGRA,
                            label: "Upscaling with \(engine.title)…", progress: progress) { frame, _ in
            try network.upscale(frame, into: big)
            return CIImage(cvPixelBuffer: big)
        }
    }

    // MARK: Apple Super Resolution

    /// Has macOS download Apple's model now (without upscaling). `progress` gets (fraction, ~bytes, ~total).
    @available(macOS 26.0, *)
    static func downloadAppleModel(progress: @escaping @MainActor (Double, Int64, Int64) -> Void) async throws {
        guard let config = configuration(for: ModelAdvisor.typicalInput) else { throw failure("Apple Super Resolution isn't supported on this Mac.") }
        guard config.configurationModelStatus != .ready else { return }
        let total = ModelAdvisor.downloadSize(.appleSuperResolution) ?? 0
        let watcher = Task {
            while !Task.isCancelled {
                let fraction = Double(config.configurationModelPercentageAvailable) / 100
                await progress(fraction, Int64(fraction * Double(total)), total)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { watcher.cancel() }
        do { try await config.downloadConfigurationModel() } catch { throw failure(describe(error)) }
    }

    @available(macOS 26.0, *)
    private static func configuration(for video: CGSize) -> VTSuperResolutionScalerConfiguration? {
        guard VTSuperResolutionScalerConfiguration.isSupported else { return nil }
        return VTSuperResolutionScalerConfiguration(
            frameWidth: Int(video.width), frameHeight: Int(video.height), scaleFactor: 4,
            inputType: .video, usePrecomputedFlow: false, qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision)
    }

    @available(macOS 26.0, *)
    private static func superResolve(_ src: URL, to dst: URL, target: CGSize, allowModelDownload: Bool,
                                     progress: @escaping @MainActor (String, Double?, Int64?, Int64?) -> Void) async throws {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw failure("No video track found.") }
        let natural = try await track.load(.naturalSize)
        guard let config = configuration(for: natural) else {
            throw failure("Super Resolution doesn't support \(Int(natural.width))×\(Int(natural.height)) input on this Mac.")
        }

        if config.configurationModelStatus != .ready {
            guard allowModelDownload else { throw failure("Apple's upscaling model isn't downloaded.") }
            await progress("Downloading Apple's upscaling model…", nil, nil, nil)
            let watcher = Task {
                while !Task.isCancelled {
                    // macOS reports only a percentage; the size is Apple's (~70 MB).
                    let fraction = Double(config.configurationModelPercentageAvailable) / 100
                    let total = ModelAdvisor.downloadSize(.appleSuperResolution) ?? 0
                    await progress("Downloading Apple's upscaling model…", fraction, Int64(fraction * Double(total)), total)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { watcher.cancel() }
            try await config.downloadConfigurationModel()
            guard config.configurationModelStatus == .ready else { throw failure("The upscaling model didn't finish downloading.") }
        }

        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)
        defer { processor.endSession() }
        var scaledPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, config.destinationPixelBufferAttributes as CFDictionary, &scaledPool)
        guard let scaledPool,
              let format = config.sourcePixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] else {
            throw failure("Couldn't set up Super Resolution.")
        }

        var previousSource: VTFrameProcessorFrame?, previousOutput: VTFrameProcessorFrame?
        try await transcode(asset, track: track, to: dst, target: target, readerFormat: format,
                            label: "Upscaling with Apple Super Resolution…", progress: progress) { frame, time in
            var scaledBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, scaledPool, &scaledBuffer)
            guard let scaledBuffer,
                  let sourceFrame = VTFrameProcessorFrame(buffer: frame, presentationTimeStamp: time),
                  let scaledFrame = VTFrameProcessorFrame(buffer: scaledBuffer, presentationTimeStamp: time),
                  let parameters = VTSuperResolutionScalerParameters(
                      sourceFrame: sourceFrame, previousFrame: previousSource, previousOutputFrame: previousOutput,
                      opticalFlow: nil, submissionMode: .sequential, destinationFrame: scaledFrame)
            else { throw failure("Couldn't prepare a frame for upscaling.") }
            _ = try await processor.process(parameters: parameters)
            previousSource = sourceFrame
            previousOutput = scaledFrame
            return CIImage(cvPixelBuffer: scaledBuffer)
        }
    }

    // MARK: Lanczos

    private static func lanczos(_ src: URL, to dst: URL, target: CGSize,
                                progress: @escaping @MainActor (String, Double?, Int64?, Int64?) -> Void) async throws {
        let asset = AVURLAsset(url: src)
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let image = request.sourceImage
            let scaleY = target.height / image.extent.height
            let resized = image
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scaleY,
                    kCIInputAspectRatioKey: (target.width / image.extent.width) / scaleY,
                ])
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.25])
            request.finish(with: resized.cropped(to: CGRect(origin: .zero, size: target)), context: nil)
        }
        composition.renderSize = target
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw failure("HEVC export isn't available on this Mac.")
        }
        session.videoComposition = composition
        let watcher = Task {
            for await state in session.states(updateInterval: 0.5) {
                if case .exporting(let p) = state { await progress("Upscaling with Lanczos…", p.fractionCompleted, nil, nil) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: dst, as: .mp4)
    }
}
