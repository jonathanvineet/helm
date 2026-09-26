import SwiftUI

/// Notes and reminders drawn over the slideshow: every note in the Helm folder
/// tiled as a card, reminders alongside. `t` is seconds since the screensaver started.
struct BoardView: View {
    let board: Board?
    let t: Double
    let now: Date
    let size: CGSize

    var body: some View {
        let W = size.width, H = size.height
        let pad = max(20, W * 0.045)
        let base = max(9, min(W, H * 1.6) * 0.0155)
        let appear = min(1, max(0, t / 1.2))

        ZStack {
            // Soft darkening top and bottom so text reads on any photo.
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                   .init(color: .black.opacity(0.1), location: 0.35),
                                   .init(color: .black.opacity(0.15), location: 0.7),
                                   .init(color: .black.opacity(0.5), location: 1)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: base * 1.6) {
                header(base: base)
                HStack(alignment: .top, spacing: pad * 0.6) {
                    notesGrid(base: base)
                        .frame(width: (W - pad * 2.6) * 0.64, alignment: .topLeading)
                    tasksPanel(base: base)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
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

    // MARK: Header

    private var notes: [BoardNote] { board?.notes ?? [] }

    private func header(base: CGFloat) -> some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: base * 0.3) {
                Text(notes.isEmpty ? "NOTES" : "NOTES · \(notes.count)")
                    .font(.system(size: base * 0.8, weight: .semibold))
                    .tracking(base * 0.12)
                    .foregroundStyle(.white.opacity(0.6))
                Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: base * 2.4, weight: .bold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: base * 2)
            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: base * 3.4, weight: .light))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.5), radius: base * 0.6)
    }

    // MARK: Notes, tiled

    private func notesGrid(base: CGFloat) -> some View {
        GeometryReader { geo in
            let n = notes.count
            let cols = n <= 1 ? 1 : n <= 4 ? 2 : n <= 9 ? 3 : 4
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
        let lineH = base * 1.2 * 1.45
        let fits = max(0, Int((height - base * 1.2 * 2 - base * 2.6 - base * 1.6) / lineH) - 1)
        let shown = Array(note.lines.prefix(fits))
        return VStack(alignment: .leading, spacing: base * 0.35) {
            Text(note.title)
                .font(.system(size: base * 1.9, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .padding(.bottom, base * 0.2)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                if line.isEmpty {
                    Color.clear.frame(height: base * 0.35)
                } else {
                    Text(line)
                        .font(.system(size: base * 1.2))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
            }
            if note.lines.count > shown.count {
                Text("…").font(.system(size: base * 1.2)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            Text("Edited \(note.modified, format: .relative(presentation: .named))")
                .font(.system(size: base * 0.8))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(base * 1.2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(panel(base: base))
    }

    private func emptyNotes(base: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: base * 0.6) {
            Text(board == nil ? "Waiting for Helm Sync" : "No notes yet")
                .font(.system(size: base * 1.9, weight: .bold))
                .foregroundStyle(.white)
            Text(board?.notesError ?? "Notes you put in the Helm folder in the Notes app show up here, one card each. The first line becomes the heading.")
                .font(.system(size: base * 1.2))
                .foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 0)
        }
        .padding(base * 1.4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(panel(base: base))
    }

    // MARK: Reminders: what's left, and what got done today.

    private func tasksPanel(base: CGFloat) -> some View {
        let todo = board?.todo ?? []
        let done = board?.done ?? []
        let total = todo.count + done.count
        return VStack(alignment: .leading, spacing: base * 0.7) {
            HStack(alignment: .firstTextBaseline) {
                Text("TO DO")
                    .font(.system(size: base * 0.8, weight: .semibold))
                    .tracking(base * 0.12)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if total > 0 {
                    Text("\(done.count) of \(total) done today")
                        .font(.system(size: base * 0.85, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            if total > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(Color.green.opacity(0.85))
                            .frame(width: g.size.width * CGFloat(done.count) / CGFloat(total))
                    }
                }
                .frame(height: base * 0.35)
            }

            if let error = board?.remindersError {
                Text(error).font(.system(size: base * 1.05)).foregroundStyle(.orange)
            } else if todo.isEmpty {
                Text("All clear").font(.system(size: base * 1.2, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            }
            ForEach(Array(todo.prefix(7).enumerated()), id: \.offset) { _, task in
                taskRow(task, done: false, base: base)
            }
            if todo.count > 7 {
                Text("+ \(todo.count - 7) more").font(.system(size: base * 0.9)).foregroundStyle(.white.opacity(0.55))
            }

            if !done.isEmpty {
                Text("DONE TODAY")
                    .font(.system(size: base * 0.8, weight: .semibold))
                    .tracking(base * 0.12)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, base * 0.5)
                ForEach(Array(done.prefix(4).enumerated()), id: \.offset) { _, task in
                    taskRow(task, done: true, base: base)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(base * 1.4)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(panel(base: base))
    }

    private func taskRow(_ task: BoardTask, done: Bool, base: CGFloat) -> some View {
        let overdue = !done && (task.due.map { $0 < now } ?? false)
        return HStack(alignment: .firstTextBaseline, spacing: base * 0.7) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: base * 1.1))
                .foregroundStyle(done ? Color.green : overdue ? Color.orange : Color.white.opacity(0.8))
            VStack(alignment: .leading, spacing: base * 0.1) {
                Text(task.title)
                    .font(.system(size: base * 1.15, weight: .medium))
                    .strikethrough(done, color: .white.opacity(0.5))
                    .foregroundStyle(.white.opacity(done ? 0.55 : 0.95))
                    .lineLimit(1)
                Text(meta(task, overdue: overdue))
                    .font(.system(size: base * 0.8))
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

    // MARK: Footer

    private func footer(base: CGFloat) -> some View {
        HStack {
            Text("HELM")
                .font(.system(size: base * 0.8, weight: .heavy))
                .tracking(base * 0.2)
            Spacer()
            if let updated = board?.updated {
                Text("Synced \(updated, format: .relative(presentation: .named))")
                    .font(.system(size: base * 0.8))
            }
        }
        .foregroundStyle(.white.opacity(0.5))
    }

    private func panel(base: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: base * 1.1, style: .continuous)
            .fill(Color.black.opacity(0.42))
            .overlay(RoundedRectangle(cornerRadius: base * 1.1, style: .continuous).stroke(.white.opacity(0.1)))
    }
}
