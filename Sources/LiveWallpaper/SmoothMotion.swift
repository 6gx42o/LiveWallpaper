import AVFoundation
import CoreImage
import VideoToolbox

/// Makes a smooth 60 fps copy of a 24/25/30 fps video with Apple's on-device frame interpolation
/// (VideoToolbox frame-rate conversion, macOS 15.4+). Built into macOS — nothing to download.
@available(macOS 15.4, *)
enum SmoothMotion {
    static var isSupported: Bool { VTFrameRateConversionConfiguration.isSupported }

    /// Writes `src` at `targetFPS` to `dst`: frames on the new time grid that fall on an original frame are
    /// copied, the rest are interpolated between their two neighbours.
    static func convert(_ src: URL, to dst: URL, targetFPS: Double = 60,
                        progress: @escaping @MainActor (Double) -> Void) async throws {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw failure("No video track found.") }
        let (size, transform, fps) = try await (track.load(.naturalSize), track.load(.preferredTransform), track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        guard Double(fps) < targetFPS - 1 else { throw failure("It's already \(Int(fps.rounded())) fps.") }
        guard let config = VTFrameRateConversionConfiguration(
            frameWidth: Int(size.width), frameHeight: Int(size.height), usePrecomputedFlow: false,
            qualityPrioritization: .quality, revision: VTFrameRateConversionConfiguration.defaultRevision),
            let format = config.sourcePixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String]
        else { throw failure("Smooth motion doesn't support \(Int(size.width))×\(Int(size.height)) video on this Mac.") }

        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)
        defer { processor.endSession() }
        var interpolatedPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, config.destinationPixelBufferAttributes as CFDictionary, &interpolatedPool)
        guard let interpolatedPool else { throw failure("Couldn't set up smooth motion.") }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.9, AVVideoExpectedSourceFrameRateKey: targetFPS],
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? failure("Couldn't start.") }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        func write(_ buffer: CVPixelBuffer, at seconds: Double) async throws {
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? failure("The encoder stopped.") }
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard let out else { throw failure("Out of memory.") }
            context.render(CIImage(cvPixelBuffer: buffer), to: out)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard adaptor.append(out, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 6000)) else {
                throw writer.error ?? failure("Couldn't write the video.")
            }
        }

        let step = 1 / targetFPS
        var grid = 0.0 // next output time
        var previous: (sample: CMSampleBuffer, frame: VTFrameProcessorFrame, buffer: CVPixelBuffer, time: Double)?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: pts) else { continue }
            let time = pts.seconds
            if let prev = previous {
                var times: [Double] = []
                while grid < time - 1e-6 {
                    if grid <= prev.time + 1e-4 { try await write(prev.buffer, at: grid) } else { times.append(grid) }
                    grid += step
                }
                if !times.isEmpty {
                    var destinations: [VTFrameProcessorFrame] = []
                    for t in times {
                        var buffer: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, interpolatedPool, &buffer)
                        guard let buffer, let destination = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 6000))
                        else { throw failure("Out of memory.") }
                        destinations.append(destination)
                    }
                    guard let parameters = VTFrameRateConversionParameters(
                        sourceFrame: prev.frame, nextFrame: frame, opticalFlow: nil,
                        interpolationPhase: times.map { Float(($0 - prev.time) / (time - prev.time)) },
                        submissionMode: .sequential, destinationFrames: destinations)
                    else { throw failure("Couldn't prepare frames for interpolation.") }
                    _ = try await processor.process(parameters: parameters)
                    for (destination, t) in zip(destinations, times) { try await write(destination.buffer, at: t) }
                }
            }
            previous = (sample, frame, buffer, time)
            if duration > 0 { await progress(time / duration) }
        }
        // Hold the last frame until the end of the video.
        if let prev = previous {
            while grid < duration - 1e-6 { try await write(prev.buffer, at: grid); grid += step }
        }
        if reader.status == .failed { throw reader.error ?? failure("Couldn't read the video.") }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? failure("Couldn't finish the video.") }
    }

    static func failure(_ text: String) -> Error {
        CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
