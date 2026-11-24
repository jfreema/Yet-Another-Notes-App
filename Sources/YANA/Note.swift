import Foundation

/// One of the note window's tabs: free text, or a to-do list
struct Note: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case list
    }

    /// Stays with the tab, so a synced list is the same list on every device
    var id: UUID
    var kind: Kind
    var text: String
    var items: [ToDo]
    /// The name you gave it, if you did. Without one, it's named after what's in it.
    var name: String?
    /// The text file it was opened from or last saved to, which Save writes back to
    var file: URL?
    /// How a to-do list syncs with other devices, once it does
    var sync: SyncInfo?

    /// The most tabs you can make. Lists synced from other devices can go past it.
    static let limit = 4

    init(id: UUID = UUID(), kind: Kind, text: String = "", items: [ToDo] = [], name: String? = nil, file: URL? = nil,
         sync: SyncInfo? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.items = items
        self.name = Self.name(name)
        self.file = file
        self.sync = sync
    }

    /// The tab's name: the name you gave it, else a note's first line or a list's first task
    var title: String {
        name ?? contentsTitle
    }

    /// A name as typed, without spaces around it. Nothing typed is no name.
    static func name(_ typed: String?) -> String? {
        guard let typed = typed?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty else { return nil }
        return typed
    }

    /// What it's named after without a name of its own: a note's first line, or a list's first task
    var contentsTitle: String {
        var first: String?
        switch kind {
        case .text:
            text.enumerateLines { line, stop in
                let line = line.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty {
                    first = line
                    stop = true
                }
            }
        case .list:
            first = items.lazy.map { $0.text.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }
        guard let first else { return kind == .text ? "New Note" : "New List" }
        return String(first.prefix(40))
    }

    /// What goes in a .txt file: a note's text, or a list's tasks one to a line, checked off with [x]
    var plainText: String {
        switch kind {
        case .text: text
        case .list: items.map { "\($0.done ? "[x]" : "[ ]") \($0.text)" }.joined(separator: "\n") + "\n"
        }
    }

    /// The note as a to-do list, a task to each line that has something on it, keeping its name. It isn't tied to the
    /// note's file, since saving a list there would change what's in it.
    var asList: Note {
        kind == .list ? self : Note(kind: .list, items: Self.tasks(fromText: text), name: name)
    }

    /// A task for each line with something on it. A bullet in front ("- ", "* ", "• ") is left off, and a line written
    /// out from a list ("[x] Milk") comes back checked off.
    static func tasks(fromText text: String) -> [ToDo] {
        var tasks: [ToDo] = []
        text.enumerateLines { line, _ in
            var line = Substring(line.trimmingCharacters(in: .whitespaces))
            if let bullet = ["- ", "* ", "+ ", "• "].first(where: { line.hasPrefix($0) }) {
                line = line.dropFirst(bullet.count)
            }
            var done = false
            if line.hasPrefix("[x] ") || line.hasPrefix("[X] ") {
                done = true
                line = line.dropFirst(4)
            } else if line.hasPrefix("[ ] ") {
                line = line.dropFirst(4)
            }
            let task = line.trimmingCharacters(in: .whitespaces)
            if !task.isEmpty { tasks.append(ToDo(text: task, done: done)) }
        }
        return tasks
    }

    /// What a text file opens as: a to-do list when every line with something on it starts "[ ] " or "[x] ", the way a
    /// list is saved, and otherwise a note. Either way it's tied to the file, and Save writes it back the same way.
    static func opened(fromText text: String, file: URL? = nil) -> Note {
        var lines = 0
        var boxes = 0
        text.enumerateLines { line, _ in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            lines += 1
            if ["[ ] ", "[x] ", "[X] "].contains(where: { line.hasPrefix($0) }) { boxes += 1 }
        }
        guard lines > 0, boxes == lines else { return Note(kind: .text, text: text, file: file) }
        return Note(kind: .list, items: tasks(fromText: text), file: file)
    }

    /// A text file's contents: UTF-8 or UTF-16 when it says so, else Windows Latin, which reads anything
    static func text(fromFile data: Data) -> String {
        var text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16) ?? ""
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            text = String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Whether there's nothing in it, not even a name
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && items.isEmpty && name == nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, items, name, file, sync
    }

    // Anything missing or unknown reads as empty, so a file from another version still opens. Notes from before 1.7
    // get an id here, kept from their next save.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .text
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        items = try container.decodeIfPresent([ToDo].self, forKey: .items) ?? []
        name = Self.name(try? container.decodeIfPresent(String.self, forKey: .name))
        file = try? container.decodeIfPresent(URL.self, forKey: .file)
        sync = try? container.decodeIfPresent(SyncInfo.self, forKey: .sync)
    }

    /// The list with change times for what's different from `before`, an earlier copy of it: a task that's new or edited
    /// is stamped `now`, one that's gone is marked deleted at `now`, the order is marked changed if it isn't the same, and
    /// so is the name. A task whose highlight is new or different gets its own time for that. Only a synced list keeps
    /// change times.
    func stamped(since before: Note, at now: Date) -> Note {
        guard var sync else { return self }
        var stamped = self
        var earlier: [UUID: ToDo] = [:]
        for item in before.items where earlier[item.id] == nil {
            earlier[item.id] = item
        }
        stamped.items = items.map { item in
            var item = item
            if let old = earlier[item.id], old.text == item.text, old.done == item.done {
                item.changed = old.changed ?? item.changed ?? now
            } else {
                item.changed = now
            }
            // Its highlight has a time of its own, so a change to it and a change to the words on another device both
            // stand
            if let old = earlier[item.id] {
                item.highlightChanged = old.highlight == item.highlight
                    ? old.highlightChanged ?? item.highlightChanged : now
            } else if item.highlight != nil {
                item.highlightChanged = now
            }
            // Back again, say by Undo
            sync.deleted[item.id.uuidString] = nil
            return item
        }
        let ids = Set(items.map(\.id))
        for old in before.items where !ids.contains(old.id) {
            sync.deleted[old.id.uuidString] = now
        }
        if items.map(\.id) != before.items.map(\.id) {
            sync.orderChanged = now
        }
        if name != before.name {
            sync.nameChanged = now
        }
        stamped.sync = sync
        return stamped
    }
}

