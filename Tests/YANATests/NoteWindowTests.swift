import AppKit
import Testing
@testable import YANA

/// The real note window, never shown, with its notes kept in a folder of the test's own
@MainActor
struct NoteWindowTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var store: NoteStore { NoteStore(folder: folder) }

    /// The note window as it would open with these notes saved
    private func open(_ notes: [Note]) -> NoteWindowController {
        store.save(notes)
        return NoteWindowController(store: store)
    }

    private func titles(_ controller: NoteWindowController) -> [String] {
        controller.notePages.map { $0.note.title }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func eachTabKeepsItsOwnUndo() throws {
        defer { cleanUp() }
        let controller = open([Note(kind: .list, items: [ToDo(text: "Milk"), ToDo(text: "Eggs", done: true)]),
                               Note(kind: .text, text: "Hi")])
        let list = try #require(controller.notePages[0] as? TodoList)
        let note = controller.notePages[1]
        controller.select(0)
        #expect(controller.window.undoManager === list.undo)
        list.clearChecked()
        #expect(list.note.items.map(\.text) == ["Milk"])

        // On to the note, and a change there
        controller.select(1)
        #expect(controller.window.undoManager === note.undo)
        controller.setName("Ideas", of: note)
        #expect(note.name == "Ideas")

        // Back on the list, Undo still puts its checked task back, and leaves the note alone
        controller.select(0)
        controller.window.undoManager?.undo()
        #expect(list.note.items.map(\.text) == ["Milk", "Eggs"])
        #expect(note.name == "Ideas")

        // And the note's Undo is still its own
        controller.select(1)
        controller.window.undoManager?.undo()
        #expect(note.name == nil)
    }

    @Test func aTabsUndoGoesWithItWhenANoteBecomesAList() throws {
        defer { cleanUp() }
        let controller = open([Note(kind: .text, text: "Milk\nEggs"), Note(kind: .text, text: "Hi")])
        controller.select(0)
        let note = controller.notePages[0]
        controller.convertToList(note)
        let list = try #require(controller.notePages[0] as? TodoList)
        #expect(list.note.items.map(\.text) == ["Milk", "Eggs"])
        #expect(list.undo === note.undo)
        #expect(controller.window.undoManager === note.undo)

        // Undo turns it back into the very note it was, and Redo into the list again
        controller.window.undoManager?.undo()
        #expect(controller.notePages[0] === note)
        #expect(controller.notePages[0].note.text == "Milk\nEggs")
        controller.window.undoManager?.undo()
        #expect(controller.notePages[0] === note)
        controller.window.undoManager?.redo()
        #expect(controller.notePages[0] === list)
        // The other tab's Undo had nothing to do with it
        #expect(!controller.notePages[1].undo.canUndo)
    }

    @Test func aDeletedTabGoesToRecentlyDeletedAndCanBePutBack() throws {
        defer { cleanUp() }
        let groceries = Note(kind: .list, items: [ToDo(text: "Milk", done: true), ToDo(text: "Eggs")], name: "Groceries",
                             sync: SyncInfo(folder: "gone", devices: [ThisDevice.id, "air"], devicesChanged: Date(),
                                            orderChanged: Date(), deleted: [:]))
        let controller = open([groceries, Note(kind: .text, text: "Hi"), Note(kind: .text)])
        controller.select(1)
        controller.discard(controller.notePages[0])
        #expect(titles(controller) == ["Hi", "New Note"])
        let deleted = controller.recentlyDeleted
        #expect(deleted.map { $0.note.title } == ["Groceries"])
        // Kept as this Mac had it, but it won't sync when it's back
        #expect(deleted.first?.note.sync == nil)
        #expect(deleted.first?.note.items.map(\.shown) == ["[x] Milk", "[ ] Eggs"])

        // A tab with nothing in it isn't worth keeping
        controller.discard(controller.notePages[1])
        #expect(titles(controller) == ["Hi"])
        #expect(controller.recentlyDeleted.count == 1)
        // The last tab stays
        controller.discard(controller.notePages[0])
        #expect(titles(controller) == ["Hi"])
        #expect(store.load().shown == [Note(kind: .text, text: "Hi")].shown)

        // Put back, it's a tab again with everything in it, and no longer in Recently Deleted
        let id = try #require(deleted.first?.note.id)
        #expect(controller.putBack(id))
        #expect(titles(controller) == ["Hi", "Groceries"])
        let back = controller.notePages[1].note
        #expect(back.items.map(\.shown) == ["[x] Milk", "[ ] Eggs"])
        #expect(back.id != groceries.id)
        #expect(back.sync == nil)
        #expect(controller.recentlyDeleted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.deletedFile.path))
        #expect(store.load().map(\.title) == ["Hi", "Groceries"])
        // It can't be put back twice
        #expect(!controller.putBack(id))
    }

    @Test func puttingBackNeedsRoomOrAnEmptyNote() throws {
        defer { cleanUp() }
        let controller = open([Note(kind: .text, text: "A"), Note(kind: .text, text: "B"), Note(kind: .text, text: "C"),
                               Note(kind: .text), Note(kind: .list, items: [ToDo(text: "Milk")])])
        controller.discard(controller.notePages[4])
        let id = try #require(controller.recentlyDeleted.first?.note.id)

        // Four tabs already, and the one in front has something in it
        controller.select(0)
        #expect(!controller.putBack(id))
        #expect(controller.recentlyDeleted.count == 1)
        #expect(titles(controller) == ["A", "B", "C", "New Note"])

        // An empty note in front gives up its tab
        controller.select(3)
        #expect(controller.putBack(id))
        #expect(titles(controller) == ["A", "B", "C", "Milk"])
        #expect(controller.recentlyDeleted.isEmpty)
    }

    /// The text view of a text tab
    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for subview in view.subviews {
            if let text = textView(in: subview) { return text }
        }
        return nil
    }

    @Test func typingNamesItsOwnTab() throws {
        defer { cleanUp() }
        let controller = open([Note(kind: .text, text: "Hi"), Note(kind: .list, items: [ToDo(text: "Milk")]),
                               Note(kind: .text, text: "Later")])
        controller.select(0)
        #expect(controller.tabTitles == ["Hi", "Milk", "Later"])
        let page = try #require(controller.notePages[0] as? TextPage)
        let text = try #require(textView(in: page.view))

        // A new first line is the tab's name, as it's typed
        text.insertText("Ideas\n", replacementRange: NSRange(location: 0, length: 0))
        #expect(page.note.text == "Ideas\nHi")
        #expect(controller.tabTitles == ["Ideas", "Milk", "Later"])
        text.insertText(" for the trip", replacementRange: NSRange(location: 5, length: 0))
        #expect(controller.tabTitles == ["Ideas for the trip", "Milk", "Later"])

        // A list's is its first task, and a name given to a tab stays whatever is typed
        let list = try #require(controller.notePages[1] as? TodoList)
        list.show([ToDo(text: "Eggs"), ToDo(text: "Milk")])
        list.onChange?()
        #expect(controller.tabTitles == ["Ideas for the trip", "Eggs", "Later"])
        controller.setName("Trip", of: page)
        text.insertText("More\n", replacementRange: NSRange(location: 0, length: 0))
        #expect(controller.tabTitles == ["Trip", "Eggs", "Later"])
    }

    @Test func aTextTabsNameIsItsNotesTitle() {
        let texts = ["", "Hello", "\n\n  Second line \nThird", "   \n\t", String(repeating: "x", count: 60),
                     "a\r\nb", "\r\rAfter two returns", "\u{2028}After a separator", "  é 😀  \n"]
        for text in texts {
            let page = TextPage(text: text)
            #expect(page.title == page.note.title, "\(text.debugDescription)")
            page.name = "  Named  "
            #expect(page.title == "Named")
            #expect(page.title == page.note.title)
            page.name = "   "
            #expect(page.title == page.note.title, "\(text.debugDescription)")
        }
    }

    @Test func savingWhatsAlreadySavedWritesNothing() throws {
        defer { cleanUp() }
        let notes = [Note(kind: .text, text: "Hi"), Note(kind: .list, items: [ToDo(text: "Milk")])]
        let store = NoteStore(folder: folder)
        func written() throws -> Date? {
            try FileManager.default.attributesOfItem(atPath: store.file.path)[.modificationDate] as? Date
        }
        store.save(notes)
        let first = try written()
        #expect(first != nil)
        store.save(notes)
        #expect(try written() == first)

        // Nor by the store YANA opens with next time, until something changes
        let next = NoteStore(folder: folder)
        var loaded = next.load()
        #expect(loaded == notes)
        next.save(loaded)
        #expect(try written() == first)
        loaded[0].text = "Hi there"
        next.save(loaded)
        #expect(try written() != first)
        #expect(NoteStore(folder: folder).load() == loaded)

        // And a file that went missing is written again
        try FileManager.default.removeItem(at: store.file)
        let fresh = NoteStore(folder: folder)
        fresh.save(loaded)
        #expect(NoteStore(folder: folder).load() == loaded)
    }

    @Test func aListTakenOffThisMacByAnotherDeviceCanBePutBackToo() throws {
        defer { cleanUp() }
        let sync = SyncInfo(folder: "gone", devices: [ThisDevice.id, "air"], devicesChanged: Date(),
                            orderChanged: Date(), deleted: [:])
        let controller = open([Note(kind: .text, text: "Hi"),
                               Note(kind: .list, items: [ToDo(text: "Milk")], name: "Groceries", sync: sync)])
        controller.removeSynced(controller.notePages[1])
        #expect(titles(controller) == ["Hi"])
        #expect(controller.recentlyDeleted.map { $0.note.title } == ["Groceries"])
        controller.emptyRecentlyDeleted()
        #expect(controller.recentlyDeleted.isEmpty)
    }
}
