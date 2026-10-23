import Foundation

/// The note's text, in ~/Library/Application Support/YANA/Note.txt
struct NoteStore {
    let file: URL

    init(file: URL = NoteStore.defaultFile) {
        self.file = file
    }

    static var defaultFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("YANA", isDirectory: true).appendingPathComponent("Note.txt")
    }

    func load() -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    func save(_ text: String) {
        guard text != load() else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Couldn't save the note: \(error.localizedDescription, privacy: .public)")
        }
    }
}
