import AVFoundation
import CoreImage
import VideoToolbox
import os

/// Upscales a low-resolution wallpaper to cover the display.
/// Prefers Apple's on-device ML Super Resolution (macOS 26+, Apple silicon); falls back to Lanczos.
enum Upscaler {
    enum Method {
        case superResolution, lanczos
        var name: String { self == .superResolution ? "Apple Super Resolution (on-device ML)" : "Lanczos scaling" }
    }

    struct Result {
        let method: Method
        /// Why Super Resolution wasn't used, if it wasn't.
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

    /// Whether Super Resolution can handle this source size on this Mac.
    static func superResolutionSupported(for video: CGSize) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return configuration(for: video) != nil
    }

    /// Super Resolution's model is fetched by macOS (from Apple) the first time it's used.
    static func needsModelDownload(for video: CGSize) -> Bool {
        guard #available(macOS 26.0, *), let config = configuration(for: video) else { return false }
        return config.configurationModelStatus != .ready
    }

    /// Upscales `src` to `target`. `allowModelDownload` lets macOS fetch the Super Resolution model if needed.
    static func upscale(_ src: URL, to dst: URL, target: CGSize, allowModelDownload: Bool,
                        progress: @escaping @MainActor (String, Double?) -> Void) async throws -> Result {
        var reason: String?
        if #available(macOS 26.0, *) {
            do {
                try await superResolve(src, to: dst, target: target, allowModelDownload: allowModelDownload, progress: progress)
                return Result(method: .superResolution)
            } catch {
                reason = describe(error)
                log.notice("Super Resolution unavailable, using Lanczos: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: dst)
            }
        } else {
            reason = "Super Resolution needs macOS 26 or later."
        }
        try await lanczos(src, to: dst, target: target, progress: progress)
        return Result(method: .lanczos, fallbackReason: reason)
    }

    /// Plain-language reason for a Super Resolution failure.
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

    // MARK: Super Resolution

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
                                     progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw failure("No video track found.") }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let duration = try await asset.load(.duration).seconds
        guard let config = configuration(for: natural) else {
            throw failure("Super Resolution doesn't support \(Int(natural.width))×\(Int(natural.height)) input on this Mac.")
        }

        if config.configurationModelStatus != .ready {
            guard allowModelDownload else { throw failure("Apple's upscaling model isn't downloaded.") }
            await progress("Downloading Apple's upscaling model…", nil)
            let watcher = Task {
                while !Task.isCancelled {
                    await progress("Downloading Apple's upscaling model…", Double(config.configurationModelPercentageAvailable) / 100)
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

        // Decode in the pixel format the scaler wants, IOSurface-backed.
        let reader = try AVAssetReader(asset: asset)
        var readerSettings: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        if let format = config.sourcePixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] {
            readerSettings[kCVPixelBufferPixelFormatTypeKey as String] = format
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
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
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.85],
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

        var scaledPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, config.destinationPixelBufferAttributes as CFDictionary, &scaledPool)
        guard let scaledPool, reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? failure("Couldn't start upscaling.")
        }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        var previousSource: VTFrameProcessorFrame?, previousOutput: VTFrameProcessorFrame?
        while let sample = output.copyNextSampleBuffer() {
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            var scaledBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, scaledPool, &scaledBuffer)
            guard let scaledBuffer,
                  let sourceFrame = VTFrameProcessorFrame(buffer: sourceBuffer, presentationTimeStamp: time),
                  let scaledFrame = VTFrameProcessorFrame(buffer: scaledBuffer, presentationTimeStamp: time),
                  let parameters = VTSuperResolutionScalerParameters(
                      sourceFrame: sourceFrame, previousFrame: previousSource, previousOutputFrame: previousOutput,
                      opticalFlow: nil, submissionMode: .sequential, destinationFrame: scaledFrame)
            else { throw failure("Couldn't prepare a frame for upscaling.") }
            _ = try await processor.process(parameters: parameters)
            previousSource = sourceFrame
            previousOutput = scaledFrame

            // 4× output → exactly the target size, with high-quality resampling.
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? failure("The encoder stopped.") }
            var outBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
            guard let outBuffer else { throw failure("Out of memory while upscaling.") }
            let image = CIImage(cvPixelBuffer: scaledBuffer)
            let scaleY = outSize.height / image.extent.height
            let resized = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleY,
                kCIInputAspectRatioKey: (outSize.width / image.extent.width) / scaleY,
            ])
            context.render(resized.cropped(to: CGRect(origin: .zero, size: outSize)), to: outBuffer)

            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard adaptor.append(outBuffer, withPresentationTime: time) else { throw writer.error ?? failure("Couldn't write the upscaled video.") }
            if duration > 0 { await progress("Upscaling with Apple Super Resolution…", time.seconds / duration) }
        }
        if reader.status == .failed { throw reader.error ?? failure("Couldn't read the video.") }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? failure("Couldn't finish the upscaled video.") }
    }

    // MARK: Lanczos fallback

    private static func lanczos(_ src: URL, to dst: URL, target: CGSize,
                                progress: @escaping @MainActor (String, Double?) -> Void) async throws {
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
                if case .exporting(let p) = state { await progress("Upscaling with Lanczos…", p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: dst, as: .mp4)
    }
}
