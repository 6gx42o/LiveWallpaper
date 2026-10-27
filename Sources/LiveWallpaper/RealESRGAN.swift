import CoreVideo
import CryptoKit
import Foundation
import Metal
import MetalPerformanceShadersGraph

/// The downloadable upscaling networks — Real-ESRGAN (BSD-3, © Xintao Wang) and SwinIR (Apache-2.0,
/// © Jingyun Liang) — run on the GPU with Metal Performance Shaders Graph.
/// Only the official weights files are downloaded (never code), on request, into LiveWallpaper's own
/// folder — so they can be deleted any time.
enum RealESRGAN {
    /// One downloadable network.
    struct Model: Hashable, Sendable {
        enum Architecture: Hashable, Sendable { case compact, rrdb, swinIR }
        let file: String
        let url: URL
        let downloadSize: Int64
        /// Pinned so a tampered or truncated download is rejected.
        let sha256: String
        let architecture: Architecture
        /// How much the network enlarges each side.
        let scale: Int
        /// Largest source it takes (longest side × shortest side).
        let maxInput: CGSize
        /// 2 = self-ensemble: also run a mirrored copy of each tile and average the two (same weights).
        var passes = 1

        var fileURL: URL { RealESRGAN.modelsDir.appending(path: file) }
        var isDownloaded: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
        var sizeOnDisk: Int64? {
            (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
        }
    }

    /// 16-layer compact network trained for animation; the fastest and lightest.
    static let small = Model(
        file: "realesr-animevideov3.pth",
        url: URL(string: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth")!,
        downloadSize: 2_504_012, sha256: "b8a8376811077954d82ca3fcf476f1ac3da3e8a68a4f4d71363008000a18b75d",
        architecture: .compact, scale: 4, maxInput: CGSize(width: 1920, height: 1080))
    /// 32-layer compact network for real-world video.
    static let medium = Model(
        file: "realesr-general-x4v3.pth",
        url: URL(string: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth")!,
        downloadSize: 4_885_111, sha256: "8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292",
        architecture: .compact, scale: 4, maxInput: CGSize(width: 1920, height: 1080))
    /// The full 23-block RRDB network at 2×: best detail for videos that are only a little too small.
    static let large2x = Model(
        file: "RealESRGAN_x2plus.pth",
        url: URL(string: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth")!,
        downloadSize: 67_061_725, sha256: "49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb",
        architecture: .rrdb, scale: 2, maxInput: CGSize(width: 2560, height: 1600))
    /// The full 23-block RRDB network at 4×: the sharpest, and by far the slowest.
    static let large = Model(
        file: "RealESRGAN_x4plus.pth",
        url: URL(string: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth")!,
        downloadSize: 67_040_989, sha256: "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1",
        architecture: .rrdb, scale: 4, maxInput: CGSize(width: 1920, height: 1080))

    /// A 6-block RRDB network trained on anime; sharp line art at a fraction of Large's cost.
    static let anime = Model(
        file: "RealESRGAN_x4plus_anime_6B.pth",
        url: URL(string: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth")!,
        downloadSize: 17_938_799, sha256: "f872d837d3c90ed2e05227bed711af5671a6fd1c9f7d7e91c911a61f155e99da",
        architecture: .rrdb, scale: 4, maxInput: CGSize(width: 1920, height: 1080))
    /// Large 4×'s network trained for fidelity instead of crispness: fewer invented details, a little softer.
    static let largeSmooth = Model(
        file: "RealESRNet_x4plus.pth",
        url: URL(string: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.1/RealESRNet_x4plus.pth")!,
        downloadSize: 67_040_989, sha256: "a820b9bde89a874d7599d545567308ce6c128fc8754a53208eda016d40aa81df",
        architecture: .rrdb, scale: 4, maxInput: CGSize(width: 1920, height: 1080))
    /// SwinIR-M (Apache-2.0, © Jingyun Liang): a 12-million-parameter Swin transformer for real-world video, 2×.
    static let swinMedium2x = Model(
        file: "003_realSR_BSRGAN_DFO_s64w8_SwinIR-M_x2_GAN.pth",
        url: URL(string: "https://github.com/JingyunLiang/SwinIR/releases/download/v0.0/003_realSR_BSRGAN_DFO_s64w8_SwinIR-M_x2_GAN.pth")!,
        downloadSize: 66_974_517, sha256: "f397408977a3e07eb06afb7238d453a12ef35ebab7328a54241f307860dbe342",
        architecture: .swinIR, scale: 2, maxInput: CGSize(width: 2560, height: 1600))
    /// SwinIR-M at 4×.
    static let swinMedium = Model(
        file: "003_realSR_BSRGAN_DFO_s64w8_SwinIR-M_x4_GAN.pth",
        url: URL(string: "https://github.com/JingyunLiang/SwinIR/releases/download/v0.0/003_realSR_BSRGAN_DFO_s64w8_SwinIR-M_x4_GAN.pth")!,
        downloadSize: 67_129_861, sha256: "b9afb61e65e04eb7f8aba5095d070bbe9af28df76acd0c9405aeb33b814bcfc6",
        architecture: .swinIR, scale: 4, maxInput: CGSize(width: 1920, height: 1080))
    /// SwinIR-L: the largest, a 28-million-parameter Swin transformer at 4×, for the biggest Macs.
    static let swinLarge = Model(
        file: "003_realSR_BSRGAN_DFOWMFC_s64w8_SwinIR-L_x4_GAN.pth",
        url: URL(string: "https://github.com/JingyunLiang/SwinIR/releases/download/v0.0/003_realSR_BSRGAN_DFOWMFC_s64w8_SwinIR-L_x4_GAN.pth")!,
        downloadSize: 142_473_939, sha256: "99adfa91350a84c99e946c1eb3d8fce34bc28f57d807b09dc8fe40a316328c0a",
        architecture: .swinIR, scale: 4, maxInput: CGSize(width: 1920, height: 1080))

    /// SwinIR-L trained for faithfulness (PSNR) instead of crispness: the same size, fewer invented details.
    static let swinLargeSmooth = Model(
        file: "003_realSR_BSRGAN_DFOWMFC_s64w8_SwinIR-L_x4_PSNR.pth",
        url: URL(string: "https://github.com/JingyunLiang/SwinIR/releases/download/v0.0/003_realSR_BSRGAN_DFOWMFC_s64w8_SwinIR-L_x4_PSNR.pth")!,
        downloadSize: 142_473_947, sha256: "450be6eac63a59959b55a83df6743444de9f018547f81d16f699b3680d366ad7",
        architecture: .swinIR, scale: 4, maxInput: CGSize(width: 1920, height: 1080))

    /// SwinIR Large run twice per tile (as is and mirrored) and averaged: steadier detail and fewer GAN
    /// artefacts, for twice the time and memory. Uses SwinIR Large's own weights file.
    static let swinLargeEnsemble: Model = {
        var model = swinLarge
        model.passes = 2
        return model
    }()

    static let modelsDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "LiveWallpaper/Models", directoryHint: .isDirectory)
    }()

    /// Downloads and verifies a model's weights. `progress` gets (bytes received, total bytes).
    static func download(_ model: Model, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let file = try await WebImport.download(model.url) { received, total in progress(received, total ?? model.downloadSize) }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        guard try sha256(of: file) == model.sha256 else {
            throw failure("The downloaded model didn't match the official file, so it wasn't used.")
        }
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: model.fileURL)
        try FileManager.default.moveItem(at: file, to: model.fileURL)
    }

    static func delete(_ model: Model) throws {
        guard model.isDownloaded else { return }
        try FileManager.default.removeItem(at: model.fileURL)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func failure(_ text: String) -> Error {
        CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: text])
    }

    // MARK: Weights

    /// Every named tensor in a downloaded model, as float32 values with their shape.
    static func loadWeights(_ model: Model) throws -> [String: (shape: [Int], values: [Float])] {
        let archive = try StoredZip(url: model.fileURL)
        guard let pickle = archive.entry(suffix: "/data.pkl") else { throw incomplete }
        var weights: [String: (shape: [Int], values: [Float])] = [:]
        for (name, tensor) in try TorchPickle.tensors(pickle) where tensor.isFloat {
            let count = tensor.shape.reduce(1, *)
            guard let data = archive.entry(suffix: "/data/\(tensor.storage)"),
                  data.count >= (tensor.offset + count) * 4 else { throw incomplete }
            let values: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)[tensor.offset..<(tensor.offset + count)]) }
            weights[name] = (tensor.shape, values)
        }
        return weights
    }

