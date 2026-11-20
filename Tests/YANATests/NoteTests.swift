import Foundation
import Testing
@testable import YANA

/// What a note shows, without the ids that make every note and task different
struct Shown: Equatable {
    var kind: Note.Kind
    var text: String
    var tasks: [String]
    var file: URL?
}

extension ToDo {
    var shown: String { (done ? "[x] " : "[ ] ") + text }
}

extension Note {
    var shown: Shown { Shown(kind: kind, text: text, tasks: items.map(\.shown), file: file) }
}

extension Array where Element == Note {
    var shown: [Shown] { map(\.shown) }
}

struct NoteTests {
    @Test func namesANoteByItsFirstLine() {
        #expect(Note(kind: .text, text: "\n  Groceries \nMilk").title == "Groceries")
        #expect(Note(kind: .text, text: " \n").title == "New Note")
    }

    @Test func namesAListByItsFirstTask() {
        #expect(Note(kind: .list, items: [ToDo(text: " "), ToDo(text: "Call Sam")]).title == "Call Sam")
        #expect(Note(kind: .list).title == "New List")
    }

    @Test func writesAListAsLinesOfText() {
        let list = Note(kind: .list, items: [ToDo(text: "Milk", done: true), ToDo(text: "Eggs")])
        #expect(list.plainText == "[x] Milk\n[ ] Eggs\n")
        #expect(Note(kind: .text, text: "Hi\nthere").plainText == "Hi\nthere")
    }

    @Test func splitsATaskWhereReturnIsPressed() {
        let task = ToDo(text: "Buy milk and eggs", done: true)
        func split(_ location: Int, _ length: Int = 0) -> [String]? {
            task.split(at: NSRange(location: location, length: length)).map { [$0.kept.shown, $0.below.shown] }
        }
        // At the end, an empty task opens below
        #expect(split(17) == ["[x] Buy milk and eggs", "[ ] "])
        // In the middle, the text after the cursor moves down, without the spaces around the break
        #expect(split(9) == ["[x] Buy milk", "[x] and eggs"])
        // A selection is replaced by the break
        #expect(split(3, 9) == ["[x] Buy", "[x] eggs"])
        // At the start, the new task opens above instead
        #expect(split(0) == nil)
        #expect(ToDo(text: "  Milk").split(at: NSRange(location: 2, length: 0)) == nil)
        // The first half is still the same task, and the second a new one
        let halves = task.split(at: NSRange(location: 9, length: 0))
        #expect(halves?.kept.id == task.id)
        #expect(halves?.below.id != task.id)
    }

