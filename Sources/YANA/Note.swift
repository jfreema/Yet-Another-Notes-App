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

    /// The most tabs the note window holds
    static let limit = 4

    init(kind: Kind, text: String = "", items: [ToDo] = []) {
        self.kind = kind
        self.text = text
        self.items = items
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

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && items.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, items
    }

    // Anything missing or unknown reads as empty, so a file from another version still opens
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .text
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        items = try container.decodeIfPresent([ToDo].self, forKey: .items) ?? []
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}
