import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Turns GIFs, animated WebP/PNG and still images into HEVC video, using ImageIO (no ffmpeg needed).
enum AnimatedImage {
    /// A file ImageIO can read as one or more frames (GIF, WebP, PNG/APNG, JPEG, HEIC…).
    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    /// Encodes every frame with its own delay. A still image becomes a 5-second clip at 1 fps,
    /// so it costs almost nothing to play.
    static func convert(_ src: URL, to dst: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The image couldn't be read."])
        }
        let count = CGImageSourceGetCount(source)
        // Video encoders need even dimensions.
        let width = max(2, first.width / 2 * 2), height = max(2, first.height / 2 * 2)

        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.9],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        var time = CMTime.zero
        let frames: [(index: Int, delay: Double)] = count == 1
            ? (0..<5).map { _ in (0, 1.0) }
            : (0..<count).map { ($0, delay(source, at: $0)) }
        for (n, frame) in frames.enumerated() {
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateImageAtIndex(source, frame.index, nil),
                  let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            draw(image, into: buffer, width: width, height: height)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer, withPresentationTime: time)
            time = time + CMTime(seconds: frame.delay, preferredTimescale: 600)
            await progress(Double(n + 1) / Double(frames.count))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: time)
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Frame delay in seconds; like browsers, very short delays are treated as 0.1 s.
    private static func delay(_ source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]
        for (dictionary, unclamped, clamped) in containers {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            let value = (values[unclamped] as? Double) ?? (values[clamped] as? Double) ?? 0.1
            return value < 0.02 ? 0.1 : value
        }
        return 0.1
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        // Transparent areas become black, like the wallpaper background.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