    @Test func turnsANoteIntoAList() {
        let note = Note(kind: .text, text: "Groceries\n\n  Milk  \n- Eggs\n• Bread\n[x] Butter\n- [ ] Jam\n \t\n",
                        file: URL(fileURLWithPath: "/Users/me/groceries.txt"))
        #expect(note.asList.shown == Note(kind: .list, items: [
            ToDo(text: "Groceries"), ToDo(text: "Milk"), ToDo(text: "Eggs"), ToDo(text: "Bread"),
            ToDo(text: "Butter", done: true), ToDo(text: "Jam"),
        ]).shown)
        #expect(Note(kind: .text, text: " \n").asList.shown == Note(kind: .list).shown)
        let list = Note(kind: .list, items: [ToDo(text: "Milk", done: true), ToDo(text: "Eggs")])
        #expect(list.asList == list)
        // What a list writes to a text file turns back into the same list
        #expect(Note(kind: .text, text: list.plainText).asList.shown == list.shown)
    }

    @Test func opensAFileSavedFromAListAsAList() {
        let file = URL(fileURLWithPath: "/Users/me/groceries.txt")
        let list = Note(kind: .list, items: [ToDo(text: "Milk", done: true), ToDo(text: "Eggs")], file: file)
        // The list comes back, still tied to its file, and saves the same as before
        let opened = Note.opened(fromText: list.plainText, file: file)
        #expect(opened.shown == list.shown)
        #expect(opened.plainText == list.plainText)
        // Blank lines and spaces around a line don't matter
        let spaced = Note.opened(fromText: "\n  [X] Milk\n\n[ ] Eggs  \n")
        #expect(spaced.shown == Note(kind: .list, items: list.items).shown)
    }

    @Test func opensAnyOtherFileAsANote() {
        let file = URL(fileURLWithPath: "/Users/me/notes.txt")
        // One line that isn't a task is enough
        for text in ["Groceries\n[x] Milk\n[ ] Eggs\n", "- Milk\n- Eggs\n", "[x]Milk\n", "Hi\nthere", "", " \n"] {
            #expect(Note.opened(fromText: text, file: file).shown == Note(kind: .text, text: text, file: file).shown)
        }
    }

    @Test func readsTextFilesInAnyEncoding() {
        #expect(Note.text(fromFile: Data("caf\u{e9}\r\nok".utf8)) == "caf\u{e9}\nok")
        #expect(Note.text(fromFile: Data([0xEF, 0xBB, 0xBF]) + Data("Hi".utf8)) == "Hi")
        #expect(Note.text(fromFile: Data([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00])) == "Hi")
        // Not UTF-8, so Windows Latin
        #expect(Note.text(fromFile: Data([0x63, 0x61, 0x66, 0xE9])) == "caf\u{e9}")
    }

    @Test func numbersLines() {
        let text = "one\ntwo\r\nthree\n"
        #expect(LineNumberRuler.lineNumber(at: 0, in: text) == 1)
        #expect(LineNumberRuler.lineNumber(at: 3, in: text) == 1)
        #expect(LineNumberRuler.lineNumber(at: 4, in: text) == 2)
        #expect(LineNumberRuler.lineNumber(at: 9, in: text) == 3)
        #expect(LineNumberRuler.lineNumber(at: (text as NSString).length, in: text) == 4)
        #expect(LineNumberRuler.lineNumber(at: 3, in: "abc") == 1)
        #expect(LineNumberRuler.lineNumber(at: 0, in: "") == 1)
    }

    @Test func widensTheNumbersPastNinetyNine() {
        let look = Look(textSize: 14, sticky: false)
        #expect(look.lineNumberWidth(lines: 0) == look.lineNumberWidth(lines: 99))
        #expect(look.lineNumberWidth(lines: 100) > look.lineNumberWidth(lines: 99))
    }

    @Test func remembersItsFile() throws {
        let note = Note(kind: .text, text: "Hi", file: URL(fileURLWithPath: "/Users/me/top todo.txt"))
        let notes = [note, Note(kind: .text, text: "No file")]
        let data = try JSONEncoder().encode(notes)
        #expect(try JSONDecoder().decode([Note].self, from: data) == notes)
    }

    @Test func readsWhatsMissingAsEmpty() throws {
        let json = #"[{"kind": "list", "items": [{"text": "Milk"}]}, {"text": "Hi"}, {"kind": "drawing"}]"#
        let notes = try JSONDecoder().decode([Note].self, from: Data(json.utf8))
        #expect(notes.shown == [
            Note(kind: .list, items: [ToDo(text: "Milk")]),
            Note(kind: .text, text: "Hi"),
            Note(kind: .text),
        ].shown)
    }

    @Test func givesOldNotesIdsThatStay() throws {
        // Notes.json from before 1.7 has no ids
        let json = #"[{"kind": "list", "items": [{"text": "Milk", "done": true}, {"text": "Eggs"}]}, {"text": "Hi"}]"#
        let notes = try JSONDecoder().decode([Note].self, from: Data(json.utf8))
        #expect(notes[0].id != notes[1].id)
        #expect(notes[0].items[0].id != notes[0].items[1].id)
        #expect(notes[0].items[0].changed == nil)
        #expect(notes[0].sync == nil)
        let again = try JSONDecoder().decode([Note].self, from: JSONEncoder().encode(notes))
        #expect(again == notes)
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
        #expect(NoteStore(folder: folder).load().shown == [Note(kind: .text, text: "Buy milk")].shown)
    }

    @Test func savesAndLoads() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(folder: folder)
        #expect(store.load().shown == [Note(kind: .text)].shown)
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
        #expect(NoteStore(folder: folder).load().shown == [Note(kind: .text)].shown)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.hasPrefix("Notes (unreadable") })
    }
}