    private static var incomplete: Error {
        failure("The model file is incomplete. Delete it in Settings and upscale again to re-download.")
    }

    // MARK: Network

    /// Runs a model on BGRA frames, tile by tile so memory stays bounded whatever the frame size.
    final class Network {
        let width: Int, height: Int, scale: Int
        private let queue: MTLCommandQueue
        private let graph: MPSGraph
        private let input: MPSGraphTensor
        private let output: MPSGraphTensor
        private let inputBuffer: MTLBuffer
        /// Tile size fed to the network (whole frame when it fits) and the overlap kept on each side.
        private let tileWidth: Int, tileHeight: Int, overlap: Int
        private let dataType: MPSDataType
        private var rgb: [Float]
        private var tileOut: [Float]

        /// `tile` is the largest tile side in source pixels; `fullPrecision` trades speed for float32 maths.
        init(model: Model, width: Int, height: Int, tile: Int, fullPrecision: Bool) throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
            else { throw RealESRGAN.failure("Metal isn't available on this Mac.") }
            let weights = try RealESRGAN.loadWeights(model)
            self.queue = queue
            self.width = width
            self.height = height
            scale = model.scale
            // Even sides (the 2× models fold pixels in pairs), multiples of 8 for SwinIR's attention windows;
            // the whole frame if it fits in one tile.
            // SwinIR's attention sees further than the convolutional networks, so it keeps more context per side.
            let align = model.architecture == .swinIR ? 8 : 2, context = model.architecture == .swinIR ? 32 : 16
            tileWidth = min(width, tile + 2 * context) / align * align
            tileHeight = min(height, tile + 2 * context) / align * align
            overlap = min(context, min(tileWidth, tileHeight) / 4)
            dataType = fullPrecision ? .float32 : .float16
            // Frames travel as 32-bit floats (Swift has no Float16 on Intel); the graph casts to half precision itself.
            guard let buffer = device.makeBuffer(length: tileWidth * tileHeight * 3 * 4, options: .storageModeShared)
            else { throw RealESRGAN.failure("Out of GPU memory.") }
            inputBuffer = buffer
            rgb = [Float](repeating: 0, count: width * height * 3)
            tileOut = [Float](repeating: 0, count: tileWidth * tileHeight * scale * scale * 3)

