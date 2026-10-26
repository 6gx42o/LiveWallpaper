import SwiftUI
import UniformTypeIdentifiers

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
                Picker("Section", selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                    ForEach(AppModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 360)
                Divider()
                switch model.tab {
                case .wallpapers:
                    ScrollView { library.padding(.trailing, 4) }
                case .upscale:
                    ScrollView { UpscaleView(studio: model.studio, model: model).padding(.trailing, 4) }
                case .memory:
                    MemoryView(cleaner: model.memory, needed: memoryNeed)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                ScrollView { settings }
                Spacer(minLength: 0)
                quitButton
            }
            .padding(24)
            .frame(width: 330)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.secondary.opacity(0.06))
            .sheet(isPresented: Binding(get: { model.scanner != nil }, set: { if !$0 { model.finishScan(adding: []) } })) {
                if let scanner = model.scanner {
                    ScanView(scanner: scanner) { model.finishScan(adding: $0) }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .sheet(isPresented: Binding(get: { model.editor != nil }, set: { if !$0 { model.closeEditor(save: false) } })) {
            if let editor = model.editor {
                EditorView(
                    editor: editor,
                    upscaleMethod: model.upscaleMethod(for: editor.url).name,
                    upscale: { model.upscale(editor.url) },
                    useForLockScreen: { model.useEditorFrameForLockScreen() },
                    close: { model.closeEditor(save: $0) }
                )
            }
        }
    }

    /// What the chosen upscaler needs, shown on the Memory tab.
    private var memoryNeed: (name: String, bytes: Int64)? {
        let engine = model.studio.info != nil ? model.studio.engine : model.upscaler
        guard engine != .basic else { return nil }
        let input = model.studio.info?.size ?? ModelAdvisor.typicalInput
        return (engine.title, ModelAdvisor.estimatedMemory(engine, input: input))
    }

    private var quitButton: some View {
        Button("Quit LiveWallpaper") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func name(_ url: URL?) -> String? { url?.deletingPathExtension().lastPathComponent }

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
                HStack(spacing: 10) {
                    Label(name(model.current) ?? "None", systemImage: "house.fill")
                        .help("Home screen wallpaper (plays behind your desktop icons)")
                    HStack(spacing: 3) {
                        Label(name(model.lockScreen) ?? "None", systemImage: "lock.fill")
                        if model.lockScreen != nil {
                            Button { model.setLockScreen(nil) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .help("Remove the lock screen wallpaper and restore your own picture")
                                .accessibilityLabel("Remove lock screen wallpaper")
                        }
                    }
                    .help("Lock screen wallpaper (a still frame — macOS doesn't allow video on the lock screen)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
                    model.addFromYouTube()
                } label: {
                    Label("YouTube", systemImage: "play.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Paste a YouTube link to turn it into a wallpaper")
                Button {
                    model.startScan()
                } label: {
                    Label("Find Videos", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Scan Movies, Downloads, Desktop, Documents and Pictures for videos that could be wallpapers")
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
                ProgressCard(progress: converting) { model.library.cancelCurrentJob() }
            }
            ForEach(lib.notices) { notice in
                NoticeCard(
                    notice: notice,
                    upscale: notice.upscale.map { url in { model.upscale(url); model.library.dismiss(notice) } },
                    dismiss: { model.library.dismiss(notice) }
                )
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
                            qualityWarning: lib.issues(for: url).first { $0.severity == .warning }?.text,
                            isHome: url == model.current,
                            isLock: url == model.lockScreen,
                            canEdit: lib.infos[url] != nil,
                            select: { model.select(url) },
                            toggleLock: { model.setLockScreen(url == model.lockScreen ? nil : url) },
                            edit: { model.edit(url) },
                            remove: { model.remove(url) }
                        )
                    }
                }
                if isWindow {
                    grid.padding(2) // the whole column scrolls
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

            Text("Quality & upscaling").font(isWindow ? .headline : .subheadline.weight(.semibold)).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text("Resolution")
                Picker("Resolution", selection: Binding(get: { model.resolution }, set: { model.resolution = $0 })) {
                    ForEach(ResolutionChoice.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Text("Wallpapers are checked and upscaled for this. Native is your display's own resolution.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Upscaler")
                Picker("Upscaler", selection: Binding(get: { model.upscaler }, set: { model.upscaler = $0 })) {
                    ForEach(Upscaler.Engine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .help("Which upscaler the Upscale button uses")
            }
            // The chosen upscaler: download it, see its RAM use and whether it runs on this Mac.
            ModelList(model: model, input: ModelAdvisor.typicalInput, inputLabel: "a 1080p video", compact: true, engines: [model.upscaler])
            Button("Compare all models…") { model.tab = .upscale; model.openWindow?() }
                .buttonStyle(.link).font(.caption)
            SettingRow(
                title: "Ask after upscaling",
                detail: "Offer to keep or delete the Real-ESRGAN model each time it's used.",
                isOn: Binding(get: { model.asksToDeleteModel }, set: { model.asksToDeleteModel = $0 })
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
    let qualityWarning: String?
    let isHome: Bool
    let isLock: Bool
    let canEdit: Bool
    let select: () -> Void
    let toggleLock: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: select) { preview }
                .buttonStyle(.plain)
                .disabled(brokenReason != nil)
                .accessibilityLabel(brokenReason == nil ? "Use \(name) as home screen wallpaper" : "\(name) is broken")
                .help(brokenReason ?? "Click to use as your home screen wallpaper")
                .overlay(alignment: .topTrailing) {
                    Button(action: remove) { circleIcon("trash") }
                        .buttonStyle(.plain)
                        .padding(5)
                        .help("Move to Trash")
                        .accessibilityLabel("Remove \(name)")
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        if isHome { badge("Home", "house.fill") }
                        if isLock { badge("Lock", "lock.fill") }
                    }
                    .padding(5)
                }
                .overlay(alignment: .bottomLeading) {
                    if let qualityWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.black, .yellow)
                            .padding(6)
                            .help(qualityWarning)
                            .accessibilityLabel("Quality warning: \(qualityWarning)")
                    }
                }
            HStack(spacing: 4) {
                if brokenReason != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if brokenReason == nil {
                    Button(action: toggleLock) {
                        Image(systemName: isLock ? "lock.fill" : "lock")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(isLock ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .help(isLock ? "Remove from lock screen" : "Use as lock screen wallpaper")
                    .accessibilityLabel(isLock ? "Remove \(name) from lock screen" : "Use \(name) as lock screen")
                    Button(action: edit) { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(!canEdit)
                        .help("Edit: trim, speed, framing, lock screen frame, quality")
                        .accessibilityLabel("Edit \(name)")
                }
            }
            .font(.caption)
        }
        .contextMenu {
            Button("Use as Home Screen", action: select).disabled(brokenReason != nil)
            Button(isLock ? "Remove from Lock Screen" : "Use as Lock Screen", action: toggleLock).disabled(brokenReason != nil)
            Button("Edit…", action: edit).disabled(!canEdit)
            Divider()
            Button("Move to Trash", role: .destructive, action: remove)
        }
    }

    private func circleIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .padding(5)
            .background(.regularMaterial, in: Circle())
    }

    private func badge(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
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
                    .strokeBorder(isHome ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isHome ? 2.5 : 1)
            )
            .contentShape(Rectangle())
    }
}

/// An error (red), quality warning (orange) or info (accent) message with details to copy.
private struct NoticeCard: View {
    let notice: Library.Notice
    /// Shown as an "Upscale" button for low-resolution warnings.
    let upscale: (() -> Void)?
    let dismiss: () -> Void

    private var color: Color {
        switch notice.kind {
        case .error: .red
        case .warning: .orange
        case .info: .accentColor
        }
    }
    private var symbol: String {
        switch notice.kind {
        case .error, .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title).font(.caption.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                Text(notice.reason).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let details = notice.details {
                    Text(details)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    if let upscale {
                        Button(action: upscale) { Label("Upscale", systemImage: "sparkles") }
                            .controlSize(.small)
                    }
                    Button("Copy details", action: copy)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copy() {
        let text = [notice.title, notice.reason, notice.details].compactMap { $0 }.joined(separator: "\n")
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
