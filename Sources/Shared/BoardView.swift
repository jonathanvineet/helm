import SwiftUI

/// Notes and reminders drawn over the slideshow: every note in the Helm folder
/// tiled as a card, reminders alongside. `t` is seconds since the screensaver started.
struct BoardView: View {
    let board: Board?
    let t: Double
    let now: Date
    let size: CGSize

    private var s: HelmSettings { board?.settings ?? HelmSettings() }
    private var accent: Color { Color(hex: s.accentHex) ?? .green }
    private var design: Font.Design {
        switch s.fontDesign {
        case "rounded": .rounded
        case "serif": .serif
        case "monospaced": .monospaced
        default: .default
        }
    }

    private func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    var body: some View {
        let W = size.width, H = size.height
        let pad = max(14, W * 0.045)
        let base = max(7, min(W, H * 1.6) * 0.0155) * s.textScale
        let appear = min(1, max(0, t / 1.2))
        let dim = s.backgroundDim

        ZStack {
            // Darken top and bottom (and a little overall) so text reads on any photo.
            LinearGradient(stops: [.init(color: .black.opacity(min(1, dim + 0.2)), location: 0),
                                   .init(color: .black.opacity(dim * 0.3), location: 0.35),
                                   .init(color: .black.opacity(dim * 0.4), location: 0.7),
                                   .init(color: .black.opacity(min(1, dim + 0.15)), location: 1)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: base * 1.6) {
                header(base: base)
                content(base: base, width: W - pad * 2)
                    .frame(maxHeight: .infinity, alignment: .top)
                footer(base: base)
            }
            .padding(.horizontal, pad)
            .padding(.top, pad * 0.9)
            .padding(.bottom, pad * 0.6)
            .opacity(appear)
            .offset(y: (1 - appear) * base * 2)
        }
        .frame(width: W, height: H)
    }

    @ViewBuilder
    private func content(base: CGFloat, width: CGFloat) -> some View {
        let gap = width * 0.025
        switch (s.showNotes, showSide) {
        case (true, true):
            HStack(alignment: .top, spacing: gap) {
                if s.notesOnLeft {
                    notesGrid(base: base).frame(width: (width - gap) * 0.66)
                    sideColumn(base: base)
                } else {
                    sideColumn(base: base).frame(width: (width - gap) * 0.34)
                    notesGrid(base: base)
                }
            }
        case (true, false):
            notesGrid(base: base)
        case (false, true):
            sideColumn(base: base).frame(maxWidth: width * 0.5)
                .frame(maxWidth: .infinity, alignment: s.notesOnLeft ? .trailing : .leading)
        case (false, false):
            Color.clear
        }
    }

    private var watches: [BoardWatch] {
        guard s.showWatches else { return [] }
        let order: [BoardWatch.State] = [.attention, .pending, .watching, .done]
        return (board?.watches ?? []).sorted { order.firstIndex(of: $0.state)! < order.firstIndex(of: $1.state)! }
    }

    private var showSide: Bool { s.showReminders || s.showWatches }

    /// Reminders to show; with none, the To do panel shrinks to "All clear".
    private var hasTasks: Bool {
        !(board?.todo ?? []).isEmpty || (s.showDoneToday && !(board?.done ?? []).isEmpty) || board?.remindersError != nil
    }

    /// Reminders, with watched pages underneath.
    private func sideColumn(base: CGFloat) -> some View {
        VStack(spacing: base * 0.9) {
            // Whichever panel has something in it takes the spare height.
            if s.showReminders { tasksPanel(base: base, fill: hasTasks) }
            if s.showWatches { watchesPanel(base: base, fill: !s.showReminders || !hasTasks) }
        }
    }

    // MARK: Header

    private var notes: [BoardNote] { Array((board?.notes ?? []).prefix(s.maxNotes)) }

    private func header(base: CGFloat) -> some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: base * 0.3) {
                if s.showNotes {
                    Text(notes.isEmpty ? "NOTES" : "NOTES · \(notes.count)")
                        .font(font(base * 0.8, .semibold))
                        .tracking(base * 0.12)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(font(base * 2.4, .bold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: base * 2)
            if s.showClock {
                Text(clock)
                    .font(font(base * 3.4, .light))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: base * 0.6)
    }

    private var clock: String {
        let f = DateFormatter()
        f.dateFormat = s.use24Hour ? "HH:mm" : "h:mm a"
        return f.string(from: now)
    }

    // MARK: Notes, tiled

    private func notesGrid(base: CGFloat) -> some View {
        GeometryReader { geo in
            let n = notes.count
            let auto = n <= 1 ? 1 : n <= 4 ? 2 : n <= 9 ? 3 : 4
            let cols = max(1, min(s.columns > 0 ? s.columns : auto, max(n, 1)))
            let rows = max(1, Int(ceil(Double(n) / Double(cols))))
            let gap = base * 0.9
            let cardW = (geo.size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let cardH = (geo.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            // Shrink type as the grid gets denser, within readable limits.
            let scale = min(1, max(0.62, min(cardW / (base * 22), cardH / (base * 11))))
            if n == 0 {
                emptyNotes(base: base)
            } else {
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: gap) {
                            ForEach(0..<cols, id: \.self) { c in
                                let i = r * cols + c
                                if i < n {
                                    noteCard(notes[i], base: base * scale, height: cardH)
                                        .frame(width: cardW, height: cardH)
                                } else {
                                    Color.clear.frame(width: cardW, height: cardH)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func noteCard(_ note: BoardNote, base: CGFloat, height: CGFloat) -> some View {
        let lines = s.hideTickedItems ? note.lines.filter { !($0.kind == .check && $0.done) } : note.lines
        let checks = note.lines.filter { $0.kind == .check }
        let lineH = base * 1.2 * 1.5
        let fits = max(0, Int((height - base * 1.2 * 2 - base * 2.6 - base * 1.6) / lineH) - 1)
        let shown = Array(lines.prefix(fits))
        let numbers = numbering(shown)
        return VStack(alignment: .leading, spacing: base * 0.35) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.title)
                    .font(font(base * 1.9, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: base)
                if !checks.isEmpty {
                    let doneCount = checks.filter(\.done).count
                    Text("\(doneCount)/\(checks.count)")
                        .font(font(base * 0.9, .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, base * 0.5)
                        .padding(.vertical, base * 0.15)
                        .background(Capsule().fill(doneCount == checks.count ? accent.opacity(0.85) : .white.opacity(0.18)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
                        .foregroundStyle(.white)
                }
            }
            .padding(.bottom, base * 0.2)
            ForEach(Array(shown.enumerated()), id: \.offset) { i, line in
                lineView(line, number: numbers[i], base: base)
            }
            if lines.count > shown.count {
                Text("…").font(font(base * 1.2)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            Text("Edited \(note.modified, format: .relative(presentation: .named))")
                .font(font(base * 0.8))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(base * 1.2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(radius: base * 1.1, tint: s.panelOpacity)
    }

    /// Running numbers for consecutive numbered-list lines.
    private func numbering(_ lines: [NoteLine]) -> [Int] {
        var out: [Int] = [], n = 0
        for line in lines {
            n = line.kind == .numbered ? n + 1 : 0
            out.append(n)
        }
        return out
    }

    @ViewBuilder
    private func lineView(_ line: NoteLine, number: Int, base: CGFloat) -> some View {
        let size = base * 1.2
        let indent = CGFloat(line.indent) * base * 1.4
        if line.text.isEmpty {
            Color.clear.frame(height: base * 0.35)
        } else {
            switch line.kind {
            case .heading:
                Text(line.text).font(font(size * 1.1, .semibold)).foregroundStyle(.white).lineLimit(1)
                    .padding(.top, base * 0.2)
            case .check:
                HStack(alignment: .firstTextBaseline, spacing: base * 0.55) {
                    Image(systemName: line.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: size))
                        .foregroundStyle(line.done ? accent : .white.opacity(0.75))
                    Text(line.text)
                        .font(font(size))
                        .strikethrough(line.done, color: .white.opacity(0.5))
                        .foregroundStyle(.white.opacity(line.done ? 0.5 : 0.92))
                        .lineLimit(1)
                }
                .padding(.leading, indent)
            case .bullet, .numbered:
                HStack(alignment: .firstTextBaseline, spacing: base * 0.55) {
                    Text(line.kind == .bullet ? "•" : "\(number).")
                        .font(font(size, .medium))
                        .foregroundStyle(accent)
                    Text(line.text).font(font(size)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                }
                .padding(.leading, indent)
            case .text:
                Text(line.text).font(font(size)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                    .padding(.leading, indent)
            }
        }
    }

    private func emptyNotes(base: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: base * 0.6) {
            Text(board == nil ? "Waiting for Helm" : "No notes yet")
                .font(font(base * 1.9, .bold))
                .foregroundStyle(.white)
            Text(board?.notesError ?? "Notes you put in the \(s.notesFolder) folder in the Notes app show up here, one card each. The first line becomes the heading.")
                .font(font(base * 1.2))
                .foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 0)
        }
        .padding(base * 1.4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(radius: base * 1.1, tint: s.panelOpacity)
    }

    // MARK: Reminders: what's left, and what got done today.

    private func tasksPanel(base: CGFloat, fill: Bool) -> some View {
        let todo = board?.todo ?? []
        let done = s.showDoneToday ? (board?.done ?? []) : []
        let total = todo.count + done.count
        let maxTodo = !s.showWatches ? 7 : watches.isEmpty ? 5 : 3, maxDone = !s.showWatches ? 4 : watches.isEmpty ? 2 : 1
        return VStack(alignment: .leading, spacing: base * 0.7) {
            HStack(alignment: .firstTextBaseline) {
                Text("TO DO")
                    .font(font(base * 0.8, .semibold))
                    .tracking(base * 0.12)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if total > 0 && s.showDoneToday {
                    Text("\(done.count) of \(total) done today")
                        .font(font(base * 0.85, .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            if total > 0 && s.showDoneToday {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                            .shadow(color: accent.opacity(0.6), radius: base * 0.4)
                            .frame(width: g.size.width * CGFloat(done.count) / CGFloat(total))
                    }
                }
                .frame(height: base * 0.35)
            }

            if let error = board?.remindersError {
                Text(error).font(font(base * 1.05)).foregroundStyle(.orange)
            } else if todo.isEmpty {
                Text("All clear").font(font(base * 1.2, .medium)).foregroundStyle(.white.opacity(0.85))
            }
            ForEach(Array(todo.prefix(maxTodo).enumerated()), id: \.offset) { _, task in
                taskRow(task, done: false, base: base)
            }
            if todo.count > maxTodo {
                Text("+ \(todo.count - maxTodo) more").font(font(base * 0.9)).foregroundStyle(.white.opacity(0.55))
            }

            if !done.isEmpty {
                Text("DONE TODAY")
                    .font(font(base * 0.8, .semibold))
                    .tracking(base * 0.12)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, base * 0.5)
                ForEach(Array(done.prefix(maxDone).enumerated()), id: \.offset) { _, task in
                    taskRow(task, done: true, base: base)
                }
            }
            if fill { Spacer(minLength: 0) }
        }
        .frame(minHeight: 0, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .clipped()
        .padding(base * 1.4)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .glass(radius: base * 1.1, tint: s.panelOpacity)
    }

    private func taskRow(_ task: BoardTask, done: Bool, base: CGFloat) -> some View {
        let overdue = !done && (task.due.map { $0 < now } ?? false)
        return HStack(alignment: .firstTextBaseline, spacing: base * 0.7) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: base * 1.1))
                .foregroundStyle(done ? accent : overdue ? Color.orange : Color.white.opacity(0.8))
            VStack(alignment: .leading, spacing: base * 0.1) {
                Text(task.title)
                    .font(font(base * 1.15, .medium))
                    .strikethrough(done, color: .white.opacity(0.5))
                    .foregroundStyle(.white.opacity(done ? 0.55 : 0.95))
                    .lineLimit(1)
                Text(meta(task, overdue: overdue))
                    .font(font(base * 0.8))
                    .foregroundStyle(overdue ? Color.orange : .white.opacity(0.5))
                    .lineLimit(1)
            }
        }
    }

    private func meta(_ task: BoardTask, overdue: Bool) -> String {
        guard let due = task.due else { return task.list }
        let cal = Calendar.current
        let when: String
        if overdue {
            when = "Overdue · " + due.formatted(.relative(presentation: .named))
        } else if cal.isDateInToday(due) {
            when = "Today"
        } else if cal.isDateInTomorrow(due) {
            when = "Tomorrow"
        } else {
            when = due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return "\(task.list) · \(when)"
    }

    // MARK: Watched pages, from the browser extension

    private func watchesPanel(base: CGFloat, fill: Bool) -> some View {
        let updates = watches.filter { $0.state == .attention }.count
        let maxWatches = !fill ? 3 : watches.count > 5 ? 4 : 5
        return VStack(alignment: .leading, spacing: base * 0.7) {
            HStack(alignment: .firstTextBaseline) {
                Text("WAITING ON")
                    .font(font(base * 0.8, .semibold))
                    .tracking(base * 0.12)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if updates > 0 {
                    Text(updates == 1 ? "1 update" : "\(updates) updates")
                        .font(font(base * 0.85, .medium))
                        .foregroundStyle(.orange)
                }
            }
            if watches.isEmpty {
                Text("Nothing yet").font(font(base * 1.2, .medium)).foregroundStyle(.white.opacity(0.85))
                Text("Pages you watch with Helm's browser extension show up here, like an order or an app review.")
                    .font(font(base * 0.9))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(watches.prefix(maxWatches).enumerated()), id: \.offset) { _, watch in
                watchRow(watch, base: base)
            }
            if watches.count > maxWatches {
                Text("+ \(watches.count - maxWatches) more").font(font(base * 0.9)).foregroundStyle(.white.opacity(0.55))
            }
            if fill { Spacer(minLength: 0) }
        }
        // Give way rather than push the board off screen on small displays.
        .frame(minHeight: 0, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .clipped()
        .padding(base * 1.4)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .glass(radius: base * 1.1, tint: s.panelOpacity)
    }

    /// A symbol for what the watch is; the colour says how it's going.
    private func kindSymbol(_ kind: String) -> String {
        switch kind {
        case "delivery": "shippingbox.fill"
        case "appReview": "app.badge.fill"
        case "access": "key.fill"
        case "government": "building.columns.fill"
        case "job": "briefcase.fill"
        case "results": "graduationcap.fill"
        case "booking": "ticket.fill"
        case "refund": "creditcard.fill"
        case "ticket": "bubble.left.and.bubble.right.fill"
        case "build": "hammer.fill"
        case "product": "tag.fill"
        default: "eye.fill"
        }
    }

    private func watchRow(_ watch: BoardWatch, base: CGFloat) -> some View {
        let color: Color = switch watch.state {
        case .attention: .orange
        case .pending: .yellow
        case .watching: .white.opacity(0.8)
        case .done: accent
        }
        let icon = watch.state == .done ? "checkmark.circle.fill"
            : watch.state == .attention && watch.kind == "general" ? "exclamationmark.circle.fill"
            : kindSymbol(watch.kind)
        var detail = watch.quoted ? "“\(watch.text)”" : watch.text
        if let since = watch.since {
            detail += " · " + since.formatted(.relative(presentation: .named))
        }
        return HStack(alignment: .firstTextBaseline, spacing: base * 0.7) {
            Image(systemName: icon)
                .font(.system(size: base * 1.1))
                .foregroundStyle(color)
                .frame(width: base * 1.6)
            VStack(alignment: .leading, spacing: base * 0.1) {
                Text(watch.name)
                    .font(font(base * 1.15, .medium))
                    .foregroundStyle(.white.opacity(watch.state == .done ? 0.7 : 0.95))
                    .lineLimit(1)
                Text(detail)
                    .font(font(base * 0.8))
                    .foregroundStyle(watch.state == .attention ? Color.orange : .white.opacity(0.55))
                    .lineLimit(1)
                if watch.steps > 1 && watch.step > 0 && watch.state != .attention {
                    stepsBar(step: watch.step, of: watch.steps, color: color, base: base)
                        .padding(.top, base * 0.25)
                }
            }
        }
    }

    /// Segments for each stage, filled up to the current one.
    private func stepsBar(step: Int, of steps: Int, color: Color, base: CGFloat) -> some View {
        HStack(spacing: base * 0.2) {
            ForEach(1...steps, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? color : .white.opacity(0.18))
                    .frame(height: base * 0.25)
            }
        }
        .frame(maxWidth: base * 12)
    }

    // MARK: Footer

    private func footer(base: CGFloat) -> some View {
        HStack {
            Text("HELM")
                .font(font(base * 0.8, .heavy))
                .tracking(base * 0.2)
            Spacer()
            if let updated = board?.updated {
                Text("Synced \(updated, format: .relative(presentation: .named))")
                    .font(font(base * 0.8))
            }
        }
        .foregroundStyle(.white.opacity(0.5))
    }

}

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Glass

/// A panel's frame, reported up so the stage can put frosted backdrop behind it.
struct GlassPanel {
    let anchor: Anchor<CGRect>
    let radius: CGFloat
}

struct GlassPanelsKey: PreferenceKey {
    static let defaultValue: [GlassPanel] = []
    static func reduce(value: inout [GlassPanel], nextValue: () -> [GlassPanel]) { value += nextValue() }
}

/// The glass itself: a faint tint, a light sheen, and a bright edge where light
/// catches it. The blur comes from `GlassStage`.
struct GlassSurface: View {
    let radius: CGFloat
    let tint: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(Color.black.opacity(tint))
            shape.fill(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.05), .white.opacity(0.02)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.12), .white.opacity(0.08), .white.opacity(0.3)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
        }
    }
}

extension View {
    func glass(radius: CGFloat, tint: Double) -> some View {
        background(GlassSurface(radius: radius, tint: tint))
            .anchorPreference(key: GlassPanelsKey.self, value: .bounds) { [GlassPanel(anchor: $0, radius: radius)] }
    }
}

/// Backdrop + board, with a blurred copy of the backdrop showing through each
/// glass panel.
struct GlassStage<Backdrop: View>: View {
    let board: Board?
    let t: Double
    let now: Date
    let size: CGSize
    @ViewBuilder let backdrop: () -> Backdrop

    var body: some View {
        let blur = CGFloat(board?.settings.glassBlur ?? HelmSettings().glassBlur)
        ZStack {
            backdrop()
            BoardView(board: board, t: t, now: now, size: size)
                .backgroundPreferenceValue(GlassPanelsKey.self) { panels in
                    if blur > 0.5 {
                        GeometryReader { geo in
                            backdrop()
                                .blur(radius: blur, opaque: true)
                                .saturation(1.25)
                                .mask {
                                    ZStack(alignment: .topLeading) {
                                        ForEach(Array(panels.enumerated()), id: \.offset) { _, panel in
                                            let r = geo[panel.anchor]
                                            RoundedRectangle(cornerRadius: panel.radius, style: .continuous)
                                                .frame(width: r.width, height: r.height)
                                                .offset(x: r.minX, y: r.minY)
                                        }
                                    }
                                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                                }
                        }
                    }
                }
        }
        .frame(width: size.width, height: size.height)
    }
}
