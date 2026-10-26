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
    static func estimatedMemory(_ engine: Upscaler.Engine, input: CGSize) -> Int64 {
        let pixels = Int64(input.width * input.height)
        switch engine {
        // 64-channel float feature maps (a few alive at once) + the 4× RGB output, plus the model and runtime.
        case .realESRGAN: return pixels * 64 * 4 * 3 + pixels * 16 * 3 * 4 * 2 + 350_000_000
        // Apple's network keeps 4× BGRA frames for temporal consistency plus its model.
        case .appleSuperResolution: return pixels * 16 * 4 * 3 + 450_000_000
        // Lanczos only needs the output frame.
        case .basic: return pixels * 16 * 4 + 150_000_000
        }
    }

    /// Model download size, if it has one.
    static func downloadSize(_ engine: Upscaler.Engine) -> Int64? {
        switch engine {
        case .realESRGAN: RealESRGAN.downloadSize
        case .appleSuperResolution: 72_000_000 // reported by macOS once installed; ~70 MB
        case .basic: nil
        }
    }

    static func availability(_ engine: Upscaler.Engine, input: CGSize = typicalInput) -> Availability {
        switch engine {
        case .realESRGAN:
            guard hasMetal else { return .unavailable("Needs a Metal-capable GPU, which this Mac doesn't have.") }
            guard max(input.width, input.height) <= 1920, min(input.width, input.height) <= 1080 else {
                return .unavailable("Handles videos up to 1920×1080; this one is \(Int(input.width))×\(Int(input.height)). It's already sharp enough for most displays.")
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

    /// The best choice for this Mac's chip and memory, with the reason.
    static func recommendation(input: CGSize = typicalInput) -> (engine: Upscaler.Engine, reason: String) {
        let ram = SystemInfo.bytes(SystemInfo.totalMemory)
        if !SystemInfo.isAppleSilicon {
            return (.basic, "Your \(SystemInfo.chip) has no Neural Engine, so ML upscaling would be very slow — Basic is quickest.")
        }
        let esrgan = availability(.realESRGAN, input: input)
        let apple = availability(.appleSuperResolution, input: input)
        if SystemInfo.memoryPressure() >= 2, esrgan.canRun {
            return (.realESRGAN, "It's the best fit for your \(ram), but macOS is short on memory right now — free up memory first (Memory tab).")
        }
        if SystemInfo.totalMemory >= 16 << 30, esrgan.canRun {
            return (.realESRGAN, "It runs comfortably with \(ram) — the sharpest results, and you can delete its model.")
        }
        if apple.canRun {
            return (.appleSuperResolution, "With \(ram), Apple Super Resolution is the lighter choice — it uses less memory than Real-ESRGAN.")
        }
        if esrgan.canRun {
            return (.realESRGAN, "It fits in \(ram); close other apps first for large videos.")
        }
        if case .unavailable(let reason) = esrgan, case .unavailable = apple {
            return (.basic, "Neither ML upscaler can run for this video (Real-ESRGAN: \(reason)), so Basic is used.")
        }
        return (.basic, "The ML upscalers need more free memory than is available right now, so Basic is used — or free up memory and use Real-ESRGAN.")
    }
}
