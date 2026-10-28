import AppKit
import SwiftUI

/// Asks before a model downloads (the only time models are fetched).
@MainActor
enum ModelConsent {
    /// true = download, false = use Basic instead, nil = cancel.
    static func ask(for engine: Upscaler.Engine) -> Bool? {
        NSApp.activate()
        let alert = NSAlert()
        if let model = engine.esrgan {
            alert.messageText = "Download \(engine.title)?"
            let project = model.url.pathComponents.dropFirst().prefix(2).joined(separator: "/") // e.g. xinntao/Real-ESRGAN
            alert.informativeText = "Upscaling uses the open-source \(engine.title) model (\(TransferProgress.size(model.downloadSize)), the official file from github.com/\(project)). It's saved in LiveWallpaper's own folder and you can delete it any time in Settings."
        } else {
            alert.messageText = "Download Apple's upscaling model?"
            alert.informativeText = "Apple Super Resolution needs a model (about \(TransferProgress.size(ModelAdvisor.downloadSize(.appleSuperResolution) ?? 0))) that macOS downloads once, from Apple. macOS manages it — apps can't delete it later. Choose a Real-ESRGAN or SwinIR model for one you can delete."
        }
        alert.addButton(withTitle: "Download & Upscale")
        alert.addButton(withTitle: "Use Basic Upscaling")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }
}

/// Every upscaler with what it needs on this Mac: download status, RAM and time for `input`, whether this
/// Mac can handle it (greyed out with the reason if not), the three per-Mac picks, and Download / Delete.
struct ModelList: View {
    @ObservedObject var model: AppModel
    /// Source size the RAM estimates are for.
    let input: CGSize
    let inputLabel: String
    /// Highlights and lets the user pick an engine (nil = informational).
    var selection: Binding<Upscaler.Engine>?
    var compact = false
    /// Which engines to list (Settings shows only the selected one).
    var engines: [Upscaler.Engine] = Upscaler.Engine.allCases

