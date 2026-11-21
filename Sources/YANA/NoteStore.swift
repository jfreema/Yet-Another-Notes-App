import Foundation

/// The notes, in ~/Library/Application Support/YANA/Notes.json. YANA 1.0 kept a single note in Note.txt, which becomes
/// the first tab. Deleted notes and lists are kept beside it for 30 days, in Recently Deleted.json.
struct NoteStore {
    let folder: URL

    init(folder: URL = NoteStore.defaultFolder) {
        self.folder = folder
    }

    static var defaultFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("YANA", isDirectory: true)
    }

    var file: URL { folder.appendingPathComponent("Notes.json") }
    /// Where 1.0 kept its note
    var oldFile: URL { folder.appendingPathComponent("Note.txt") }

    func load() -> [Note] {
        if let data = try? Data(contentsOf: file) {
            do {
                let notes = try JSONDecoder().decode([Note].self, from: data)
                if !notes.isEmpty { return notes }
            } catch {
                // Keeps a copy, since the next save writes over it
                logger.error("Couldn't read the notes: \(error.localizedDescription, privacy: .public)")
                let copy = folder.appendingPathComponent("Notes (unreadable \(Int(Date().timeIntervalSince1970))).json")
                try? FileManager.default.copyItem(at: file, to: copy)
            }
        }
        let text = (try? String(contentsOf: oldFile, encoding: .utf8)) ?? ""
        return [Note(kind: .text, text: text)]
    }

    func save(_ notes: [Note]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(notes)
            guard data != (try? Data(contentsOf: file)) else { return }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            logger.error("Couldn't save the notes: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Recently Deleted

    /// A note or list whose tab was deleted, and when
    struct DeletedNote: Codable, Equatable {
        var note: Note
        var deleted: Date
    }

    /// How long a deleted note or list can still be put back
    static let deletedKept: TimeInterval = 30 * 24 * 60 * 60
    /// The most that are kept. Past it, the ones deleted longest ago go first.
    static let deletedLimit = 50

    var deletedFile: URL { folder.appendingPathComponent("Recently Deleted.json") }

    /// What was deleted in the last 30 days, latest first. Anything older is gone for good from now on.
    func loadDeleted(now: Date = Date()) -> [DeletedNote] {
        guard let data = try? Data(contentsOf: deletedFile),
              let all = try? JSONDecoder().decode([DeletedNote].self, from: data) else { return [] }
        let kept = all.filter { now.timeIntervalSince($0.deleted) < Self.deletedKept }
            .sorted { $0.deleted > $1.deleted }
        if kept != all { saveDeleted(kept) }
        return kept
    }

    func saveDeleted(_ deleted: [DeletedNote]) {
        do {
            guard !deleted.isEmpty else {
                if FileManager.default.fileExists(atPath: deletedFile.path) {
                    try FileManager.default.removeItem(at: deletedFile)
                }
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(deleted).write(to: deletedFile, options: .atomic)
        } catch {
            logger.error("Couldn't save Recently Deleted: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keeps a note or list whose tab is being deleted, unless there's nothing in it. A synced list is kept as this
    /// Mac had it, and doesn't sync when it's put back.
    func keepDeleted(_ note: Note, at now: Date = Date()) {
        guard !note.isEmpty else { return }
        var note = note
        note.sync = nil
        let deleted = [DeletedNote(note: note, deleted: now)] + loadDeleted(now: now)
        saveDeleted(Array(deleted.prefix(Self.deletedLimit)))
    }
}
