import AppKit
import Darwin

/// What this Mac has: chip, memory, and each display's native panel resolution.
enum SystemInfo {
    /// e.g. "Apple M5" or "Intel(R) Core(TM) i9…".
    static let chip: String = sysctlString("machdep.cpu.brand_string") ?? "Unknown chip"
    static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()
    static let totalMemory = Int64(ProcessInfo.processInfo.physicalMemory)

    /// Memory that can be used right now without swapping: free + inactive + purgeable pages.
    static func availableMemory() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return totalMemory / 2 }
        let pages = Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.purgeable_count) + Int64(stats.speculative_count)
        return pages * Int64(vm_kernel_page_size)
    }

    /// Pages that are completely unused right now (purge moves cached files here).
    static func freeMemory() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(stats.free_count) * Int64(vm_kernel_page_size) : 0
    }

    /// macOS's own verdict: 1 = normal, 2 = warning (compressing/swapping), 4 = critical.
    static func memoryPressure() -> Int {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Int(level) : 1
    }

    /// Memory already pushed out to disk.
    static func swapUsed() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? Int64(usage.xsu_used) : 0
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: Displays

    struct Screen {
        let name: String
        /// The panel's physical pixel resolution (largest mode the display offers).
        let native: CGSize
    }

    /// Every connected display with its native resolution — works for any Mac or external monitor.
    static var screens: [Screen] {
        NSScreen.screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
            // macOS flags the panel's true native mode; scaled "More Space" modes can be larger, so don't just take the biggest.
            let nativeFlag: UInt32 = 0x0200_0000 // kDisplayModeNativeFlag
            let best = modes.filter { $0.ioFlags & nativeFlag != 0 }.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
                ?? modes.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
            let native = best.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
                ?? CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
            return Screen(name: screen.localizedName, native: native)
        }
    }

    /// The largest connected display's native resolution.
    static var nativeResolution: Screen {
        screens.max { $0.native.width * $0.native.height < $1.native.width * $1.native.height }
            ?? Screen(name: "Display", native: CGSize(width: 1920, height: 1080))
    }
}

/// The resolution wallpapers are checked and upscaled against. Defaults to the display's native resolution.
enum ResolutionChoice: String, CaseIterable, Identifiable {
    case native, uhd5k, uhd4k, qhd, fullHD

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .native: SystemInfo.nativeResolution.native
        case .uhd5k: CGSize(width: 5120, height: 2880)
        case .uhd4k: CGSize(width: 3840, height: 2160)
        case .qhd: CGSize(width: 2560, height: 1440)
        case .fullHD: CGSize(width: 1920, height: 1080)
        }
    }

    var title: String {
        let s = size
        let pixels = "\(Int(s.width))×\(Int(s.height))"
        switch self {
        case .native: return "Native — \(pixels) (\(SystemInfo.nativeResolution.name))"
        case .uhd5k: return "5K — \(pixels)"
        case .uhd4k: return "4K — \(pixels)"
        case .qhd: return "1440p — \(pixels)"
        case .fullHD: return "1080p — \(pixels)"
        }
    }

    static var current: ResolutionChoice {
        get { UserDefaults.standard.string(forKey: "resolution").flatMap(ResolutionChoice.init) ?? .native }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "resolution") }
    }
}
