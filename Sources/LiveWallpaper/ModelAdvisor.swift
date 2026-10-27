import Foundation
import Metal

/// Per-Mac advice for each upscaler: memory it needs, whether it can run here and why not,
/// and which one to use given the chip and RAM.
enum ModelAdvisor {
    enum Availability: Equatable {
        case ready
        /// Fits in RAM but not in what's free right now (or macOS is already swapping) — closing apps would help.
        case needsFreeMemory(needed: Int64, available: Int64, swapped: Int64)
        /// Can't run on this Mac, with a plain reason.
        case unavailable(String)

        var canRun: Bool { if case .unavailable = self { false } else { true } }
    }

    /// A typical wallpaper source, used when no specific video is selected.
    static let typicalInput = CGSize(width: 1920, height: 1080)
    private static let hasMetal = MTLCreateSystemDefaultDevice() != nil

    /// Approximate peak memory for upscaling one `input`-sized frame (bytes).
    /// Real-ESRGAN runs in tiles, so it's mostly a fixed cost plus the enlarged output frame
    /// (measured on an M5: 1.2 GB for Small/Medium and 1.8 GB for Large 4× at 1080p).
    static func estimatedMemory(_ engine: Upscaler.Engine, input: CGSize) -> Int64 {
        let pixels = Int64(input.width * input.height)
        if let model = engine.esrgan {
            let frames = pixels * Int64(model.scale * model.scale) * 4 + pixels * 6
            let fixed: Int64 = switch engine {
            case .realESRGANLarge: 1_600_000_000
            case .realESRGANLarge2x: 700_000_000
            default: 1_000_000_000
            }
            let tileFactor: Double = switch UpscaleSettings.snapshot().tile {
            case .auto: 1
            case .small: 0.6
            case .large: 2.2
            }
            return Int64(Double(fixed) * tileFactor) + frames + 250_000_000
        }
        switch engine {
        // Apple's network keeps 4× BGRA frames for temporal consistency plus its model.
        case .appleSuperResolution: return pixels * 16 * 4 * 3 + 450_000_000
        // Lanczos only needs the output frame.
        default: return pixels * 16 * 4 + 150_000_000
        }
    }

    /// Rough seconds per frame for `input` on this Mac, from timings on an M5 (10 GPU cores),
    /// scaled by GPU cores. nil for engines that don't depend on the GPU this way.
    static func secondsPerFrame(_ engine: Upscaler.Engine, input: CGSize) -> Double? {
        let perMegapixel: Double
        switch engine {
        case .realESRGANSmall: perMegapixel = 0.26
        case .realESRGAN: perMegapixel = 0.35
        case .realESRGANLarge2x: perMegapixel = 1.1
        case .realESRGANLarge: perMegapixel = 5.1
        default: return nil
        }
        let speed = Double(SystemInfo.gpuCores ?? 8) / 10
        let precision = UpscaleSettings.snapshot().fullPrecision ? 1.6 : 1
        return input.width * input.height / 1_000_000 * perMegapixel * precision / speed
    }

    /// "Fastest" … "Slowest", for the model list.
    static func speedLabel(_ engine: Upscaler.Engine) -> String {
        switch engine {
        case .basic: "Instant"
        case .realESRGANSmall: "Fastest ML"
        case .appleSuperResolution, .realESRGAN: "Fast"
        case .realESRGANLarge2x: "Slow"
        case .realESRGANLarge: "Slowest, sharpest"
        }
    }

    /// Model download size, if it has one.
    static func downloadSize(_ engine: Upscaler.Engine) -> Int64? {
        if let model = engine.esrgan { return model.downloadSize }
        return engine == .appleSuperResolution ? 72_000_000 : nil // Apple's is reported by macOS once installed; ~70 MB
    }

    static func availability(_ engine: Upscaler.Engine, input: CGSize = typicalInput) -> Availability {
        switch engine {
        case .realESRGANSmall, .realESRGAN, .realESRGANLarge2x, .realESRGANLarge:
            guard hasMetal else { return .unavailable("Needs a Metal-capable GPU, which this Mac doesn't have.") }
            if let model = engine.esrgan, !Upscaler.fits(input, model) {
                return .unavailable("Handles videos up to \(Int(model.maxInput.width))×\(Int(model.maxInput.height)); this one is \(Int(input.width))×\(Int(input.height)). It's already sharp enough for most displays.")
            }
        case .appleSuperResolution:
            guard SystemInfo.isAppleSilicon else { return .unavailable("Needs an Apple silicon Mac (M1 or later); this Mac has \(SystemInfo.chip).") }
            guard #available(macOS 26.0, *) else { return .unavailable("Needs macOS 26 or later.") }
            guard Upscaler.superResolutionSupported(for: input) else {
                return .unavailable("macOS doesn't support \(Int(input.width))×\(Int(input.height)) input for Super Resolution.")
            }
        case .basic:
            return .ready
        }
        let needed = estimatedMemory(engine, input: input)
        // Leave room for macOS and the apps you're using.
        if Double(needed) > Double(SystemInfo.totalMemory) * 0.6 {
            return .unavailable("Needs about \(SystemInfo.bytes(needed)) of RAM, more than this Mac's \(SystemInfo.bytes(SystemInfo.totalMemory)) can spare.")
        }
        let available = SystemInfo.availableMemory()
        // macOS keeps some memory looking free by swapping other apps to disk, so its pressure level counts too.
        if needed > available || (engine != .basic && SystemInfo.memoryPressure() >= 2) {
            return .needsFreeMemory(needed: needed, available: available, swapped: SystemInfo.swapUsed())
        }
        return .ready
    }

    /// The best choice for this Mac's chip, GPU and memory, with the reason: bigger Macs get bigger models.
    static func recommendation(input: CGSize = typicalInput) -> (engine: Upscaler.Engine, reason: String) {
        let ram = SystemInfo.bytes(SystemInfo.totalMemory)
        let gb = SystemInfo.totalMemory >> 30
        let cores = SystemInfo.gpuCores ?? 0
        let mac = "\(SystemInfo.chip)\(cores > 0 ? " (\(cores)-core GPU)" : "") with \(ram)"
        if !SystemInfo.isAppleSilicon {
            return (.basic, "Your \(SystemInfo.chip) has no Apple GPU or Neural Engine, so ML upscaling would be very slow — Basic is quickest.")
        }
        // Largest model first; each must run here and suit this Mac's power.
        let ladder: [(Upscaler.Engine, Bool, String)] = [
            (.realESRGANLarge, gb >= 32 && cores >= 16, "Your \(mac) is powerful enough for the sharpest model."),
            (.realESRGANLarge2x, gb >= 24 && cores >= 14, "Your \(mac) can run the full-size network; at 2× it's the best fit for videos that are only a little too small."),
            (.realESRGAN, gb >= 16, "It runs comfortably on your \(mac) — sharp results at a good speed."),
            (.realESRGANSmall, gb >= 8, "The lightest ML model suits your \(mac); it's fastest and easiest on memory."),
            (.appleSuperResolution, true, "With \(ram), Apple Super Resolution is the lightest ML choice."),
        ]
        let pressured = SystemInfo.memoryPressure() >= 2
        for (engine, suits, reason) in ladder where suits && availability(engine, input: input).canRun {
            return (engine, pressured ? reason + " macOS is short on memory right now, so free up memory first (Memory section)." : reason)
        }
        return (.basic, "The ML upscalers can't run for this video right now, so Basic is used — free up memory or try a smaller model.")
    }
}
