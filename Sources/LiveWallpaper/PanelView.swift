import SwiftUI

/// Status, wallpaper library and settings — as the compact menu bar panel, or as the
/// resizable (full-screen capable) app window.
struct PanelView: View {
    @ObservedObject var model: AppModel
    var isWindow = false

    var body: some View {
        if isWindow { windowLayout } else { panelLayout }
    }

    private var panelLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            library
            Divider()
            settings
            Divider()
            HStack {
                Spacer()
                quitButton
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var windowLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                library
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], delegate: VideoDropDelegate(model: model))

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                settings
                Spacer()
                quitButton
            }
            .padding(24)
            .frame(width: 300)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.secondary.opacity(0.06))
        }
        .frame(minWidth: 760, minHeight: 500)
    }

    private var quitButton: some View {
        Button("Quit LiveWallpaper") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    // MARK: Header

    private var header: some View {
        let status = model.status
        return HStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: isWindow ? 30 : 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("LiveWallpaper").font(isWindow ? .title2.weight(.semibold) : .headline)
                HStack(spacing: 5) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("status")
                }
            }
            Spacer()
            if !isWindow {
                Button {
                    model.openWindow?()
                } label: {
                    Image(systemName: "macwindow").frame(width: 16, height: 16)
                }
                .controlSize(.large)
                .help("Open the LiveWallpaper window")
                .accessibilityLabel("Open window")
            }
            Button {
                model.gate.userPaused.toggle()
            } label: {
                Image(systemName: model.gate.userPaused ? "play.fill" : "pause.fill")
                    .frame(width: 16, height: 16)
            }
            .controlSize(.large)
            .disabled(model.current == nil || model.isCurrentBroken)
            .help(model.gate.userPaused ? "Resume" : "Pause")
            .accessibilityLabel(model.gate.userPaused ? "Resume" : "Pause")
        }
    }

    // MARK: Library

    private var library: some View {
        let lib = model.library
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Wallpapers").font(isWindow ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                Spacer()
                Button {
                    model.addVideos()
                } label: {
                    Label("Add Video", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .controlSize(isWindow ? .large : .regular)

            // The window takes drag & drop; the panel closes as soon as you click another app.
            if isWindow || lib.videos.isEmpty {
                DropZone(
                    isLarge: lib.videos.isEmpty,
                    acceptsDrops: isWindow,
                    isTargeted: model.isDropTargeted,
                    add: model.addVideos
                )
            }
            if let converting = lib.converting {
                ConvertingCard(name: converting.name, fraction: converting.fraction)
            }
            ForEach(lib.failures) { failure in
                BrokenCard(failure: failure) { model.library.dismissFailure(failure) }
            }

            if !lib.videos.isEmpty {
                let columns = isWindow
                    ? [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 18)]
                    : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                let grid = LazyVGrid(columns: columns, spacing: isWindow ? 20 : 12) {
                    ForEach(lib.videos, id: \.self) { url in
                        WallpaperTile(
                            name: url.deletingPathExtension().lastPathComponent,
                            thumbnail: lib.thumbnails[url],
                            brokenReason: lib.broken[url],
                            isSelected: url == model.current,
                            select: { model.select(url) },
                            remove: { model.remove(url) }
                        )
                    }
                }
                if isWindow {
                    ScrollView { grid.padding(2) }
                } else if lib.videos.count > 4 {
                    ScrollView { grid.padding(2) }.frame(height: 250)
                } else {
                    grid
                }
            }
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(isWindow ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
            SettingRow(
                title: "Play in Low Power Mode",
                detail: "Off saves battery: the wallpaper pauses in Low Power Mode.",
                isOn: Binding(get: { model.gate.playsInLowPowerMode }, set: { model.gate.playsInLowPowerMode = $0 })
            )
            SettingRow(
                title: "Pause when the desktop is covered",
                detail: "Full-screen apps or maximized windows hide the wallpaper.",
                isOn: Binding(get: { model.gate.pausesWhenCovered }, set: { model.gate.pausesWhenCovered = $0 })
            )
            SettingRow(
                title: "Open at login",
                detail: model.launchAtLoginNeedsApproval
                    ? "Allow it in System Settings › General › Login Items."
                    : "Start LiveWallpaper automatically.",
                isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })
            )
        }
    }
}

// MARK: - Components

private struct SettingRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct WallpaperTile: View {
    let name: String
    let thumbnail: NSImage?
    let brokenReason: String?
    let isSelected: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: select) { preview }
                .buttonStyle(.plain)
                .disabled(brokenReason != nil)
                .accessibilityLabel(brokenReason == nil ? "Use \(name)" : "\(name) is broken")
                .overlay(alignment: .topTrailing) {
                    Button(action: remove) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(5)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .help("Move to Trash")
                    .accessibilityLabel("Remove \(name)")
                }
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                } else if brokenReason != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Text(name).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
        }
        .help(brokenReason ?? name)
        .contextMenu {
            Button("Move to Trash", role: .destructive, action: remove)
        }
    }

    private var preview: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if brokenReason != nil {
                    ZStack {
                        Color.red.opacity(0.12)
                        VStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Broken").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.red)
                    }
                } else if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2.5 : 1)
            )
            .contentShape(Rectangle())
    }
}

private struct ConvertingCard: View {
    let name: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "wand.and.stars")
                Text("Converting “\(name)”").lineLimit(1).truncationMode(.middle)
                Spacer()
                if let fraction { Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary) }
            }
            .font(.caption)
            if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BrokenCard: View {
    let failure: Library.ImportFailure
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.title).font(.caption.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                Text(failure.reason).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let details = failure.details {
                    Text(details)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Button("Copy details", action: copy)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copy() {
        let text = [failure.title, failure.reason, failure.details].compactMap { $0 }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Click to choose videos; in the window, also a drag & drop target that lights up while hovered.
private struct DropZone: View {
    let isLarge: Bool
    let acceptsDrops: Bool
    let isTargeted: Bool
    let add: () -> Void

    private var title: String {
        isTargeted ? "Release to add" : acceptsDrops ? "Drop videos here" : "Add a video to get started"
    }
    private var subtitle: String {
        acceptsDrops
            ? "or click to choose — any video is converted automatically"
            : "Click to choose a file. Open the window to drag & drop."
    }

    var body: some View {
        Button(action: add) {
            Group {
                if isLarge {
                    VStack(spacing: 6) {
                        icon.font(acceptsDrops ? .largeTitle : .title2)
                        Text(title)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.vertical, acceptsDrops ? 80 : 22)
                    .padding(.horizontal, 12)
                } else {
                    HStack(spacing: 10) {
                        icon.font(.title3)
                        Text(title)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                }
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6]))
                    .foregroundStyle(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(acceptsDrops ? "Drop videos here, or click to choose" : "Add a video")
    }

    private var icon: some View {
        Image(systemName: isTargeted ? "arrow.down.circle.fill" : "square.and.arrow.down.on.square")
            .foregroundStyle(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
    }
}

/// Accepts files dragged onto the window and hands them to the library.
private struct VideoDropDelegate: DropDelegate {
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { model.isDropTargeted = true }
    func dropExited(info: DropInfo) { model.isDropTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        model.isDropTargeted = false
        model.importDropped(info.itemProviders(for: [.fileURL]))
        return true
    }
}
