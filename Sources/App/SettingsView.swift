import AppKit
import EventKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: SyncEngine
    @State private var section: Pane = .content

    enum Pane: String, CaseIterable, Identifiable {
        case content = "Content"
        case appearance = "Appearance"
        case slideshow = "Slideshow"
        case sync = "Sync & Access"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .content: "text.alignleft"
            case .appearance: "paintpalette"
            case .slideshow: "photo.on.rectangle"
            case .sync: "arrow.triangle.2.circlepath"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                BoardPreview(engine: engine)
                    .padding([.horizontal, .top], 20)
                    .padding(.bottom, 8)
                Form { detail }
                    .formStyle(.grouped)
            }
            .frame(minWidth: 520)
        }
        .frame(minWidth: 780, minHeight: 640)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let mark = Logo.mask {
                    // Just the bat, tinted to match light or dark mode.
                    Image(nsImage: mark).renderingMode(.template).resizable()
                        .aspectRatio(contentMode: .fit).frame(width: 54)
                        .foregroundStyle(.primary)
                } else {
                    Image(nsImage: Logo.appIcon(size: 64)).resizable().frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Helm").font(.system(size: 17, weight: .bold))
                    Text("Screensaver").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 14)
            ForEach(Pane.allCases) { s in
                Button {
                    section = s
                } label: {
                    Label(s.rawValue, systemImage: s.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(section == s ? Color.accentColor.opacity(0.2) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button("Start Screensaver") { startScreensaver() }
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 200)
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .content: content
        case .appearance: appearance
        case .slideshow: slideshow
        case .sync: sync
        }
    }

    // MARK: Content

    @State private var folderDraft = ""

    @ViewBuilder
    private var content: some View {
        Section("Notes") {
            Toggle("Show notes", isOn: $engine.settings.showNotes)
            LabeledContent("Notes folder") {
                TextField("", text: $folderDraft, prompt: Text("Helm"))
                    .onSubmit { commitFolder() }
                    .onAppear { folderDraft = engine.settings.notesFolder }
                    .frame(width: 180)
                Button("Use") { commitFolder() }.disabled(folderDraft == engine.settings.notesFolder)
            }
            Stepper("Show up to \(engine.settings.maxNotes) notes", value: $engine.settings.maxNotes, in: 1...24)
            Picker("Columns", selection: $engine.settings.columns) {
                Text("Automatic").tag(0)
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle("Hide ticked checklist items", isOn: $engine.settings.hideTickedItems)
        }
        Section("Reminders") {
            Toggle("Show reminders", isOn: $engine.settings.showReminders)
            Toggle("Show what's done today", isOn: $engine.settings.showDoneToday)
            Toggle("All lists", isOn: Binding(
                get: { engine.settings.reminderLists.isEmpty },
                set: { engine.settings.reminderLists = $0 ? [] : engine.reminderListNames }))
            if !engine.settings.reminderLists.isEmpty {
                ForEach(engine.reminderListNames, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { engine.settings.reminderLists.contains(name) },
                        set: { on in
                            var lists = Set(engine.settings.reminderLists)
                            if on { lists.insert(name) } else { lists.remove(name) }
                            // Never leave it empty by accident: empty means "all".
                            engine.settings.reminderLists = lists.isEmpty ? engine.settings.reminderLists : lists.sorted()
                        }))
                    .padding(.leading, 16)
                }
            }
        }
        Section("Watched pages") {
            Toggle("Show pages Helm's browser extension is watching", isOn: $engine.settings.showWatches)
        }
        Section("Clock") {
            Toggle("Show clock", isOn: $engine.settings.showClock)
            Toggle("24-hour time", isOn: $engine.settings.use24Hour)
        }
    }

    private func commitFolder() {
        let name = folderDraft.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { engine.settings.notesFolder = name }
    }

    // MARK: Appearance

    @ViewBuilder
    private var appearance: some View {
        Section("Style") {
            ColorPicker("Accent colour", selection: Binding(
                get: { Color(hex: engine.settings.accentHex) ?? .green },
                set: { engine.settings.accentHex = $0.hexString }), supportsOpacity: false)
            Picker("Font", selection: $engine.settings.fontDesign) {
                Text("System").tag("default")
                Text("Rounded").tag("rounded")
                Text("Serif").tag("serif")
                Text("Monospaced").tag("monospaced")
            }
            slider("Text size", value: $engine.settings.textScale, in: 0.7...1.5, format: { "\(Int($0 * 100))%" })
        }
        Section("Layout") {
            Picker("Notes", selection: $engine.settings.notesOnLeft) {
                Text("On the left").tag(true)
                Text("On the right").tag(false)
            }
            .pickerStyle(.segmented)
        }
        Section("Glass") {
            slider("Glass blur", value: $engine.settings.glassBlur, in: 0...60, format: { $0 < 0.5 ? "Off" : "\(Int($0))" })
            slider("Glass tint", value: $engine.settings.panelOpacity, in: 0...0.9, format: { "\(Int($0 * 100))%" })
            slider("Photo dimming", value: $engine.settings.backgroundDim, in: 0...0.9, format: { "\(Int($0 * 100))%" })
        }
        Section {
            Button("Reset appearance") {
                let d = HelmSettings()
                engine.settings.accentHex = d.accentHex
                engine.settings.fontDesign = d.fontDesign
                engine.settings.textScale = d.textScale
                engine.settings.panelOpacity = d.panelOpacity
                engine.settings.glassBlur = d.glassBlur
                engine.settings.backgroundDim = d.backgroundDim
                engine.settings.notesOnLeft = d.notesOnLeft
            }
        }
    }

    // MARK: Slideshow

    @ViewBuilder
    private var slideshow: some View {
        Section("Photos") {
            Toggle("Show photos", isOn: $engine.settings.showPhotos)
            LabeledContent("Folder") {
                Text(engine.photoSource.path.replacingOccurrences(of: realHome, with: "~"))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Choose…") { choosePhotoFolder() }
            }
            if !engine.settings.photoFolder.isEmpty {
                Button("Use the system slideshow's folder") { engine.settings.photoFolder = "" }
            }
            LabeledContent("Photos ready", value: "\(engine.photoCount)")
        }
        Section("Motion") {
            slider("Seconds per photo", value: $engine.settings.photoDuration, in: 5...60, step: 1, format: { "\(Int($0)) s" })
            slider("Zoom and pan", value: $engine.settings.zoomAmount, in: 0...2, format: {
                $0 < 0.05 ? "Still" : "\(Int($0 * 100))%"
            })
        }
    }

    private func choosePhotoFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = engine.photoSource
        panel.prompt = "Use Folder"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            engine.settings.photoFolder = url.path
        }
    }

    // MARK: Sync & access

    @ViewBuilder
    private var sync: some View {
        Section("Sync") {
            Picker("Check for changes every", selection: $engine.settings.syncInterval) {
                Text("5 seconds").tag(5.0)
                Text("10 seconds").tag(10.0)
                Text("30 seconds").tag(30.0)
                Text("1 minute").tag(60.0)
                Text("5 minutes").tag(300.0)
            }
            LabeledContent("Last synced") {
                if let date = engine.board?.updated {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text("Not yet")
                }
            }
            LabeledContent("Notes read from", value: engine.notesSource?.rawValue ?? "—")
            Button("Sync now") { engine.syncNow() }
        }
        Section {
            accessRow("Full Disk Access",
                      granted: engine.fullDiskAccess,
                      detail: engine.fullDiskAccess
                          ? "Checklists, headings and lists come through with their ticks."
                          : "Needed to show checklists with their ticks. Click Open, then turn on Helm (use + if it isn't listed).",
                      open: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
            if !engine.fullDiskAccess {
                Button("Show Helm in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            }
            accessRow("Reminders",
                      granted: engine.remindersAccess == .fullAccess,
                      detail: engine.remindersAccess == .fullAccess ? "Reminders show with their done state." : "Needed to show your reminders.",
                      open: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        } header: {
            Text("Access")
        }
        Section("Startup") {
            Toggle("Open Helm at login", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.set($0) }))
        }
    }

    private func accessRow(_ title: String, granted: Bool, detail: String, open url: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open") { NSWorkspace.shared.open(URL(string: url)!) }
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
                        format: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack {
                if let step {
                    Slider(value: value, in: range, step: step)
                } else {
                    Slider(value: value, in: range)
                }
                Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            }
            .frame(width: 260)
        }
    }

    private func startScreensaver() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"),
                                           configuration: .init())
    }
}

/// A live, scaled-down screensaver: current notes and settings over a photo.
struct BoardPreview: View {
    @ObservedObject var engine: SyncEngine
    @State private var photo: NSImage?

    var body: some View {
        let canvas = CGSize(width: 1470, height: 956)
        GeometryReader { geo in
            let scale = geo.size.width / canvas.width
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                GlassStage(board: previewBoard, t: 10, now: tl.date, size: canvas) {
                    if engine.settings.showPhotos, let photo {
                        Image(nsImage: photo).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: canvas.width, height: canvas.height).clipped()
                    } else {
                        Color.black
                    }
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
        .onAppear { loadPhoto() }
        .onChange(of: engine.photoCount) { loadPhoto() }
    }

    /// Current content with the settings being edited (not yet synced).
    private var previewBoard: Board {
        var b = engine.board ?? Board(updated: Date())
        b.settings = engine.settings
        return b
    }

    private func loadPhoto() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Board.photosURL, includingPropertiesForKeys: nil)) ?? []
        photo = files.sorted { $0.lastPathComponent < $1.lastPathComponent }.first.flatMap { NSImage(contentsOf: $0) }
    }
}

extension Color {
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .systemGreen
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
