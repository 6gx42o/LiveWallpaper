import Foundation
import Metal

/// Per-Mac advice for each upscaler: memory and time it needs, whether this Mac can handle it (and why not),
/// and three picks — fast, quality and the most this Mac can do — that scale with the Mac's GPU and memory.
enum ModelAdvisor {
    enum Availability: Equatable {
        case ready
        /// Fits in RAM but not in what's free right now (or macOS is already swapping) — closing apps would help.
        case needsFreeMemory(needed: Int64, available: Int64, swapped: Int64)
        /// Can't run on this Mac, with a plain reason.
        case unavailable(String)

        var canRun: Bool { if case .unavailable = self { false } else { true } }
    }

    /// The three per-Mac picks, each with why.
    struct Picks {
        /// The best quality that still upscales quickly here — a balance, not simply the fastest model.
        let speed: (engine: Upscaler.Engine, reason: String)
        /// The best quality that finishes in a reasonable time here.
        let quality: (engine: Upscaler.Engine, reason: String)
        /// The biggest model this Mac can run at all.
        let max: (engine: Upscaler.Engine, reason: String)
    }

    /// A typical wallpaper source, used when no specific video is selected.
    static let typicalInput = CGSize(width: 1920, height: 1080)
    private static let hasMetal = MTLCreateSystemDefaultDevice() != nil

    /// Time budgets per frame on this Mac: the speed pick, the quality pick, and beyond which a model is
    /// greyed out as too much for this Mac (a 30-second, 30 fps clip is 900 frames).
    static let speedBudget = 1.5, qualityBudget = 15.0, limit = 30.0

    /// Seconds per source megapixel on an M5 with a 10-core GPU (measured), peak memory at the default work
    /// size apart from the frames themselves (measured), and the least memory a Mac should have to run it
    /// alongside macOS and your apps (the transformers need room to work in bigger tiles).
    private static func cost(_ engine: Upscaler.Engine) -> (secondsPerMegapixel: Double, fixedMemory: Int64, minimumGB: Int64)? {
        switch engine {
        case .realESRGANSmall: (0.26, 1_000_000_000, 8)
        case .realESRGAN: (0.35, 1_000_000_000, 8)
        case .realESRGANAnime: (1.62, 1_000_000_000, 8)
        case .realESRGANLarge2x: (1.1, 700_000_000, 8)
        case .realESRGANLarge: (5.1, 1_600_000_000, 8)
        case .realESRNetLarge: (4.9, 1_600_000_000, 8)
        case .swinIRMedium2x: (14.5, 2_000_000_000, 16)
        case .swinIRMedium: (14.8, 2_400_000_000, 16)
        case .swinIRLarge: (29.5, 3_400_000_000, 32)
        case .appleSuperResolution, .basic: nil
        }
    }

    /// How good the result is, for general footage (Anime and Smooth are specialists, so they aren't picked).
    private static func quality(_ engine: Upscaler.Engine) -> Int {
        switch engine {
        case .basic: 0
        case .appleSuperResolution: 1
        case .realESRGANSmall: 2
        case .realESRGAN, .realESRGANAnime: 3
        case .realESRGANLarge2x, .realESRGANLarge, .realESRNetLarge: 4
        case .swinIRMedium2x, .swinIRMedium: 5
        case .swinIRLarge: 6
        }
    }

    private static let specialists: Set<Upscaler.Engine> = [.realESRGANAnime, .realESRNetLarge]

    /// Approximate peak memory for upscaling one `input`-sized frame (bytes). Networks run in tiles, so it's
    /// mostly a fixed cost plus the enlarged output frame.
    static func estimatedMemory(_ engine: Upscaler.Engine, input: CGSize) -> Int64 {
        let pixels = Int64(input.width * input.height)
        if let model = engine.esrgan, let fixed = cost(engine)?.fixedMemory {
            let frames = pixels * Int64(model.scale * model.scale) * 4 + pixels * 12
            return Int64(Double(fixed) * UpscaleSettings.snapshot().memoryFactor) + frames + 250_000_000
        }
        switch engine {
        // Apple's network keeps 4× BGRA frames for temporal consistency plus its model.
        case .appleSuperResolution: return pixels * 16 * 4 * 3 + 450_000_000
        // Lanczos only needs the output frame.
        default: return pixels * 16 * 4 + 150_000_000
        }
    }

    /// Rough seconds per frame for `input` on this Mac, scaled from the M5 timings by GPU cores.
    /// nil for engines that don't depend on the GPU this way (they're fast).
    static func secondsPerFrame(_ engine: Upscaler.Engine, input: CGSize) -> Double? {
        guard let perMegapixel = cost(engine)?.secondsPerMegapixel else { return nil }
        let speed = Double(SystemInfo.gpuCores ?? 8) / 10
        let settings = UpscaleSettings.snapshot()
        return input.width * input.height / 1_000_000 * perMegapixel * settings.speedFactor / speed
    }

    /// A short speed label for the model list.
    static func speedLabel(_ engine: Upscaler.Engine) -> String {
        switch engine {
        case .basic: "Instant"
        case .appleSuperResolution, .realESRGANSmall, .realESRGAN: "Fast"
        case .realESRGANAnime, .realESRGANLarge2x: "Moderate"
        case .realESRGANLarge, .realESRNetLarge: "Slow"
        case .swinIRMedium2x, .swinIRMedium: "Very slow"
        case .swinIRLarge: "Slowest, sharpest"
        }
    }

    /// Model download size, if it has one.
    static func downloadSize(_ engine: Upscaler.Engine) -> Int64? {
        if let model = engine.esrgan { return model.downloadSize }
        return engine == .appleSuperResolution ? 72_000_000 : nil // Apple's is reported by macOS once installed; ~70 MB
    }