/// A task in a to-do list
struct ToDo: Codable, Equatable, Sendable {
    /// Stays with the task as it's edited and moved, so syncing can tell which task is which
    var id: UUID
    var text: String
    var done: Bool
    /// When its text or check last changed, kept once its list syncs. The latest change wins when two devices differ.
    var changed: Date?
    /// The highlighter color its line is shaded with, if it has one
    var highlight: Highlight?
    /// When its highlight was last given, changed or taken off, kept once its list syncs. The latest one wins, apart
    /// from the text and check. A copy without it, such as one from a version before highlights, never changes one.
    var highlightChanged: Date?

    init(id: UUID = UUID(), text: String, done: Bool = false, changed: Date? = nil, highlight: Highlight? = nil,
         highlightChanged: Date? = nil) {
        self.id = id
        self.text = text
        self.done = done
        self.changed = changed
        self.highlight = highlight
        self.highlightChanged = highlightChanged
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, done, changed, highlight, highlightChanged
    }

    /// Whether it shows the same as `other`: the same task, with the same text, check and highlight
    func looksLike(_ other: ToDo) -> Bool {
        readsLike(other) && highlight == other.highlight
    }

    /// Whether it says the same as `other`: the same task, with the same text and check, highlighted alike or not
    func readsLike(_ other: ToDo) -> Bool {
        id == other.id && text == other.text && done == other.done
    }