            let graph = MPSGraph()
            self.graph = graph
            input = graph.placeholder(shape: [1, tileHeight, tileWidth, 3] as [NSNumber], dataType: .float32, name: "input")
            let builder = Builder(graph: graph, weights: weights, dataType: dataType)
            let x = fullPrecision ? input : graph.cast(input, to: .float16, name: "in16")
            let (th, tw) = (tileHeight, tileWidth)
            func network(_ input: MPSGraphTensor) throws -> MPSGraphTensor {
                switch model.architecture {
                case .compact: try builder.compact(input)
                case .rrdb: try builder.rrdb(input, scale: model.scale)
                case .swinIR: try builder.swinIR(input, scale: model.scale, height: th, width: tw)
                }
            }
            var y = try network(x)
            if model.passes == 2 {
                // Self-ensemble: the left-right mirror of the tile, upscaled and mirrored back, averaged in.
                let mirrored = graph.reverse(try network(graph.reverse(x, axes: [2], name: nil)), axes: [2], name: nil)
                y = graph.multiplication(graph.addition(y, mirrored, name: nil), builder.scalar(0.5), name: nil)
            }
            y = graph.clamp(y, min: builder.scalar(0), max: builder.scalar(1), name: nil)
            output = fullPrecision ? y : graph.cast(y, to: .float32, name: "out32")
        }

        /// Upscales one BGRA frame by `scale` into `destination` (BGRA, `scale`× the size).
        func upscale(_ frame: CVPixelBuffer, into destination: CVPixelBuffer) throws {
            try readFrame(frame)
            CVPixelBufferLockBaseAddress(destination, [])
            defer { CVPixelBufferUnlockBaseAddress(destination, []) }
            guard let dst = CVPixelBufferGetBaseAddress(destination)?.assumingMemoryBound(to: UInt8.self) else {
                throw RealESRGAN.failure("Out of memory.")
            }
            let dstStride = CVPixelBufferGetBytesPerRow(destination)
            for y0 in Self.starts(length: height, tile: tileHeight, overlap: overlap) {
                for x0 in Self.starts(length: width, tile: tileWidth, overlap: overlap) {
                    try run(x0: x0, y0: y0)
                    // Keep the tile's centre; its overlap is only context (edges of the frame are kept).
                    let left = x0 == 0 ? 0 : overlap, right = x0 + tileWidth == width ? 0 : overlap
                    let top = y0 == 0 ? 0 : overlap, bottom = y0 + tileHeight == height ? 0 : overlap
                    let outW = tileWidth * scale
                    for ty in (top * scale)..<((tileHeight - bottom) * scale) {
                        let row = dst + (y0 * scale + ty) * dstStride
                        for tx in (left * scale)..<((tileWidth - right) * scale) {
                            let o = (ty * outW + tx) * 3
                            let p = (x0 * scale + tx) * 4
                            row[p] = Self.byte(tileOut[o + 2])
                            row[p + 1] = Self.byte(tileOut[o + 1])
                            row[p + 2] = Self.byte(tileOut[o])
                            row[p + 3] = 255
                        }
                    }
                }
            }
        }

        /// Tile origins along one side: steps that overlap by `2 × overlap`, the last one flush with the end.
        static func starts(length: Int, tile: Int, overlap: Int) -> [Int] {
            guard length > tile else { return [0] }
            let step = tile - 2 * overlap
            return Array(stride(from: 0, to: length - tile, by: step)) + [length - tile]
        }

        private static func byte(_ value: Float) -> UInt8 { UInt8(value * 255 + 0.5) }

        private func readFrame(_ frame: CVPixelBuffer) throws {
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            guard let src = CVPixelBufferGetBaseAddress(frame)?.assumingMemoryBound(to: UInt8.self) else {
                throw RealESRGAN.failure("Couldn't read a frame.")
            }
            let stride = CVPixelBufferGetBytesPerRow(frame)
            for y in 0..<height {
                let row = src + y * stride
                for x in 0..<width {
                    let o = (y * width + x) * 3
                    rgb[o] = Float(row[x * 4 + 2]) / 255
                    rgb[o + 1] = Float(row[x * 4 + 1]) / 255
                    rgb[o + 2] = Float(row[x * 4]) / 255
                }
            }
        }

