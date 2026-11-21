import Foundation

/// Where typing goes next, after what was typed in a task
enum NextFocus: Equatable {
    /// Stays in the same task
    case stay
    /// Goes to this task, just opened
    case task(UUID)
    /// Goes to adding a task at the bottom
    case add
}

/// What editing a list on the iPhone does to it. These are plain changes to the list; `AppModel.change` stamps them
/// with the change times a synced list keeps. A list is saved and synced without its empty tasks (`Note.syncable`,
/// in SyncPass.swift), as on the Mac.
extension Note {
    /// The list after a change made here, given `old`, the list before it. A synced list gets change times like the
    /// Mac gives it (`stamped(since:at:)`), with empty tasks left where they are and not counted.
    func stamped(after old: Note, at now: Date) -> Note {
        guard sync != nil else { return self }
        let stamped = syncable.stamped(since: old.syncable, at: now)
        var byID: [UUID: ToDo] = [:]
        for item in stamped.items where byID[item.id] == nil {
            byID[item.id] = item
        }
        var note = self
        note.items = items.map { byID[$0.id] ?? $0 }
        note.sync = stamped.sync
        return note
    }

    var checkedCount: Int { items.filter(\.done).count }

    mutating func toggle(_ task: UUID) {
        guard let index = items.firstIndex(where: { $0.id == task }) else { return }
        items[index].done.toggle()
    }

    /// Adds a task at the bottom for each line typed. Gives back whether there was anything to add.
    @discardableResult
    mutating func add(_ text: String) -> Bool {
        var added = false
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            items.append(ToDo(text: line))
            added = true
        }
        return added
    }

    /// What typing in a task does, where `text` is all of the task's text as typed. A Return, which comes in as a new
    /// line, works like Return in a task on the Mac: the text after it goes to a new task below, so at the end of a
    /// task it opens an empty one; at the very start of a task it opens an empty one above; and in an empty task it
    /// goes on to adding a task at the bottom. A paste of several lines makes a task of each.
    mutating func enter(_ text: String, in task: UUID) -> NextFocus {
        guard let index = items.firstIndex(where: { $0.id == task }) else { return .stay }
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard text.contains("\n") else {
            items[index].text = text
            return .stay
        }
        let was = items[index]
        let lines = text.components(separatedBy: "\n")
        let first = lines[0]
        let rest = Array(lines.dropFirst())
        let blank = { (line: String) in line.trimmingCharacters(in: .whitespaces).isEmpty }

        // Return in an empty task
        if was.isBlank && blank(first) && rest.allSatisfy(blank) {
            items[index].text = ""
            return .add
        }
        // Return at the very start of a task
        if first.isEmpty && rest.count == 1 && rest[0] == was.text {
            let above = ToDo(text: "")
            items.insert(above, at: index)
            return .task(above.id)
        }
        items[index].text = first.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        var at = index + 1
        var next: ToDo?
        for (number, line) in rest.enumerated() {
            let line = line.trimmingCharacters(in: .whitespaces)
            let isLast = number == rest.count - 1
            if line.isEmpty && !isLast { continue }
            // A checked task split in two stays checked, but a new empty task isn't done yet
            let item = ToDo(text: line, done: was.done && !line.isEmpty)
            items.insert(item, at: at)
            at += 1
            next = item
        }
        return next.map { .task($0.id) } ?? .stay
    }

    /// Takes away a task if nothing's typed in it, as when typing leaves it
    mutating func removeBlank(_ task: UUID) {
        items.removeAll { $0.id == task && $0.isBlank }
    }

    mutating func clearChecked() {
        items.removeAll(where: \.done)
    }
}