    /// Whether nothing's typed in it yet. An empty task isn't saved or synced: it's one just opened to type in, or one
    /// emptied to delete it.
    var isBlank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Return in this task, with `selection` (a range of its text, counted like a text field counts) selected: the text
    /// before the selection stays in this task and the text after it becomes a new task below, so at the end of a task
    /// Return opens an empty one. Nil at the very start of the task, where Return opens an empty task above it instead.
    func split(at selection: NSRange) -> (kept: ToDo, below: ToDo)? {
        let text = self.text as NSString
        let start = min(selection.location, text.length)
        let end = min(max(NSMaxRange(selection), start), text.length)
        let before = text.substring(to: start).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let after = text.substring(from: end).replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        guard !before.isEmpty else { return nil }
        // Splitting a checked or highlighted task leaves both halves that way, but a new empty task isn't done or
        // highlighted yet. The first half is still this task.
        var kept = self
        kept.text = before
        return (kept, ToDo(text: after, done: done && !after.isEmpty, highlight: after.isEmpty ? nil : highlight))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
        changed = try? container.decodeIfPresent(Date.self, forKey: .changed)
        // A color from a later version that this one doesn't have reads as none
        highlight = try? container.decodeIfPresent(Highlight.self, forKey: .highlight)
        highlightChanged = try? container.decodeIfPresent(Date.self, forKey: .highlightChanged)
    }
}

/// A highlighter color, which shades a task's whole line. The Mac and the iPhone show the same colors, from these
/// numbers: see-through in light and dark mode, so they sit on the usual background either way, and solid on a sticky
/// note, whose yellow would muddy them.
enum Highlight: String, Codable, CaseIterable, Sendable {
    // Around the color wheel from yellow, the usual highlighter
    case yellow, green, blue, purple, pink, orange

    /// What it's called in menus
    var name: String { rawValue.capitalized }

    /// sRGB red, green and blue from 0 to 1, and how opaque it is
    struct Shade: Equatable, Sendable {
        var red, green, blue, alpha: Double

        init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
            self.red = red / 255
            self.green = green / 255
            self.blue = blue / 255
            self.alpha = alpha
        }
    }

    /// Over the white of light mode
    var light: Shade {
        switch self {
        case .yellow: Shade(255, 224, 0, 0.5)
        case .green: Shade(100, 215, 60, 0.38)
        case .blue: Shade(60, 170, 255, 0.32)
        case .purple: Shade(170, 90, 230, 0.28)
        case .pink: Shade(255, 60, 150, 0.28)
        case .orange: Shade(255, 150, 0, 0.4)
        }
    }

    /// Over the near black of dark mode
    var dark: Shade {
        switch self {
        case .yellow: Shade(255, 214, 10, 0.4)
        case .green: Shade(60, 200, 80, 0.36)
        case .blue: Shade(64, 156, 255, 0.38)
        case .purple: Shade(175, 90, 235, 0.4)
        case .pink: Shade(255, 55, 140, 0.36)
        case .orange: Shade(255, 140, 0, 0.4)
        }
    }

    /// On a sticky note's yellow, solid
    var sticky: Shade {
        switch self {
        case .yellow: Shade(255, 216, 50)
        case .green: Shade(186, 232, 160)
        case .blue: Shade(170, 214, 250)
        case .purple: Shade(222, 196, 245)
        case .pink: Shade(255, 186, 214)
        case .orange: Shade(255, 196, 120)
        }
    }
}

extension Array where Element == ToDo {
    /// Whether the two lists show the same tasks in the same order
    func looksLike(_ other: [ToDo]) -> Bool {
        count == other.count && zip(self, other).allSatisfy { $0.looksLike($1) }
    }

    /// What a synced list shows once other devices' changes are merged in, where `self` is what it shows now: the
    /// `merged` tasks, with this list's empty tasks put back in, since those aren't synced. Each stays after the task
    /// it follows now.
    func showing(_ merged: [ToDo]) -> [ToDo] {
        var shown: [ToDo] = []
        var ids: Set<UUID> = []
        for item in merged where ids.insert(item.id).inserted {
            shown.append(item)
        }
        for (index, item) in enumerated() where item.isBlank && !ids.contains(item.id) {
            let above = self[..<index].last { ids.contains($0.id) }
            let place = above.flatMap { above in shown.firstIndex { $0.id == above.id } }.map { $0 + 1 } ?? 0
            shown.insert(item, at: place)
            ids.insert(item.id)
        }
        return shown
    }
}
