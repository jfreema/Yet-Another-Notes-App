import Foundation

/// One of the note window's tabs: free text, or a to-do list
struct Note: Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case list
    }

    var kind: Kind
    var text: String
    var items: [ToDo]
    /// The text file it was opened from or last saved to, which Save writes back to
    var file: URL?

    /// The most tabs the note window holds
    static let limit = 4

    init(kind: Kind, text: String = "", items: [ToDo] = [], file: URL? = nil) {
        self.kind = kind
        self.text = text
        self.items = items
        self.file = file
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
        case kind, text, items, file
    }

    // Anything missing or unknown reads as empty, so a file from another version still opens
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .text
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        items = try container.decodeIfPresent([ToDo].self, forKey: .items) ?? []
        file = try? container.decodeIfPresent(URL.self, forKey: .file)
    }
}

/// A task in a to-do list
struct ToDo: Codable, Equatable {
    var text: String
    var done: Bool

    init(text: String, done: Bool = false) {
        self.text = text
        self.done = done
    }

    private enum CodingKeys: String, CodingKey {
        case text, done
    }

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
        // Splitting a checked task leaves both halves checked, but a new empty task isn't done yet
        return (ToDo(text: before, done: done), ToDo(text: after, done: done && !after.isEmpty))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}