    static func availability(_ engine: Upscaler.Engine, input: CGSize = typicalInput) -> Availability {
        if let model = engine.esrgan {
            guard hasMetal else { return .unavailable("Needs a Metal-capable GPU, which this Mac doesn't have.") }
            guard Upscaler.fits(input, model) else {
                return .unavailable("Handles videos up to \(Int(model.maxInput.width))×\(Int(model.maxInput.height)); this one is \(Int(input.width))×\(Int(input.height)). It's already sharp enough for most displays.")
            }
            if let minimum = cost(engine)?.minimumGB, SystemInfo.totalMemory < (minimum << 30) - (1 << 29) {
                return .unavailable("Needs a Mac with at least \(minimum) GB of memory; this one has \(SystemInfo.bytes(SystemInfo.totalMemory)).")
            }
            if let seconds = secondsPerFrame(engine, input: input), seconds > limit {
                let hours = seconds * 900 / 3600
                return .unavailable("Too much for this Mac's \(SystemInfo.gpuCores.map { "\($0)-core " } ?? "")GPU: about \(Int(seconds.rounded())) s per frame, so a 30-second clip would take about \(Int(hours.rounded())) hours. It needs a Pro, Max or Ultra chip.")
            }
        } else if engine == .appleSuperResolution {
            guard SystemInfo.isAppleSilicon else { return .unavailable("Needs an Apple silicon Mac (M1 or later); this Mac has \(SystemInfo.chip).") }
            guard #available(macOS 26.0, *) else { return .unavailable("Needs macOS 26 or later.") }
            guard Upscaler.superResolutionSupported(for: input) else {
                return .unavailable("macOS doesn't support \(Int(input.width))×\(Int(input.height)) input for Super Resolution.")
            }
        } else {
            return .ready
        }
        let needed = estimatedMemory(engine, input: input)
        // Leave room for macOS and the apps you're using.
        if Double(needed) > Double(SystemInfo.totalMemory) * 0.6 {
            return .unavailable("Needs about \(SystemInfo.bytes(needed)) of RAM, more than this Mac's \(SystemInfo.bytes(SystemInfo.totalMemory)) can spare.")
        }
        let available = SystemInfo.availableMemory()
        // macOS keeps some memory looking free by swapping other apps to disk, so its pressure level counts too.
        if needed > available || SystemInfo.memoryPressure() >= 2 {
            return .needsFreeMemory(needed: needed, available: available, swapped: SystemInfo.swapUsed())
        }
        return .ready
    }

    /// The chosen upscaler if this Mac can handle it for this video, otherwise the speed pick.
    static func engine(for input: CGSize) -> Upscaler.Engine {
        availability(.current, input: input).canRun ? .current : picks(input: input).speed.engine
    }

    /// "Apple M5 (10-core GPU, 16 GB)".
    static var macDescription: String {
        "\(SystemInfo.chip) (\(SystemInfo.gpuCores.map { "\($0)-core GPU, " } ?? "")\(SystemInfo.bytes(SystemInfo.totalMemory)))"
    }

    /// The fast, quality and max picks for this Mac and video. Bigger Macs get bigger models for every pick.
    static func picks(input: CGSize = typicalInput) -> Picks {
        // How much the video must grow to cover the display: 2× models suit videos that are only a little small.
        let target = Upscaler.targetSize(for: input, display: Display.pixelSize)
        let needed = input.width > 0 ? target.width / input.width : 4
        func scale(_ engine: Upscaler.Engine) -> Int { engine.esrgan?.scale ?? 4 }
        let runnable = Upscaler.Engine.allCases.filter { availability($0, input: input).canRun }
        let general = runnable.filter { !specialists.contains($0) }
        func time(_ engine: Upscaler.Engine) -> Double { secondsPerFrame(engine, input: input) ?? 0 }
        // A 2× model on a video that needs 4× only does half the job (the rest is plain resizing).
        func worth(_ engine: Upscaler.Engine) -> Int { quality(engine) - (scale(engine) == 2 && needed > 2.05 ? 2 : 0) }
        /// Best quality first; at equal quality the one matching the needed scale, then the quicker one.
        func best(_ pool: [Upscaler.Engine]) -> Upscaler.Engine? {
            pool.max { a, b in
                if worth(a) != worth(b) { return worth(a) < worth(b) }
                let aFits = needed <= 2.05 ? scale(a) == 2 : scale(a) == 4, bFits = needed <= 2.05 ? scale(b) == 2 : scale(b) == 4
                if aFits != bFits { return !aFits }
                return time(a) > time(b)
            }
        }
        func describe(_ engine: Upscaler.Engine) -> String {
            guard let seconds = secondsPerFrame(engine, input: input) else { return "" }
            return seconds < 1 ? " (about \(Int((1 / seconds).rounded())) frames a second here)" : " (about \(String(format: "%.1f", seconds)) s per frame here)"
        }
        let mac = macDescription
        let fallback = runnable.contains(.appleSuperResolution) ? Upscaler.Engine.appleSuperResolution : .basic

        let fast = best(general.filter { time($0) <= speedBudget }) ?? fallback
        let finest = best(general.filter { time($0) <= qualityBudget }) ?? fast
        let biggest = best(general) ?? finest
        return Picks(
            speed: (fast, "The sharpest model that's still quick on your \(mac)\(describe(fast)) — a balance of speed and quality."),
            quality: (finest, "The best results your \(mac) can produce in a reasonable time\(describe(finest))."),
            max: (biggest, "The biggest model your \(mac) can handle\(describe(biggest)). Anything larger is greyed out.")
        )
    }
}