    var body: some View {
        let picks = ModelAdvisor.picks(input: input)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                pickRow("Recommended for speed", "hare.fill", .blue, picks.speed,
                        info: "The sharpest model that still upscales quickly on this Mac — about 1.5 s a frame or less. It's a balance, not just the fastest model: bigger Macs get bigger models here.")
                pickRow("Recommended for quality", "sparkles", .purple, picks.quality,
                        info: "The best-looking results this Mac can produce in a reasonable time — up to about 15 s a frame, so a 30-second clip finishes in a few hours at most.")
                pickRow("Max for this Mac", "gauge.with.dots.needle.100percent", .orange, picks.max,
                        info: "The biggest model this Mac can handle at all. Models beyond it are greyed out: they'd need more memory than this Mac can spare, or a faster GPU (they'd take over 30 s a frame).")
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            ForEach(engines, id: \.self) { engine in
                row(engine, picks: picks)
            }
        }
    }

    private func pickRow(_ title: String, _ symbol: String, _ color: Color, _ pick: (engine: Upscaler.Engine, reason: String), info: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title).foregroundStyle(.secondary)
                    InfoButton(info)
                }
                .font(.caption)
                Text(pick.engine.title).fontWeight(.medium)
                Text(pick.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let selection {
                Button(selection.wrappedValue == pick.engine ? "In Use" : "Use") { selection.wrappedValue = pick.engine }
                    .controlSize(.small)
                    .disabled(selection.wrappedValue == pick.engine)
            }
        }
    }

    @ViewBuilder private func row(_ engine: Upscaler.Engine, picks: ModelAdvisor.Picks) -> some View {
        let availability = ModelAdvisor.availability(engine, input: input)
        let isSelected = selection?.wrappedValue == engine
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let selection {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .onTapGesture { if availability.canRun { selection.wrappedValue = engine } }
                }
                Text(engine.title).fontWeight(.medium).lineLimit(1).fixedSize()
                InfoButton(engine.summary)
                if engine == picks.speed.engine { badge("Speed pick", .blue).fixedSize() }
                if engine == picks.quality.engine { badge("Quality pick", .purple).fixedSize() }
                if engine == picks.max.engine { badge("Max for this Mac", .orange).fixedSize() }
                if !availability.canRun { badge("Too much for this Mac", .secondary).fixedSize() }
                badge(ModelAdvisor.speedLabel(engine), .secondary).fixedSize()
                Spacer(minLength: 4)
                actions(engine).fixedSize()
            }
            Text(statusText(engine)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Uses about \(SystemInfo.bytes(ModelAdvisor.estimatedMemory(engine, input: input))) of RAM for \(inputLabel)" + speedText(engine) + ".")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch availability {
            case .ready:
                Label("Runs on your \(SystemInfo.chip) (\(SystemInfo.bytes(SystemInfo.totalMemory)))", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .needsFreeMemory(let needed, let available, let swapped):
                VStack(alignment: .leading, spacing: 3) {
                    Label(needed > available
                          ? "Needs about \(SystemInfo.bytes(needed)) free; only \(SystemInfo.bytes(available)) is free right now. Quit some apps first."
                          : "Needs about \(SystemInfo.bytes(needed)), but macOS is short on memory (\(SystemInfo.bytes(swapped)) swapped to disk). Quit some apps first so upscaling doesn't slow your Mac.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("Free Up Memory…") { model.tab = .memory; model.openWindow?() }
                        .controlSize(.small)
                }
            case .unavailable(let reason):
                Label("Can't run: \(reason)", systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let download = model.modelDownload, download.engine == engine {
                ProgressCard(progress: download.progress, symbol: "arrow.down.circle") { model.cancelModelDownload() }
            }
        }
        .padding(compact ? 8 : 10)
        .background(isSelected ? Color.appAccent.opacity(0.1) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        // Greyed out when this Mac can't handle it; the reason stays readable.
        .saturation(availability.canRun ? 1 : 0)
        .opacity(availability.canRun ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { if let selection, availability.canRun { selection.wrappedValue = engine } }
    }

    private func statusText(_ engine: Upscaler.Engine) -> String {
        let size = model.modelSizes[engine].map(TransferProgress.size)
        switch engine {
        case .appleSuperResolution:
            return size.map { "Model downloaded · \($0) · managed by macOS (can't be deleted by apps)" }
                ?? "Model not downloaded · about \(TransferProgress.size(ModelAdvisor.downloadSize(.appleSuperResolution) ?? 0)) download · managed by macOS"
        case .basic:
            return "No model needed"
        default:
            return size.map { "Model downloaded · \($0) · deletable" }
                ?? "Model not downloaded · \(TransferProgress.size(ModelAdvisor.downloadSize(engine) ?? 0)) download"
        }
    }

    /// ", about 1.3 s per frame on this Mac" for GPU models.
    private func speedText(_ engine: Upscaler.Engine) -> String {
        guard let seconds = ModelAdvisor.secondsPerFrame(engine, input: input) else { return "" }
        return seconds <= 0.5
            ? ", about \(Int((1 / seconds).rounded())) frames a second on this Mac"
            : ", about \(String(format: "%.1f", seconds)) s per frame on this Mac"
    }

    @ViewBuilder private func actions(_ engine: Upscaler.Engine) -> some View {
        let downloading = model.modelDownload?.engine == engine
        if engine != .basic, model.modelSizes[engine] == nil {
            Button(downloading ? "Downloading…" : "Download") { model.downloadModel(engine) }
                .controlSize(.small)
                .disabled(downloading || model.modelDownload != nil || !ModelAdvisor.availability(engine, input: input).canRun)
        } else if engine.esrgan != nil {
            Button("Delete…") { model.deleteModel(engine) }.controlSize(.small)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color).background(color.opacity(0.15), in: Capsule())
    }
}
