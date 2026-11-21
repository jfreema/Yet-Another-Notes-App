import AppKit
import Testing
@testable import YANA

/// Syncing a real list through a folder, with another device's copies written by hand
@MainActor
struct ListSyncTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var folder: SyncFolder { SyncFolder(id: "here", url: root) }
    private let me = ThisDevice.id
    private let air = UUID().uuidString
    /// Before now, so a change made in the test is the later one
    private let earlier = Date().addingTimeInterval(-3600)

    private final class Host: SyncHost {
        var notePages: [NotePage]

        init(_ pages: [NotePage]) {
            notePages = pages
        }

        func showSynced(_ note: Note, on page: NotePage) {
            (page as? TodoList)?.show(note.items)
            page.name = note.name
            page.sync = note.sync
        }

        func addSynced(_ note: Note) {
            let list = TodoList(items: note.items)
            list.id = note.id
            list.name = note.name
            list.sync = note.sync
            notePages.append(list)
        }

        func removeSynced(_ page: NotePage) {
            notePages.removeAll { $0 === page }
        }
    }

    /// Syncing through the test's folder, which is made the way adding a sync folder makes one. The host has to be kept
    /// by whoever asks, as the note window keeps itself.
    private func syncing(_ host: Host) throws -> ListSync {
        let folder = self.folder
        try FileManager.default.createDirectory(at: folder.devicesFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.listsFolder, withIntermediateDirectories: true)
        let sync = ListSync()
        sync.folders = { [folder] }
        // So a copy that doesn't match is written every time, and one written over and over shows up
        sync.writeSettles = 0
        sync.host = host
        return sync
    }

    /// A list that already syncs with the other device, in a window so its tasks can be edited
    private func makeList(_ items: [ToDo]) -> (list: TodoList, window: NSWindow) {
        let list = TodoList(items: items)
        list.sync = SyncInfo(folder: "here", devices: [me, air], devicesChanged: earlier, orderChanged: earlier,
                             deleted: [:])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = list
        return (list, window)
    }

    /// The other device's copy of a list, as it would write it
    private func theirs(_ list: UUID, _ items: [ToDo], name: String? = nil, named: Date? = nil) async {
        let copy = SyncedList(device: air, items: items, orderChanged: earlier, devices: [me, air],
                              devicesChanged: earlier, name: name, nameChanged: named)
        let wrote = await SyncFiles().write(copy, to: folder.copy(of: list, by: air))
        #expect(wrote)
    }

    /// This Mac's copy of a list, as it is in the folder
    private func mine(_ list: UUID) throws -> SyncedList {
        try JSONDecoder().decode(SyncedList.self, from: Data(contentsOf: folder.copy(of: list, by: me)))
    }

    /// The task with this text, to put the cursor in
    private func field(_ text: String, in view: NSView) -> TaskField? {
        for subview in view.subviews {
            if let task = subview as? TaskField, task.stringValue == text { return task }
            if let task = field(text, in: subview) { return task }
        }
        return nil
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func syncsBothWaysWithTheCursorLeftInATask() async throws {
        defer { cleanUp() }
        let milk = ToDo(text: "Milk", changed: earlier), eggs = ToDo(text: "Eggs", changed: earlier)
        let (list, window) = makeList([milk, eggs])
        let host = Host([list])
        let sync = try syncing(host)
        await sync.pass()
        #expect(try mine(list.id).items.map(\.text) == ["Milk", "Eggs"])

        // The cursor is in a task here, with something typed, when the other device changes another task
        let milkField = try #require(field("Milk", in: list))
        #expect(window.makeFirstResponder(milkField))
        let editor = try #require(milkField.currentEditor() as? NSTextView)
        editor.insertText("!", replacementRange: NSRange(location: 4, length: 0))
        #expect(list.note.items.map(\.text) == ["Milk!", "Eggs"])
        var brown = eggs
        brown.text = "Brown eggs"
        brown.changed = Date().addingTimeInterval(60)
        await theirs(list.id, [milk, brown])
        await sync.pass()

        // Its change shows, what's typed here goes to it, and the cursor is still where it was
        #expect(list.note.items.map(\.text) == ["Milk!", "Brown eggs"])
        #expect(try mine(list.id).items.map(\.text) == ["Milk!", "Brown eggs"])
        #expect(milkField.currentEditor() != nil)
        #expect(milkField.stringValue == "Milk!")

        // When it changes the very task the cursor is in, that task shows as the other device has it
        var oat = milk
        oat.text = "Oat milk"
        oat.changed = Date().addingTimeInterval(120)
        await theirs(list.id, [oat, brown])
        await sync.pass()
        #expect(list.note.items.map(\.text) == ["Oat milk", "Brown eggs"])
        #expect(try mine(list.id).items.map(\.text) == ["Oat milk", "Brown eggs"])
        #expect(milkField.currentEditor() == nil)
        #expect(milkField.stringValue == "Oat milk")

        // And once they agree, nothing more is written
        let written = try FileManager.default.attributesOfItem(atPath: folder.copy(of: list.id, by: me).path)
        await sync.pass()
        let after = try FileManager.default.attributesOfItem(atPath: folder.copy(of: list.id, by: me).path)
        #expect(written[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(host.notePages.count == 1)
    }

    @Test func keepsAnEmptyTaskBeingTypedInWhenChangesComeIn() async throws {
        defer { cleanUp() }
        let milk = ToDo(text: "Milk", changed: earlier), eggs = ToDo(text: "Eggs", changed: earlier)
        // Return in Milk opened an empty task under it
        let (list, window) = makeList([milk, ToDo(text: ""), eggs])
        let host = Host([list])
        let sync = try syncing(host)
        await sync.pass()
        #expect(try mine(list.id).items.map(\.text) == ["Milk", "Eggs"])

        let empty = try #require(field("", in: list))
        #expect(window.makeFirstResponder(empty))
        await theirs(list.id, [ToDo(text: "Bread", changed: Date().addingTimeInterval(60)), milk, eggs])
        await sync.pass()
        #expect(list.note.items.map(\.text) == ["Bread", "Milk", "Eggs"])
        #expect(empty.currentEditor() != nil)

        // What's then typed in it is a new task, under Milk
        (empty.currentEditor() as? NSTextView)?.insertText("Jam", replacementRange: NSRange(location: 0, length: 0))
        await sync.pass()
        #expect(list.note.items.map(\.text) == ["Bread", "Milk", "Jam", "Eggs"])
        #expect(try mine(list.id).items.map(\.text) == ["Bread", "Milk", "Jam", "Eggs"])
        #expect(host.notePages.count == 1)
    }

    @Test func namesGoBothWays() async throws {
        defer { cleanUp() }
        let milk = ToDo(text: "Milk", changed: earlier)
        let (list, _) = makeList([milk])
        let host = Host([list])
        let sync = try syncing(host)
        await theirs(list.id, [milk])
        await sync.pass()
        #expect(try mine(list.id).name == nil)

        // Named here, as Rename… does, then saved
        list.name = "Groceries"
        _ = sync.note(of: list)
        await sync.pass()
        #expect(try mine(list.id).name == "Groceries")
        let named = try #require(try mine(list.id).nameChanged)
        #expect(named > earlier)

        // The other device, on a version from before names, writes its copy without one: the name stays
        await theirs(list.id, [milk])
        await sync.pass()
        #expect(list.note.title == "Groceries")
        #expect(try mine(list.id).name == "Groceries")

        // Renamed on the other device later: it shows here, and this Mac's copy says so too
        await theirs(list.id, [milk], name: "Shopping", named: named.addingTimeInterval(60))
        await sync.pass()
        #expect(list.note.name == "Shopping")
        #expect(list.note.items.map(\.text) == ["Milk"])
        #expect(try mine(list.id).name == "Shopping")

        // Its name taken off there: it's named after its first task again
        await theirs(list.id, [milk], name: nil, named: named.addingTimeInterval(120))
        await sync.pass()
        #expect(list.note.name == nil)
        #expect(list.note.title == "Milk")
    }

    @Test func aListSentHereComesWithItsName() async throws {
        defer { cleanUp() }
        let id = UUID()
        await theirs(id, [ToDo(text: "Milk", changed: earlier)], name: "Groceries", named: earlier)
        let host = Host([])
        let sync = try syncing(host)
        await sync.pass()
        let page = try #require(host.notePages.first)
        #expect(page.note.title == "Groceries")
        #expect(page.sync?.nameChanged == earlier)
    }

    @Test func aNamedListStartsSyncingWithItsName() async throws {
        defer { cleanUp() }
        let list = TodoList(items: [ToDo(text: "Milk")])
        list.name = "Groceries"
        let host = Host([list])
        let sync = try syncing(host)
        sync.start(list, in: folder, to: [air])
        await sync.pass()
        #expect(try mine(list.id).name == "Groceries")
        #expect(try mine(list.id).nameChanged != nil)
        #expect(list.note.name == "Groceries")
    }

    @Test func addsAListAnotherDeviceSendsHereAndKeepsItGoneOnceDeleted() async throws {
        defer { cleanUp() }
        let id = UUID()
        await theirs(id, [ToDo(text: "Milk", changed: earlier)])
        let host = Host([])
        let sync = try syncing(host)
        await sync.pass()
        let page = try #require(host.notePages.first)
        #expect(page.id == id)
        #expect(page.note.items.map(\.text) == ["Milk"])
        #expect(page.sync?.devices == [me, air])
        await sync.pass()
        #expect(try mine(id).items.map(\.text) == ["Milk"])

        // Its tab is deleted here. The other device hasn't heard yet, and its copy still says the list comes here.
        sync.stop(page)
        host.removeSynced(page)
        await sync.pass()
        await sync.pass()
        #expect(host.notePages.isEmpty)
        #expect(try mine(id).devices == [air])
        #expect(try mine(id).items.isEmpty)

        // Nor does it come back the next time YANA opens
        let later = Host([])
        let again = try syncing(later)
        await again.pass()
        #expect(later.notePages.isEmpty)
    }
}