        private func run(x0: Int, y0: Int) throws {
            let tile = inputBuffer.contents().assumingMemoryBound(to: Float.self)
            rgb.withUnsafeBufferPointer { frame in
                for y in 0..<tileHeight {
                    (tile + y * tileWidth * 3).update(from: frame.baseAddress! + ((y0 + y) * width + x0) * 3, count: tileWidth * 3)
                }
            }
            let feed = MPSGraphTensorData(inputBuffer, shape: [1, tileHeight, tileWidth, 3] as [NSNumber], dataType: .float32)
            let result = graph.run(with: queue, feeds: [input: feed], targetTensors: [output], targetOperations: nil)
            guard let out = result[output] else { throw RealESRGAN.failure("The upscaler produced no output.") }
            tileOut.withUnsafeMutableBytes { out.mpsndarray().readBytes($0.baseAddress!, strideBytes: nil) }
        }
    }

    /// Builds the two Real-ESRGAN architectures from their PyTorch weight names.
    private struct Builder {
        let graph: MPSGraph
        let weights: [String: (shape: [Int], values: [Float])]
        let dataType: MPSDataType
        /// 3×3 convolutions pad by one pixel; 1×1 ones don't pad.
        private func descriptor(padding: Int) -> MPSGraphConvolution2DOpDescriptor {
            MPSGraphConvolution2DOpDescriptor(
                strideInX: 1, strideInY: 1, dilationRateInX: 1, dilationRateInY: 1, groups: 1,
                paddingLeft: padding, paddingRight: padding, paddingTop: padding, paddingBottom: padding,
                paddingStyle: .explicit, dataLayout: .NHWC, weightsLayout: .OIHW)!
        }

        init(graph: MPSGraph, weights: [String: (shape: [Int], values: [Float])], dataType: MPSDataType) {
            self.graph = graph
            self.weights = weights
            self.dataType = dataType
        }

        func scalar(_ value: Double) -> MPSGraphTensor { graph.constant(value, dataType: dataType) }

        private func constant(_ name: String, shape: [Int]? = nil, type: MPSDataType? = nil) throws -> MPSGraphTensor {
            guard let tensor = weights[name] else { throw RealESRGAN.incomplete }
            let data = tensor.values.withUnsafeBufferPointer { Data(buffer: $0) }
            let value = graph.constant(data, shape: (shape ?? tensor.shape) as [NSNumber], dataType: .float32)
            let target = type ?? dataType
            return target == .float32 ? value : graph.cast(value, to: target, name: name + ".half")
        }

        private func wide(_ x: MPSGraphTensor) -> MPSGraphTensor { dataType == .float32 ? x : graph.cast(x, to: .float32, name: "wide") }
        private func narrow(_ x: MPSGraphTensor) -> MPSGraphTensor { dataType == .float32 ? x : graph.cast(x, to: dataType, name: "narrow") }

        /// 3×3 or 1×1 convolution (PyTorch `name.weight` / `name.bias`), in `type` (default: the network's precision).
        private func conv(_ x: MPSGraphTensor, _ name: String, type: MPSDataType? = nil) throws -> MPSGraphTensor {
            let kernel = weights[name + ".weight"]?.shape.last ?? 3
            let y = graph.convolution2D(x, weights: try constant(name + ".weight", type: type), descriptor: descriptor(padding: kernel / 2), name: nil)
            let channels = weights[name + ".bias"]?.shape.first ?? 0
            return graph.addition(y, try constant(name + ".bias", shape: [1, 1, 1, channels], type: type), name: nil)
        }

        private func lrelu(_ x: MPSGraphTensor, _ slope: Double = 0.2) -> MPSGraphTensor { graph.leakyReLU(with: x, alpha: slope, name: nil) }

        private func up2(_ x: MPSGraphTensor) -> MPSGraphTensor {
            let shape = x.shape!.map(\.intValue)
            return graph.resize(x, size: [shape[1] * 2, shape[2] * 2] as [NSNumber], mode: .nearest,
                                centerResult: true, alignCorners: false, layout: .NHWC, name: nil)
        }

        /// SRVGGNetCompact ×4: conv+PReLU stack → pixel shuffle, added to a nearest-neighbour upscale of the input.
        func compact(_ input: MPSGraphTensor) throws -> MPSGraphTensor {
            var x = input
            var index = 0
            while let tensor = weights["body.\(index).weight"] {
                if tensor.shape.count == 4 {
                    x = try conv(x, "body.\(index)")
                } else {
                    let slope = try constant("body.\(index).weight", shape: [1, 1, 1, tensor.shape[0]])
                    let zero = scalar(0)
                    x = graph.addition(graph.maximum(x, zero, name: nil),
                                       graph.multiplication(graph.minimum(x, zero, name: nil), slope, name: nil), name: nil)
                }
                index += 1
            }
            guard index > 0 else { throw RealESRGAN.incomplete }
            let shuffled = graph.depth(toSpace2DTensor: x, widthAxis: 2, heightAxis: 1, depthAxis: 3, blockSize: 4, usePixelShuffleOrder: true, name: nil)
            return graph.addition(shuffled, up2(up2(input)), name: nil)
        }

        /// RRDBNet: 23 residual-in-residual dense blocks, then two 2× nearest upsamples with convs.
        /// The 2× model first folds 2×2 pixels into channels so the same 4× tail gives 2× overall.
        func rrdb(_ input: MPSGraphTensor, scale: Int) throws -> MPSGraphTensor {
            var x = input
            if scale == 2 {
                x = graph.space(toDepth2DTensor: x, widthAxis: 2, heightAxis: 1, depthAxis: 3, blockSize: 2, usePixelShuffleOrder: true, name: nil)
            }
            let feat = try conv(x, "conv_first")
            var body = feat
            var block = 0
            while weights["body.\(block).rdb1.conv1.weight"] != nil {
                let start = body
                for rdb in 1...3 { body = try dense(body, "body.\(block).rdb\(rdb)") }
                body = graph.addition(graph.multiplication(body, scalar(0.2), name: nil), start, name: nil)
                block += 1
            }
            guard block > 0 else { throw RealESRGAN.incomplete }
            var y = graph.addition(feat, try conv(body, "conv_body"), name: nil)
            y = lrelu(try conv(up2(y), "conv_up1"))
            y = lrelu(try conv(up2(y), "conv_up2"))
            return try conv(lrelu(try conv(y, "conv_hr")), "conv_last")
        }

        // MARK: SwinIR

        /// SwinIR for real-world SR ("nearest+conv"): conv → residual Swin transformer blocks (shifted 8×8 window
        /// attention) → conv, then the same nearest-neighbour upsampling tail as RRDBNet. `height`/`width` are the
        /// tile size (multiples of 8), which fixes the window layout and the shifted-window mask.
        func swinIR(_ input: MPSGraphTensor, scale: Int, height: Int, width: Int) throws -> MPSGraphTensor {
            let mean = graph.constant(Data([Float(0.4488), 0.4371, 0.4040].withUnsafeBufferPointer { Data(buffer: $0) }),
                                      shape: [1, 1, 1, 3], dataType: .float32)
            let meanTyped = dataType == .float32 ? mean : graph.cast(mean, to: dataType, name: "mean")
            let x = graph.subtraction(input, meanTyped, name: nil)
            guard let dim = weights["conv_first.weight"]?.shape.first else { throw RealESRGAN.incomplete }
            let first = try conv(x, "conv_first")

            // Transformer body works on tokens: [H·W, C]. Its residual stream stays in float32 (mixed precision):
            // SwinIR-M's last block reaches ~220,000, beyond half precision; the heavy maths still runs in half.
            let tokens = height * width
            var t = wide(try layerNorm(graph.reshape(first, shape: [tokens, dim] as [NSNumber], name: nil), "patch_embed.norm"))
            var layer = 0
            while weights["layers.\(layer).residual_group.blocks.0.norm1.weight"] != nil {
                let start = t
                var block = 0
                while weights["layers.\(layer).residual_group.blocks.\(block).norm1.weight"] != nil {
                    t = try swinBlock(t, "layers.\(layer).residual_group.blocks.\(block)", dim: dim, height: height, width: width,
                                      shift: block % 2 == 1 ? 4 : 0)
                    block += 1
                }
                // Residual Swin Transformer Block: a conv over the image, then back to tokens, plus the skip.
                let image = graph.reshape(t, shape: [1, height, width, dim] as [NSNumber], name: nil)
                let convolved = try residualConv(image, "layers.\(layer).conv", type: .float32)
                t = graph.addition(graph.reshape(convolved, shape: [tokens, dim] as [NSNumber], name: nil), start, name: nil)
                layer += 1
            }
            guard layer > 0 else { throw RealESRGAN.incomplete }
            t = try layerNorm(t, "norm")
            let body = graph.reshape(t, shape: [1, height, width, dim] as [NSNumber], name: nil)
            var y = graph.addition(try residualConv(body, "conv_after_body"), first, name: nil)

            y = lrelu(try conv(y, "conv_before_upsample.0"), 0.01) // PyTorch's default LeakyReLU slope here
            y = lrelu(try conv(up2(y), "conv_up1"))
            if scale == 4 { y = lrelu(try conv(up2(y), "conv_up2")) }
            y = try conv(lrelu(try conv(y, "conv_hr")), "conv_last")
            return graph.addition(y, meanTyped, name: nil)
        }

        /// "1conv" (one 3×3 conv) or "3conv" (3×3 → 1×1 → 3×3 with LeakyReLUs), whichever the weights contain.
        private func residualConv(_ x: MPSGraphTensor, _ name: String, type: MPSDataType? = nil) throws -> MPSGraphTensor {
            if weights[name + ".weight"] != nil { return try conv(x, name, type: type) }
            return try conv(lrelu(try conv(lrelu(try conv(x, name + ".0", type: type)), name + ".2", type: type)), name + ".4", type: type)
        }

        /// Always in float32: SwinIR's residual stream grows large enough that squaring it overflows half precision.
        private func layerNorm(_ x: MPSGraphTensor, _ name: String) throws -> MPSGraphTensor {
            let wide = dataType == .float32 ? x : graph.cast(x, to: .float32, name: "ln32")
            let mean = graph.mean(of: wide, axes: [-1], name: nil)
            let variance = graph.variance(of: wide, mean: mean, axes: [-1], name: nil)
            guard let gamma = weights[name + ".weight"], let beta = weights[name + ".bias"] else { throw RealESRGAN.incomplete }
            func f32(_ v: [Float]) -> MPSGraphTensor {
                graph.constant(v.withUnsafeBufferPointer { Data(buffer: $0) }, shape: [v.count as NSNumber], dataType: .float32)
            }
            let y = graph.normalize(wide, mean: mean, variance: variance, gamma: f32(gamma.values), beta: f32(beta.values), epsilon: 1e-5, name: nil)
            return dataType == .float32 ? y : graph.cast(y, to: dataType, name: "ln16")
        }

        /// y = x·Wᵀ + b for PyTorch `nn.Linear` weights.
        private func linear(_ x: MPSGraphTensor, _ name: String) throws -> MPSGraphTensor {
            let w = graph.transposeTensor(try constant(name + ".weight"), dimension: 0, withDimension: 1, name: nil)
            return graph.addition(graph.matrixMultiplication(primary: x, secondary: w, name: nil), try constant(name + ".bias"), name: nil)
        }

        private func gelu(_ x: MPSGraphTensor) -> MPSGraphTensor {
            let erf = graph.erf(with: graph.multiplication(x, scalar(1 / 2.0.squareRoot()), name: nil), name: nil)
            return graph.multiplication(graph.multiplication(x, scalar(0.5), name: nil), graph.addition(erf, scalar(1), name: nil), name: nil)
        }

        /// Rolls an [H, W, C] image by `shift` along height and width (like `torch.roll`).
        private func roll(_ x: MPSGraphTensor, _ shift: Int, height: Int, width: Int) -> MPSGraphTensor {
            var y = x
            for (axis, size) in [(0, height), (1, width)] {
                let s = ((shift % size) + size) % size
                guard s != 0 else { continue }
                let head = graph.sliceTensor(y, dimension: axis, start: size - s, length: s, name: nil)
                let tail = graph.sliceTensor(y, dimension: axis, start: 0, length: size - s, name: nil)
                y = graph.concatTensors([head, tail], dimension: axis, name: nil)
            }
            return y
        }

        /// One Swin transformer block: (shifted) 8×8 window attention and an MLP, each with a residual.
        private func swinBlock(_ x: MPSGraphTensor, _ name: String, dim: Int, height: Int, width: Int, shift: Int) throws -> MPSGraphTensor {
            let ws = 8, n = ws * ws, windows = (height / ws) * (width / ws)
            guard let table = weights[name + ".attn.relative_position_bias_table"] else { throw RealESRGAN.incomplete }
            let heads = table.shape[1], headDim = dim / heads

            var h = graph.reshape(try layerNorm(x, name + ".norm1"), shape: [height, width, dim] as [NSNumber], name: nil)
            if shift > 0 { h = roll(h, -shift, height: height, width: width) }
            // Partition into windows: [nW, 64, C].
            h = graph.reshape(h, shape: [height / ws, ws, width / ws, ws, dim] as [NSNumber], name: nil)
            h = graph.transpose(h, permutation: [0, 2, 1, 3, 4], name: nil)
            h = graph.reshape(h, shape: [windows, n, dim] as [NSNumber], name: nil)

            // Multi-head attention with the learned relative position bias (and the shifted-window mask).
            var qkv = graph.reshape(try linear(h, name + ".attn.qkv"), shape: [windows, n, 3, heads, headDim] as [NSNumber], name: nil)
            qkv = graph.transpose(qkv, permutation: [2, 0, 3, 1, 4], name: nil) // [3, nW, heads, 64, d]
            func part(_ i: Int) -> MPSGraphTensor {
                graph.reshape(graph.sliceTensor(qkv, dimension: 0, start: i, length: 1, name: nil),
                              shape: [windows, heads, n, headDim] as [NSNumber], name: nil)
            }
            let q = graph.multiplication(part(0), scalar(1 / Double(headDim).squareRoot()), name: nil)
            var attention = graph.matrixMultiplication(primary: q, secondary: graph.transposeTensor(part(1), dimension: 2, withDimension: 3, name: nil), name: nil)
            attention = graph.addition(attention, positionBias(table.values, heads: heads), name: nil)
            if shift > 0 { attention = graph.addition(attention, shiftMask(height: height, width: width, shift: shift), name: nil) }
            attention = graph.softMax(with: attention, axis: 3, name: nil)
            var out = graph.matrixMultiplication(primary: attention, secondary: part(2), name: nil) // [nW, heads, 64, d]
            out = graph.reshape(graph.transpose(out, permutation: [0, 2, 1, 3], name: nil), shape: [windows, n, dim] as [NSNumber], name: nil)
            out = try linear(out, name + ".attn.proj")

            // Merge windows back into the image and undo the shift.
            out = graph.reshape(out, shape: [height / ws, width / ws, ws, ws, dim] as [NSNumber], name: nil)
            out = graph.reshape(graph.transpose(out, permutation: [0, 2, 1, 3, 4], name: nil), shape: [height, width, dim] as [NSNumber], name: nil)
            if shift > 0 { out = roll(out, shift, height: height, width: width) }
            let attended = graph.addition(x, wide(graph.reshape(out, shape: [height * width, dim] as [NSNumber], name: nil)), name: nil)

            let mlp = try linear(gelu(try linear(try layerNorm(attended, name + ".norm2"), name + ".mlp.fc1")), name + ".mlp.fc2")
            return graph.addition(attended, wide(mlp), name: nil)
        }

        /// The [heads, 64, 64] bias looked up from the relative position table (same index as SwinIR's buffer).
        private func positionBias(_ table: [Float], heads: Int) -> MPSGraphTensor {
            var bias = [Float](repeating: 0, count: heads * 64 * 64)
            for i in 0..<64 {
                for j in 0..<64 {
                    let index = (i / 8 - j / 8 + 7) * 15 + (i % 8 - j % 8 + 7)
                    for head in 0..<heads { bias[(head * 64 + i) * 64 + j] = table[index * heads + head] }
                }
            }
            return typed(bias, shape: [heads, 64, 64])
        }

        /// -100 between tokens that came from different image regions after the cyclic shift, else 0: [nW, 1, 64, 64].
        private func shiftMask(height: Int, width: Int, shift: Int) -> MPSGraphTensor {
            func region(_ v: Int, _ size: Int) -> Int { v < size - 8 ? 0 : v < size - shift ? 1 : 2 }
            let columns = width / 8, windows = (height / 8) * columns
            var mask = [Float](repeating: 0, count: windows * 64 * 64)
            for w in 0..<windows {
                let ids = (0..<64).map { t in region((w / columns) * 8 + t / 8, height) * 3 + region((w % columns) * 8 + t % 8, width) }
                for i in 0..<64 { for j in 0..<64 where ids[i] != ids[j] { mask[(w * 64 + i) * 64 + j] = -100 } }
            }
            return typed(mask, shape: [windows, 1, 64, 64])
        }

        private func typed(_ values: [Float], shape: [Int]) -> MPSGraphTensor {
            let c = graph.constant(values.withUnsafeBufferPointer { Data(buffer: $0) }, shape: shape as [NSNumber], dataType: .float32)
            return dataType == .float32 ? c : graph.cast(c, to: dataType, name: "const")
        }

        /// Residual dense block: five convs, each seeing everything before it.
        private func dense(_ x: MPSGraphTensor, _ name: String) throws -> MPSGraphTensor {
            var features = [x]
            for i in 1...4 {
                let joined = features.count == 1 ? x : graph.concatTensors(features, dimension: 3, name: nil)
                features.append(lrelu(try conv(joined, "\(name).conv\(i)")))
            }
            let x5 = try conv(graph.concatTensors(features, dimension: 3, name: nil), "\(name).conv5")
            return graph.addition(graph.multiplication(x5, scalar(0.2), name: nil), x, name: nil)
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
        guard data.count >= 22, let end = stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1)
            .first(where: { u32($0) == 0x0605_4b50 }) else { throw RealESRGAN.failure("The model file isn't a valid archive.") }
        var offset = u32(end + 16)
        for _ in 0..<u16(end + 10) {
            guard offset + 46 <= data.count, u32(offset) == 0x0201_4b50 else { break }
            let method = u16(offset + 10), size = u32(offset + 20)
            let nameLength = u16(offset + 28), extraLength = u16(offset + 30), commentLength = u16(offset + 32)
            let local = u32(offset + 42)
            guard offset + 46 + nameLength <= data.count else { break }
            let name = String(decoding: data[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            if method == 0, local + 30 <= data.count, u32(local) == 0x0403_4b50 {
                let start = local + 30 + u16(local + 26) + u16(local + 28)
                if start + size <= data.count { entries[name] = start..<(start + size) }
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    func entry(suffix: String) -> Data? {
        entries.first { $0.key.hasSuffix(suffix) }.map { data.subdata(in: $0.value) }
    }
}

/// Reads the tensor index (name → storage, offset, shape) from PyTorch's `data.pkl`.
/// Only the handful of pickle opcodes PyTorch uses for a state dict are understood; nothing is executed —
/// the only "calls" recognised are rebuilding a tensor and creating an ordered dictionary.
enum TorchPickle {
    struct Tensor {
        let storage: String
        let offset: Int
        let shape: [Int]
        /// float32 weights; other storages (e.g. SwinIR's integer index tables) are skipped.
        var isFloat = true
    }

    private final class Dict { var items: [(Value, Value)] = [] }
    private enum Value {
        case none, int(Int), string(String), tuple([Value]), dict(Dict), global(String), storage(String, isFloat: Bool), tensor(Tensor), other
    }

    static func tensors(_ data: Data) throws -> [(String, Tensor)] {
        let bytes = [UInt8](data)
        var i = 0
        var stack: [Value] = [], marks: [Int] = [], memo: [Int: Value] = [:]
        func bad() -> Error { RealESRGAN.failure("The model file's index couldn't be read.") }
        func read(_ n: Int) throws -> ArraySlice<UInt8> {
            guard i + n <= bytes.count else { throw bad() }
            defer { i += n }
            return bytes[i..<(i + n)]
        }
        func uint(_ n: Int) throws -> Int { try read(n).reversed().reduce(0) { $0 << 8 | Int($1) } }
        func pop() throws -> Value { guard let v = stack.popLast() else { throw bad() }; return v }
        func popMark() throws -> [Value] {
            guard let mark = marks.popLast(), mark <= stack.count else { throw bad() }
            defer { stack.removeSubrange(mark...) }
            return Array(stack[mark...])
        }
        func line() throws -> String {
            guard let end = bytes[i...].firstIndex(of: 0x0a) else { throw bad() }
            defer { i = end + 1 }
            return String(decoding: bytes[i..<end], as: UTF8.self)
        }
        func setItems(_ pairs: [Value]) throws {
            guard case .dict(let dict) = stack.last, pairs.count.isMultiple(of: 2) else { throw bad() }
            for k in stride(from: 0, to: pairs.count, by: 2) { dict.items.append((pairs[k], pairs[k + 1])) }
        }

        loop: while i < bytes.count {
            let op = bytes[i]
            i += 1
            switch op {
            case 0x80: _ = try read(1) // PROTO
            case 0x95: _ = try read(8) // FRAME
            case 0x7d: stack.append(.dict(Dict())) // EMPTY_DICT
            case 0x5d, 0x29: stack.append(op == 0x29 ? .tuple([]) : .other) // EMPTY_LIST, EMPTY_TUPLE
            case 0x28: marks.append(stack.count) // MARK
            case 0x58: stack.append(.string(String(decoding: try read(try uint(4)), as: UTF8.self))) // BINUNICODE
            case 0x8c: stack.append(.string(String(decoding: try read(try uint(1)), as: UTF8.self))) // SHORT_BINUNICODE
            case 0x63: stack.append(.global(try line() + " " + (try line()))) // GLOBAL
            case 0x71: guard let top = stack.last else { throw bad() }; memo[try uint(1)] = top // BINPUT
            case 0x72: guard let top = stack.last else { throw bad() }; memo[try uint(4)] = top // LONG_BINPUT
            case 0x68: guard let v = memo[try uint(1)] else { throw bad() }; stack.append(v) // BINGET
            case 0x6a: guard let v = memo[try uint(4)] else { throw bad() }; stack.append(v) // LONG_BINGET
            case 0x4a: stack.append(.int(Int(Int32(truncatingIfNeeded: try uint(4))))) // BININT
            case 0x4b: stack.append(.int(try uint(1))) // BININT1
            case 0x4d: stack.append(.int(try uint(2))) // BININT2
            case 0x74: stack.append(.tuple(try popMark())) // TUPLE
            case 0x85, 0x86, 0x87: // TUPLE1-3
                let n = Int(op - 0x84)
                guard stack.count >= n else { throw bad() }
                stack.append(.tuple(Array(stack.suffix(n))))
                stack.removeSubrange((stack.count - n - 1)..<(stack.count - 1))
            case 0x88, 0x89, 0x4e: stack.append(op == 0x4e ? .none : .other) // NEWTRUE, NEWFALSE, NONE
            case 0x51: // BINPERSID: ('storage', type, key, location, size)
                guard case .tuple(let id) = try pop(), id.count > 2, case .string(let key) = id[2] else { throw bad() }
                let isFloat: Bool = if case .global("torch FloatStorage") = id[1] { true } else { false }
                stack.append(.storage(key, isFloat: isFloat))
            case 0x52: // REDUCE
                let args = try pop(), callable = try pop()
                switch (callable, args) {
                case (.global("torch._utils _rebuild_tensor_v2"), .tuple(let a)) where a.count >= 3:
                    guard case .storage(let key, let isFloat) = a[0], case .int(let offset) = a[1], case .tuple(let dims) = a[2] else { throw bad() }
                    let shape = try dims.map { dim -> Int in guard case .int(let n) = dim else { throw bad() }; return n }
                    stack.append(.tensor(Tensor(storage: key, offset: offset, shape: shape, isFloat: isFloat)))
                case (.global("collections OrderedDict"), _): stack.append(.dict(Dict()))
                default: stack.append(.other)
                }
            case 0x62: _ = try pop() // BUILD (sets metadata we don't need)
            case 0x73: let value = try pop(), key = try pop(); try setItems([key, value]) // SETITEM
            case 0x75: try setItems(try popMark()) // SETITEMS
            case 0x61: _ = try pop() // APPEND
            case 0x65: _ = try popMark() // APPENDS
            case 0x2e: break loop // STOP
            default: throw bad()
            }
        }
        // The weights are either the top-level dict or under "params_ema" / "params".
        guard case .dict(let top) = stack.last else { throw bad() }
        func tensors(in dict: Dict) -> [(String, Tensor)] {
            dict.items.compactMap { key, value in
                guard case .string(let name) = key, case .tensor(let tensor) = value else { return nil }
                return (name, tensor)
            }
        }
        for preferred in ["params_ema", "params"] {
            if let (_, value) = top.items.first(where: { if case .string(preferred) = $0.0 { true } else { false } }),
               case .dict(let inner) = value {
                return tensors(in: inner)
            }
        }
        return tensors(in: top)
    }
}
