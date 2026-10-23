import Foundation
import Testing
@testable import YANA

struct NoteTests {
    @Test func namesANoteByItsFirstLine() {
        #expect(Note(kind: .text, text: "\n  Groceries \nMilk").title == "Groceries")
        #expect(Note(kind: .text, text: " \n").title == "New Note")
    }

    @Test func namesAListByItsFirstTask() {
        #expect(Note(kind: .list, items: [ToDo(text: " "), ToDo(text: "Call Sam")]).title == "Call Sam")
        #expect(Note(kind: .list).title == "New List")
    }

    @Test func readsWhatsMissingAsEmpty() throws {
        let json = #"[{"kind": "list", "items": [{"text": "Milk"}]}, {"text": "Hi"}, {"kind": "drawing"}]"#
        let notes = try JSONDecoder().decode([Note].self, from: Data(json.utf8))
        #expect(notes == [
            Note(kind: .list, items: [ToDo(text: "Milk")]),
            Note(kind: .text, text: "Hi"),
            Note(kind: .text),
        ])
    }
}

struct NoteStoreTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func startsWithTheNoteFromVersion1() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "Buy milk".write(to: folder.appendingPathComponent("Note.txt"), atomically: true, encoding: .utf8)
        #expect(NoteStore(folder: folder).load() == [Note(kind: .text, text: "Buy milk")])
    }

    @Test func savesAndLoads() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(folder: folder)
        #expect(store.load() == [Note(kind: .text)])
        let notes = [
            Note(kind: .text, text: "Buy milk\nCall Sam"),
            Note(kind: .list, items: [ToDo(text: "Milk", done: true), ToDo(text: "Eggs")]),
        ]
        store.save(notes)
        #expect(store.load() == notes)
    }

    @Test func keepsAFileItCantRead() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("nope".utf8).write(to: folder.appendingPathComponent("Notes.json"))
        #expect(NoteStore(folder: folder).load() == [Note(kind: .text)])
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.hasPrefix("Notes (unreadable") })
    }
}
