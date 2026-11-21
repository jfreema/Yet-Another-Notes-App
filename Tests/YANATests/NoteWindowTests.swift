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
