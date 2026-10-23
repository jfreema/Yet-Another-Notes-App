import Foundation

/// The notes, in ~/Library/Application Support/YANA/Notes.json. YANA 1.0 kept a single note in Note.txt, which becomes
/// the first tab.
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
}
