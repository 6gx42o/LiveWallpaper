import CoreVideo
import CryptoKit
import Foundation
import Metal
import MetalPerformanceShadersGraph

/// Real-ESRGAN (BSD-3, © Xintao Wang): the compact video model `realesr-general-x4v3`, run on the GPU with
/// Metal Performance Shaders Graph. Only the official weights file is downloaded (never code), on request,
/// into LiveWallpaper's own folder — so it can be deleted any time.
enum RealESRGAN {
    static let name = "Real-ESRGAN"
    static let downloadURL = URL(string: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth")!
    static let downloadSize: Int64 = 4_885_111
    /// Pinned so a tampered or truncated download is rejected.
    private static let sha256 = "8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292"

    static let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "LiveWallpaper/Models/realesr-general-x4v3.pth")
    }()

    static var isDownloaded: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    static var sizeOnDisk: Int64? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
    }

    /// Downloads and verifies the weights. `progress` gets 0…1.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw failure("The download server answered with an error.") }
        var data = Data()
        data.reserveCapacity(Int(downloadSize))
        for try await byte in bytes {
            data.append(byte)
            if data.count % 262_144 == 0 { progress(Double(data.count) / Double(downloadSize)) }
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw failure("The downloaded model didn't match the official file, so it wasn't used.") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    static func delete() throws {
        guard isDownloaded else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    static func failure(_ text: String) -> Error {
        CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: text])
    }

    // MARK: Weights

    /// Layer `i` of SRVGGNetCompact: conv weight/bias, then PReLU slope (absent for the last conv).
    struct Layer { let weight: [Float]; let outChannels: Int; let inChannels: Int; let bias: [Float]; let slope: [Float]? }

    /// Reads the 34 conv + 33 PReLU tensors. The file is hash-verified, so tensors are taken in their
    /// known storage order (conv w, conv b, prelu) and every size is still checked.
    static func loadLayers() throws -> [Layer] {
        let archive = try StoredZip(url: fileURL)
        func floats(_ key: Int, count: Int) throws -> [Float] {
            guard let data = archive.entry(suffix: "/data/\(key)"), data.count == count * 4 else {
                throw failure("The model file is incomplete. Delete it in Settings and upscale again to re-download.")
            }
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        var layers: [Layer] = []
        var key = 0
        for index in 0..<34 {
            let (inC, outC) = index == 0 ? (3, 64) : index == 33 ? (64, 48) : (64, 64)
            let weight = try floats(key, count: outC * inC * 9)
            let bias = try floats(key + 1, count: outC)
            let slope = index < 33 ? try floats(key + 2, count: outC) : nil
            key += index < 33 ? 3 : 2
            layers.append(Layer(weight: weight, outChannels: outC, inChannels: inC, bias: bias, slope: slope))
        }
        return layers
    }

    // MARK: Network

    /// SRVGGNetCompact ×4: conv+PReLU stack → pixel shuffle, added to a nearest-neighbour upscale of the input.
    final class Network {
        let width: Int, height: Int
        private let device: MTLDevice
        private let queue: MTLCommandQueue
        private let graph: MPSGraph
        private let input: MPSGraphTensor
        private let output: MPSGraphTensor
        private let inputBuffer: MTLBuffer

        init(layers: [Layer], width: Int, height: Int) throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let buffer = device.makeBuffer(length: width * height * 3 * 4, options: .storageModeShared)
            else { throw RealESRGAN.failure("Metal isn't available on this Mac.") }
            self.device = device
            self.queue = queue
            self.width = width
            self.height = height
            inputBuffer = buffer
            let graph = MPSGraph()
            self.graph = graph

            let input = graph.placeholder(shape: [1, height, width, 3] as [NSNumber], dataType: .float32, name: "input")
            let conv = MPSGraphConvolution2DOpDescriptor(
                strideInX: 1, strideInY: 1, dilationRateInX: 1, dilationRateInY: 1, groups: 1,
                paddingLeft: 1, paddingRight: 1, paddingTop: 1, paddingBottom: 1,
                paddingStyle: .explicit, dataLayout: .NHWC, weightsLayout: .OIHW)!
            func constant(_ values: [Float], _ shape: [Int]) -> MPSGraphTensor {
                graph.constant(values.withUnsafeBufferPointer { Data(buffer: $0) }, shape: shape as [NSNumber], dataType: .float32)
            }
            var x = input
            for layer in layers {
                let weights = constant(layer.weight, [layer.outChannels, layer.inChannels, 3, 3])
                x = graph.convolution2D(x, weights: weights, descriptor: conv, name: nil)
                x = graph.addition(x, constant(layer.bias, [1, 1, 1, layer.outChannels]), name: nil)
                if let slope = layer.slope {
                    let zero = graph.constant(0, dataType: .float32)
                    let positive = graph.maximum(x, zero, name: nil)
                    let negative = graph.multiplication(graph.minimum(x, zero, name: nil), constant(slope, [1, 1, 1, layer.outChannels]), name: nil)
                    x = graph.addition(positive, negative, name: nil)
                }
            }
            let shuffled = graph.depth(toSpace2DTensor: x, widthAxis: 2, heightAxis: 1, depthAxis: 3, blockSize: 4, usePixelShuffleOrder: true, name: nil)
            let base = graph.resize(input, size: [height * 4, width * 4] as [NSNumber], mode: .nearest,
                                    centerResult: true, alignCorners: false, layout: .NHWC, name: nil)
            self.input = input
            output = graph.clamp(graph.addition(shuffled, base, name: nil),
                                 min: graph.constant(0, dataType: .float32), max: graph.constant(1, dataType: .float32), name: nil)
        }

        /// Upscales one BGRA frame 4× into `destination` (BGRA, 4× the size).
        func upscale(_ frame: CVPixelBuffer, into destination: CVPixelBuffer) throws {
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            guard let src = CVPixelBufferGetBaseAddress(frame)?.assumingMemoryBound(to: UInt8.self) else { throw RealESRGAN.failure("Couldn't read a frame.") }
            let srcStride = CVPixelBufferGetBytesPerRow(frame)
            let rgb = inputBuffer.contents().assumingMemoryBound(to: Float.self)
            for y in 0..<height {
                let row = src + y * srcStride
                for x in 0..<width {
                    let o = (y * width + x) * 3
                    rgb[o] = Float(row[x * 4 + 2]) / 255
                    rgb[o + 1] = Float(row[x * 4 + 1]) / 255
                    rgb[o + 2] = Float(row[x * 4]) / 255
                }
            }
            let feed = MPSGraphTensorData(inputBuffer, shape: [1, height, width, 3] as [NSNumber], dataType: .float32)
            let result = graph.run(with: queue, feeds: [input: feed], targetTensors: [output], targetOperations: nil)
            guard let out = result[output] else { throw RealESRGAN.failure("The upscaler produced no output.") }

            let outWidth = width * 4, outHeight = height * 4
            var pixels = [Float](repeating: 0, count: outWidth * outHeight * 3)
            pixels.withUnsafeMutableBytes { out.mpsndarray().readBytes($0.baseAddress!, strideBytes: nil) }

            CVPixelBufferLockBaseAddress(destination, [])
            defer { CVPixelBufferUnlockBaseAddress(destination, []) }
            guard let dst = CVPixelBufferGetBaseAddress(destination)?.assumingMemoryBound(to: UInt8.self) else { throw RealESRGAN.failure("Out of memory.") }
            let dstStride = CVPixelBufferGetBytesPerRow(destination)
            for y in 0..<outHeight {
                let row = dst + y * dstStride
                for x in 0..<outWidth {
                    let o = (y * outWidth + x) * 3
                    row[x * 4] = UInt8(pixels[o + 2] * 255 + 0.5)
                    row[x * 4 + 1] = UInt8(pixels[o + 1] * 255 + 0.5)
                    row[x * 4 + 2] = UInt8(pixels[o] * 255 + 0.5)
                    row[x * 4 + 3] = 255
                }
            }
        }
    }
}

/// Minimal reader for uncompressed ("stored") zip archives, which is how PyTorch saves weights.
private struct StoredZip {
    private let data: Data
    private var entries: [String: Range<Int>] = [:]

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // End of central directory record, searched from the end.
        guard let end = stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1)
            .first(where: { u32($0) == 0x0605_4b50 }) else { throw RealESRGAN.failure("The model file isn't a valid archive.") }
        var offset = u32(end + 16)
        for _ in 0..<u16(end + 10) {
            guard u32(offset) == 0x0201_4b50 else { break }
            let method = u16(offset + 10), size = u32(offset + 20)
            let nameLength = u16(offset + 28), extraLength = u16(offset + 30), commentLength = u16(offset + 32)
            let local = u32(offset + 42)
            let name = String(decoding: data[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            if method == 0, u32(local) == 0x0403_4b50 {
                let start = local + 30 + u16(local + 26) + u16(local + 28)
                entries[name] = start..<(start + size)
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    func entry(suffix: String) -> Data? {
        entries.first { $0.key.hasSuffix(suffix) }.map { data.subdata(in: $0.value) }
    }
}
