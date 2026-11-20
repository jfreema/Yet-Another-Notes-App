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
    /// The text file it was opened from or last saved to, which Save writes back to
    var file: URL?
    /// How a to-do list syncs with other devices, once it does
    var sync: SyncInfo?

    /// The most tabs you can make. Lists synced from other devices can go past it.
    static let limit = 4

    init(id: UUID = UUID(), kind: Kind, text: String = "", items: [ToDo] = [], file: URL? = nil,
         sync: SyncInfo? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.items = items
        self.file = file
        self.sync = sync
    }

    /// The tab's name: a note's first line, or a list's first task
    var title: String {
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

    /// The note as a to-do list, a task to each line that has something on it. It isn't tied to the note's file, since
    /// saving a list there would change what's in it.
    var asList: Note {
        kind == .list ? self : Note(kind: .list, items: Self.tasks(fromText: text))
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

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && items.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, items, file, sync
    }

    // Anything missing or unknown reads as empty, so a file from another version still opens. Notes from before 1.7
    // get an id here, kept from their next save.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .text
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        items = try container.decodeIfPresent([ToDo].self, forKey: .items) ?? []
        file = try? container.decodeIfPresent(URL.self, forKey: .file)
        sync = try? container.decodeIfPresent(SyncInfo.self, forKey: .sync)
    }

    /// The list with change times for what's different from `before`, an earlier copy of it: a task that's new or edited
    /// is stamped `now`, one that's gone is marked deleted at `now`, and the order is marked changed if it isn't the same.
    /// Only a synced list keeps change times.
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

    init(id: UUID = UUID(), text: String, done: Bool = false, changed: Date? = nil) {
        self.id = id
        self.text = text
        self.done = done
        self.changed = changed
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, done, changed
    }

    /// Whether it shows the same as `other`: the same task, with the same text and check
    func looksLike(_ other: ToDo) -> Bool {
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
        // Splitting a checked task leaves both halves checked, but a new empty task isn't done yet. The first half is
        // still this task.
        var kept = self
        kept.text = before
        return (kept, ToDo(text: after, done: done && !after.isEmpty))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
        changed = try? container.decodeIfPresent(Date.self, forKey: .changed)
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
