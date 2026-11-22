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
    /// What syncing remembers between launches, kept away from YANA's own settings
    private let settings = "YANATests." + UUID().uuidString

    private final class Host: SyncHost {
        var notePages: [NotePage]
        /// The devices it was told have started using a folder
        var offered: [(device: DeviceCard, folder: SyncFolder)] = []
        /// How many times it was told a folder stopped or started being readable
        var stateChanges = 0
        /// How many times it was told another device took lists off this Mac
        var tookOffs = 0

        init(_ pages: [NotePage]) {
            notePages = pages
        }

        func syncStateChanged() {
            stateChanges += 1
        }

        func tookOff() {
            tookOffs += 1
        }

        func offer(_ device: DeviceCard, in folder: SyncFolder) {
            offered.append((device, folder))
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
        return reopened(host)
    }

    /// Syncing as it starts when YANA opens, with what it remembered last time and the folder as it is
    private func reopened(_ host: Host) -> ListSync {
        let folder = self.folder
        let sync = ListSync(defaults: UserDefaults(suiteName: settings) ?? .standard)
        sync.folders = { [folder] }
        // So a copy that doesn't match is written every time, and one written over and over shows up
        sync.writeSettles = 0
        // And the folder's devices are looked at on every pass
        sync.devicesLookedEvery = 0
        sync.host = host
        return sync
    }

    /// Another device's card in the folder, as it writes one when it starts using the folder
    private func card(_ device: String, _ name: String) throws {
        try JSONEncoder().encode(DeviceCard(id: device, name: name, seen: earlier)).write(to: folder.card(of: device))
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

    /// The task with this text, to put the cursor in. The row for adding a task isn't one.
    private func field(_ text: String, in view: NSView) -> TaskField? {
        for subview in view.subviews {
            if let row = subview as? ToDoRow {
                if row.field.stringValue == text { return row.field }
            } else if let task = field(text, in: subview) {
                return task
            }
        }
        return nil
    }

    /// Waits for something to come true, for up to twenty seconds
    private func until(_ what: Comment, _ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(done(), what)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: settings)
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

    @Test func syncsWhenSomethingChangesInTheFolder() async throws {
        defer { cleanUp() }
        let milk = ToDo(text: "Milk", changed: earlier)
        let (list, _) = makeList([milk])
        let host = Host([list])
        let sync = try syncing(host)
        // Nothing but a change in the folder makes it sync again in the time this test takes
        sync.readEvery = 3600
        sync.changesGathered = 0.2
        sync.start()
        defer { sync.stop() }
        try await until("its first pass writes this Mac's copy") { (try? mine(list.id))?.items.map(\.text) == ["Milk"] }

        // The other device's change lands in the folder, and shows here without anything asking for a sync
        var oat = milk
        oat.text = "Oat milk"
        oat.changed = Date().addingTimeInterval(60)
        await theirs(list.id, [oat])
        try await until("the other device's change shows") { list.note.items.map(\.text) == ["Oat milk"] }
        try await until("and this Mac's copy has it") { (try? mine(list.id))?.items.map(\.text) == ["Oat milk"] }

        // A list it sends here later does too
        let other = UUID()
        await theirs(other, [ToDo(text: "Tent", changed: earlier)], name: "Camping", named: earlier)
        try await until("a list sent here gets a tab") { host.notePages.count == 2 }
        #expect(host.notePages.last?.note.title == "Camping")
    }

    @Test func aListThisMacLeftStaysGoneTheNextTimeYANAOpens() async throws {
        defer { cleanUp() }
        let id = UUID()
        let milk = ToDo(text: "Milk", changed: earlier)
        await theirs(id, [milk])
        let host = Host([])
        let sync = try syncing(host)
        await sync.pass()
        let page = try #require(host.notePages.first)
        sync.stop(page)
        host.removeSynced(page)
        await sync.pass()
        #expect(try mine(id).devices == [air])

        // An older copy of this Mac's, from before it left, lands over the one saying it left. YANA has been reopened
        // since, and still knows it left: the list stays gone, and its copy says so again.
        let old = SyncedList(device: me, items: [milk], orderChanged: earlier, devices: [me, air], devicesChanged: earlier)
        let wrote = await SyncFiles().write(old, to: folder.copy(of: id, by: me))
        #expect(wrote)
        let later = Host([])
        let again = reopened(later)
        await again.pass()
        #expect(later.notePages.isEmpty)
        #expect(try mine(id).devices == [air])
        #expect(try mine(id).items.isEmpty)
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

    @Test func saysWhenItsFolderCantBeReadAndWhenItLastSynced() async throws {
        defer { cleanUp() }
        let (list, _) = makeList([ToDo(text: "Milk", changed: earlier)])
        let host = Host([list])
        let sync = try syncing(host)
        // A list that doesn't sync has nothing to say
        #expect(sync.state(of: TodoList(items: [])) == nil)
        let started = Date()
        await sync.pass()
        #expect(sync.state(of: list) == .working)
        #expect(sync.state(of: list)?.problem() == nil)
        #expect(host.stateChanges == 1)
        await sync.pass()
        #expect(host.stateChanges == 1)

        // The folder goes, as when a drive is unplugged or iCloud Drive is turned off
        try FileManager.default.removeItem(at: root)
        await sync.pass()
        guard case .stopped(let name, let last)? = sync.state(of: list) else {
            Issue.record("The list should have stopped syncing")
            return
        }
        #expect(name == root.lastPathComponent)
        #expect(try #require(last) >= started)
        #expect(sync.state(of: list)?.problem()?.contains("can't open its sync folder") == true)
        #expect(sync.state(of: list)?.problem()?.contains("It last synced") == true)
        #expect(host.stateChanges == 2)
        // Nothing was written to bring the folder back
        #expect(!FileManager.default.fileExists(atPath: root.path))

        // YANA reopened still knows when the list last synced, to within the minute
        let again = reopened(host)
        await again.pass()
        guard case .stopped(_, let remembered)? = again.state(of: list) else {
            Issue.record("The list should still have stopped syncing")
            return
        }
        #expect(try #require(remembered) >= started.addingTimeInterval(-1))

        // A list whose folder this Mac doesn't use any more says so too
        let (lost, _) = makeList([ToDo(text: "Eggs", changed: earlier)])
        lost.sync?.folder = "another"
        #expect(again.state(of: lost) == .stopped(folder: nil, last: nil))

        // With the folder back, the list syncs again
        let told = host.stateChanges
        try FileManager.default.createDirectory(at: folder.listsFolder, withIntermediateDirectories: true)
        await sync.pass()
        #expect(sync.state(of: list) == .working)
        #expect(host.stateChanges == told + 1)
    }

    @Test func showsTheListsInAFolderAndBringsOneHere() async throws {
        defer { cleanUp() }
        let host = Host([])
        let sync = try syncing(host)
        // A list the other device syncs through the folder, without this Mac
        let id = UUID()
        let milk = ToDo(text: "Milk", changed: earlier), eggs = ToDo(text: "Eggs", done: true, changed: earlier)
        let theirs = SyncedList(device: air, items: [milk, eggs], orderChanged: earlier, devices: [air],
                                devicesChanged: earlier, name: "Groceries", nameChanged: earlier)
        let wrote = await SyncFiles().write(theirs, to: folder.copy(of: id, by: air))
        #expect(wrote)
        try card(air, "MacBook Air")

        // It doesn't come here by itself, since it wasn't sent here
        await sync.pass()
        #expect(host.notePages.isEmpty)
        let lists = await sync.lists(in: folder)
        #expect(lists == [FolderList(id: id, title: "Groceries", tasks: 2, devices: ["MacBook Air"])])
        #expect(lists.first?.detail == "2 tasks, on MacBook Air")

        await sync.join([id], in: folder)
        let page = try #require(host.notePages.first)
        #expect(host.notePages.count == 1)
        #expect(page.id == id)
        #expect(page.note.title == "Groceries")
        #expect(page.note.items.map(\.shown) == ["[ ] Milk", "[x] Eggs"])
        #expect(page.sync.map { Set($0.devices) } == [me, air])

        // This Mac's copy says the list comes here now, later than the other device's say of where it goes
        let copy = try mine(id)
        #expect(Set(copy.devices) == [me, air])
        #expect(copy.devicesChanged > theirs.devicesChanged)
        #expect(copy.items.map(\.text) == ["Milk", "Eggs"])
        #expect(copy.name == "Groceries")
        // So the other device, merging the two, sends it here from now on
        #expect(Set(SyncMerge.merge([theirs, copy], now: Date()).devices) == [me, air])

        // It's a synced list like any other: a change over there shows here, and it isn't offered again
        var oat = milk
        oat.text = "Oat milk"
        oat.changed = Date().addingTimeInterval(60)
        var changed = copy
        changed.device = air
        changed.items = [oat, eggs]
        let wroteAgain = await SyncFiles().write(changed, to: folder.copy(of: id, by: air))
        #expect(wroteAgain)
        await sync.pass()
        #expect(page.note.items.map(\.text) == ["Oat milk", "Eggs"])
        let left = await sync.lists(in: folder)
        #expect(left.isEmpty)
        #expect(host.notePages.count == 1)
    }

    @Test func aListDeletedHereCanBeBroughtBackFromItsFolder() async throws {
        defer { cleanUp() }
        let id = UUID()
        await theirs(id, [ToDo(text: "Milk", changed: earlier)])
        let host = Host([])
        let sync = try syncing(host)
        await sync.pass()
        let page = try #require(host.notePages.first)
        await sync.pass()

        // Its tab is deleted here, so it no longer comes here, and the folder has it to bring back
        sync.stop(page)
        host.removeSynced(page)
        await sync.pass()
        await sync.pass()
        #expect(host.notePages.isEmpty)
        let lists = await sync.lists(in: folder)
        #expect(lists.map(\.id) == [id])

        await sync.join([id], in: folder)
        #expect(host.notePages.map { $0.id } == [id])
        #expect(host.notePages.first?.note.items.map(\.text) == ["Milk"])
        #expect(Set(try mine(id).devices) == [me, air])
        // And it stays
        await sync.pass()
        await sync.pass()
        #expect(host.notePages.count == 1)
    }

    @Test func offersADeviceThatStartsUsingTheFolderTheListsThatSyncThere() async throws {
        defer { cleanUp() }
        let (list, _) = makeList([ToDo(text: "Milk", changed: earlier)])
        let host = Host([list])
        let sync = try syncing(host)
        try card(air, "MacBook Air")
        await sync.pass()
        // Whoever's in the folder at the first look was there already
        #expect(host.offered.isEmpty)

        // An iPhone starts using the folder
        let phone = UUID().uuidString
        try card(phone, "iPhone")
        await sync.pass()
        #expect(host.offered.map { $0.device.name } == ["iPhone"])
        #expect(host.offered.first?.folder == folder)
        #expect(sync.lists(notGoingTo: phone, in: folder).map { $0.id } == [list.id])
        // It's only said once, and YANA reopened doesn't say it again
        await sync.pass()
        await reopened(host).pass()
        #expect(host.offered.count == 1)

        // Sent to it, the list has nothing left to offer
        sync.send(list, to: [air, phone])
        #expect(sync.lists(notGoingTo: phone, in: folder).isEmpty)
        #expect(Set(list.sync?.devices ?? []) == [me, air, phone])

        // A device that the lists here already go to isn't news
        let pad = UUID().uuidString
        list.sync?.devices.append(pad)
        try card(pad, "iPad")
        await sync.pass()
        #expect(host.offered.count == 1)
    }

    // MARK: What a sync folder can't do

    @Test func saysWhichDeviceTookAListOffThisMac() async throws {
        defer { cleanUp() }
        let milk = ToDo(text: "Milk", changed: earlier)
        let (list, _) = makeList([milk])
        let host = Host([list])
        let sync = try syncing(host)
        try card(air, "MacBook Air")
        await theirs(list.id, [milk])
        await sync.pass()
        #expect(sync.takenOff.isEmpty)

        // Unticked for this Mac on the MacBook Air
        let off = SyncedList(device: air, items: [milk], orderChanged: earlier, devices: [air], devicesChanged: Date())
        let wrote = await SyncFiles().write(off, to: folder.copy(of: list.id, by: air))
        #expect(wrote)
        await sync.pass()
        // The tab goes, as it asked, and there's something to say about it
        #expect(host.notePages.isEmpty)
        #expect(host.tookOffs == 1)
        #expect(sync.takenOff == [TakenOff(title: "Milk", by: "MacBook Air", kept: true)])
        let copy = folder.copy(of: list.id, by: me).path
        try await until("this Mac's copy is deleted") { !FileManager.default.fileExists(atPath: copy) }
        // Once, however many passes follow
        await sync.pass()
        #expect(sync.takenOff.count == 1)

        // It's still to be said if YANA is reopened before the note was showing, and not after it's been said
        #expect(reopened(host).takenOff == sync.takenOff)
        sync.saidTakenOff()
        #expect(sync.takenOff.isEmpty)
        #expect(reopened(host).takenOff.isEmpty)
    }

    @Test func aCopyDatedInTheFutureHasNoSay() async throws {
        defer { cleanUp() }
        let milk = ToDo(text: "Milk", changed: earlier)
        let (list, _) = makeList([milk])
        let host = Host([list])
        let sync = try syncing(host)
        // Dated ten days from now, which no clock that's nearly right gives: it takes this Mac off the list, and
        // changes its task
        let later = Date().addingTimeInterval(10 * 24 * 60 * 60)
        let wrong = SyncedList(device: air, items: [ToDo(id: milk.id, text: "Oat milk", changed: later)],
                               orderChanged: later, devices: [air], devicesChanged: later)
        let wrote = await SyncFiles().write(wrong, to: folder.copy(of: list.id, by: air))
        #expect(wrote)
        await sync.pass()
        await sync.pass()
        #expect(host.notePages.count == 1)
        #expect(list.note.items.map(\.text) == ["Milk"])
        #expect(sync.takenOff.isEmpty)
        let copy = try mine(list.id)
        #expect(Set(copy.devices) == [me, air])
        #expect(copy.items.map(\.text) == ["Milk"])
    }

    @Test func thisMacsOwnDatesFromTheFutureBecomeNow() async throws {
        defer { cleanUp() }
        // Changed while this Mac's date was ten days out
        let later = Date().addingTimeInterval(10 * 24 * 60 * 60)
        let (list, _) = makeList([ToDo(text: "Milk", changed: later)])
        list.sync?.devicesChanged = later
        let host = Host([list])
        let sync = try syncing(host)
        await theirs(list.id, [])
        await sync.pass()
        let now = Date()
        let copy = try mine(list.id)
        #expect(copy.items.map(\.text) == ["Milk"])
        #expect(copy.items.allSatisfy { ($0.changed ?? later) <= now })
        #expect(copy.devicesChanged <= now)
        #expect((list.sync?.devicesChanged ?? later) <= now)
        // And the next change here is the later one, as it should be
        list.show([ToDo(id: copy.items[0].id, text: "Oat milk", changed: copy.items[0].changed)])
        await sync.pass()
        let next = try mine(list.id)
        #expect(next.items.map(\.text) == ["Oat milk"])
        #expect((next.items[0].changed ?? .distantPast) > (copy.items[0].changed ?? later))
    }

    @Test func skipsAFileThatIsntWhatItsNameSaysOrIsTooBig() async throws {
        defer { cleanUp() }
        let milk = ToDo(text: "Milk", changed: earlier)
        let (list, _) = makeList([milk])
        let host = Host([list])
        let sync = try syncing(host)
        let soon = Date()

        // In the file named for the MacBook Air, a copy that says it's another device's and takes this Mac off
        let other = UUID().uuidString
        let forged = SyncedList(device: other, items: [], orderChanged: soon, devices: [other], devicesChanged: soon)
        try FileManager.default.createDirectory(at: folder.listFolder(list.id), withIntermediateDirectories: true)
        try forged.encoded().write(to: folder.copy(of: list.id, by: air))
        await sync.pass()
        #expect(host.notePages.count == 1)

        // A copy with more tasks than any list of YANA's, which would be a tab that never finishes drawing
        let many = (0...SyncLimits.tasks).map { ToDo(text: "Task \($0)", changed: soon) }
        let huge = SyncedList(device: air, items: many, orderChanged: soon, devices: [me, air], devicesChanged: soon)
        try huge.encoded().write(to: folder.copy(of: list.id, by: air))
        await sync.pass()
        #expect(list.note.items.map(\.text) == ["Milk"])

        // And a file too big to be a copy at all, which isn't even read
        try Data(count: SyncLimits.copyBytes + 1).write(to: folder.copy(of: list.id, by: air))
        await sync.pass()
        #expect(list.note.items.map(\.text) == ["Milk"])
        #expect(Set(try mine(list.id).devices) == [me, air])

        // The real thing still syncs
        await theirs(list.id, [milk, ToDo(text: "Eggs", changed: soon)])
        await sync.pass()
        #expect(list.note.items.map(\.text) == ["Milk", "Eggs"])
    }

    @Test func takesNoMoreListsThanItHasRoomFor() async throws {
        defer { cleanUp() }
        let host = Host([])
        let sync = try syncing(host)
        // More lists sent here than YANA's own lists ever come to
        for number in 0..<(ListSync.mostTabs + 3) {
            await theirs(UUID(), [ToDo(text: "List \(number)", changed: earlier)])
        }
        await sync.pass()
        #expect(host.notePages.count == ListSync.mostTabs)
        await sync.pass()
        #expect(host.notePages.count == ListSync.mostTabs)
        // Once there's room again, more come
        host.notePages.removeFirst(3)
        await sync.pass()
        #expect(host.notePages.count == ListSync.mostTabs)
    }
}
