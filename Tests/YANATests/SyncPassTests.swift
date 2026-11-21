import Foundation
import Testing
@testable import YANA

/// A pass of syncing as both apps work it out: what was read from a folder, plus what's on this device, gives what to
/// show, add, take away, write and delete. No files and no screens, so these cover the Mac and the iPhone at once.
struct SyncPassTests {
    private let me = "me"
    private let air = "air"
    private let folder = "here"
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func task(_ text: String, done: Bool = false, at seconds: TimeInterval = 0) -> ToDo {
        ToDo(text: text, done: done, changed: at(seconds))
    }

    /// A list on this device that syncs with the other one
    private func list(_ items: [ToDo], name: String? = nil, devices: [String]? = nil) -> Note {
        Note(kind: .list, items: items, name: name,
             sync: SyncInfo(folder: folder, devices: devices ?? [me, air], devicesChanged: start, orderChanged: start,
                            deleted: [:]))
    }

    /// A device's copy of a list, as it would write it
    private func copy(_ device: String, _ items: [ToDo], devices: [String]? = nil, devicesChanged: TimeInterval = 0,
                      order: TimeInterval = 0, name: String? = nil, named: TimeInterval? = nil) -> SyncedList {
        SyncedList(device: device, items: items, orderChanged: at(order), devices: devices ?? [me, air],
                   devicesChanged: at(devicesChanged), name: name, nameChanged: named.map(at))
    }

    private func run(_ pass: inout SyncPass, _ lists: [Note], found: [UUID: [SyncedList]]?, left: [UUID: Date] = [:],
                     waiting: Set<UUID> = [], also here: [UUID] = [], at seconds: TimeInterval = 100) -> SyncPass.Changes {
        pass.run(lists: lists, here: Set(lists.map(\.id) + here), folders: [folder],
                 found: found.map { [folder: $0] } ?? [:], left: left, waiting: waiting, now: at(seconds))
    }

    // MARK: A list here

    @Test func writesThisDevicesCopyWhenTheFolderDoesntHaveIt() {
        var pass = SyncPass(device: me)
        let local = list([task("Milk"), task("Eggs")])
        let changes = run(&pass, [local], found: [:])
        #expect(changes.merged.isEmpty)
        #expect(changes.added.isEmpty && changes.removed.isEmpty && changes.deletes.isEmpty)
        #expect(changes.writes.count == 1)
        let write = changes.writes.first
        #expect(write?.list == local.id)
        #expect(write?.folder == folder)
        #expect(write?.copy.device == me)
        #expect(write?.copy.items.map(\.text) == ["Milk", "Eggs"])
        #expect(write?.copy.devices == [me, air])
    }

    @Test func aCopyJustWrittenIsGivenAWhileBeforeItsWrittenAgain() {
        var pass = SyncPass(device: me)
        pass.writeSettles = 15
        let local = list([task("Milk")])
        #expect(run(&pass, [local], found: [:], at: 100).writes.count == 1)
        // Not read back yet
        #expect(run(&pass, [local], found: [:], at: 103).writes.isEmpty)
        // Still not there: it's written again
        #expect(run(&pass, [local], found: [:], at: 116).writes.count == 1)
        // Something else to write doesn't wait
        var changed = local
        changed.items.append(task("Eggs", at: 117))
        #expect(run(&pass, [changed], found: [:], at: 118).writes.first?.copy.items.map(\.text) == ["Milk", "Eggs"])
    }

    @Test func nothingIsWrittenOnceTheFolderHasThisDevicesCopy() throws {
        var pass = SyncPass(device: me)
        let milk = task("Milk")
        let local = list([milk])
        let mine = try #require(run(&pass, [local], found: [:]).writes.first?.copy)
        let changes = run(&pass, [local], found: [local.id: [mine, copy(air, [milk])]], at: 200)
        #expect(changes == SyncPass.Changes())
    }

    @Test func showsTheOtherDevicesChangesAndWritesThemBack() throws {
        var pass = SyncPass(device: me)
        let milk = task("Milk"), eggs = task("Eggs")
        let local = list([milk, eggs])
        var brown = eggs
        brown.text = "Brown eggs"
        brown.changed = at(60)
        let changes = run(&pass, [local], found: [local.id: [copy(air, [milk, brown, task("Jam", at: 60)], order: 60)]])
        let merged = try #require(changes.merged.first)
        #expect(merged.looksDifferent)
        #expect(merged.note.id == local.id)
        #expect(merged.note.items.map(\.text) == ["Milk", "Brown eggs", "Jam"])
        #expect(merged.note.sync?.orderChanged == at(60))
        #expect(merged.note.sync?.folder == folder)
        #expect(changes.writes.first?.copy.items.map(\.text) == ["Milk", "Brown eggs", "Jam"])
    }

    @Test func aChangeThatDoesntShowIsStillTakenIn() throws {
        var pass = SyncPass(device: me)
        let milk = task("Milk")
        let local = list([milk])
        // The other device reordered nothing visible, but its copy says the order changed later
        let changes = run(&pass, [local], found: [local.id: [copy(air, [milk], order: 60)]])
        let merged = try #require(changes.merged.first)
        #expect(!merged.looksDifferent)
        #expect(merged.note.sync?.orderChanged == at(60))
        #expect(merged.note.items == local.items)
    }

    @Test func aListThatCantShowChangesJustNowWaits() throws {
        var pass = SyncPass(device: me)
        let milk = task("Milk")
        let local = list([milk])
        let theirs = copy(air, [milk, task("Eggs", at: 60)], order: 60)
        // A task is being dragged: nothing of this list is shown or written
        #expect(run(&pass, [local], found: [local.id: [theirs]], waiting: [local.id]) == SyncPass.Changes())
        // A change that doesn't show doesn't wait
        let quiet = run(&pass, [local], found: [local.id: [copy(air, [milk], order: 60)]], waiting: [local.id])
        #expect(quiet.merged.count == 1)
        #expect(quiet.writes.count == 1)
        // And once the mouse is up, it shows
        let after = run(&pass, [local], found: [local.id: [theirs]])
        #expect(after.merged.first?.note.items.map(\.text) == ["Milk", "Eggs"])
    }

    @Test func emptyTasksStayWhereTheyAreAndArentWritten() throws {
        var pass = SyncPass(device: me)
        let milk = task("Milk"), eggs = task("Eggs")
        let empty = ToDo(text: "")
        let local = list([milk, empty, eggs])
        let changes = run(&pass, [local], found: [local.id: [copy(air, [task("Bread", at: 60), milk, eggs], order: 60)]])
        let merged = try #require(changes.merged.first)
        #expect(merged.note.items.map(\.text) == ["Bread", "Milk", "", "Eggs"])
        #expect(merged.note.items[2].id == empty.id)
        #expect(changes.writes.first?.copy.items.map(\.text) == ["Bread", "Milk", "Eggs"])

        // With nothing new from the other device, an empty task alone changes nothing
        var again = SyncPass(device: me)
        let same = run(&again, [local], found: [local.id: [copy(air, [milk, eggs])]])
        #expect(same.merged.isEmpty)
        #expect(same.writes.first?.copy.items.map(\.text) == ["Milk", "Eggs"])
    }

    @Test func namesComeFromTheLatestCopyToSayWhen() throws {
        var pass = SyncPass(device: me)
        let milk = task("Milk")
        let local = list([milk], name: "Groceries")
        // A copy from before names doesn't change it
        #expect(run(&pass, [local], found: [local.id: [copy(air, [milk])]]).merged.isEmpty)
        // One that says when does
        let changes = run(&pass, [local], found: [local.id: [copy(air, [milk], name: "Shopping", named: 60)]])
        let merged = try #require(changes.merged.first)
        #expect(merged.looksDifferent)
        #expect(merged.note.name == "Shopping")
        #expect(merged.note.sync?.nameChanged == at(60))
    }

    @Test func aFolderThatCouldntBeReadChangesNothing() {
        var pass = SyncPass(device: me)
        let local = list([task("Milk")])
        #expect(run(&pass, [local], found: nil) == SyncPass.Changes())
        // Nor does a folder this device doesn't use any more
        let changes = pass.run(lists: [local], here: [local.id], folders: [], found: [folder: [:]], now: at(100))
        #expect(changes == SyncPass.Changes())
    }

    @Test func listsThatDontSyncAreLeftAlone() {
        var pass = SyncPass(device: me)
        let plain = Note(kind: .list, items: [task("Milk")])
        let note = Note(kind: .text, text: "Hello")
        #expect(run(&pass, [plain, note], found: [:]) == SyncPass.Changes())
    }

    // MARK: Taken off, and sent here

    @Test func takenAwayWhenAnotherDeviceTakesThisOneOffTheList() {
        var pass = SyncPass(device: me)
        let milk = task("Milk")
        let local = list([milk])
        let changes = run(&pass, [local], found: [local.id: [copy(air, [milk], devices: [air], devicesChanged: 60)]])
        #expect(changes.removed == [local.id])
        #expect(changes.deletes == [SyncPass.Delete(list: local.id, folder: folder)])
        #expect(changes.merged.isEmpty && changes.writes.isEmpty && changes.added.isEmpty)
    }

    @Test func addsAListAnotherDeviceSendsHere() throws {
        var pass = SyncPass(device: me)
        let id = UUID()
        let theirs = copy(air, [task("Milk")], name: "Groceries", named: 0)
        let changes = run(&pass, [], found: [id: [theirs]])
        let added = try #require(changes.added.first)
        #expect(changes.added.count == 1)
        #expect(added.id == id)
        #expect(added.kind == .list)
        #expect(added.title == "Groceries")
        #expect(added.items.map(\.text) == ["Milk"])
        #expect(added.sync?.folder == folder)
        #expect(added.sync?.devices == [me, air])
        #expect(added.sync?.nameChanged == at(0))
        // This device's copy is written at once, which is how the other device sees it has the list
        #expect(changes.writes.count == 1)
        #expect(changes.writes.first?.list == id)
        #expect(changes.writes.first?.copy.device == me)
        #expect(changes.writes.first?.copy.items.map(\.text) == ["Milk"])

        // Now that it's here, it isn't added again
        let next = run(&pass, [added], found: [id: [theirs]], at: 101)
        #expect(next.added.isEmpty)
    }

    @Test func leavesOutListsThatDontComeHere() {
        var pass = SyncPass(device: me)
        // Another device's list that isn't sent here, one only this device ever wrote, and one already here
        let elsewhere = UUID(), stale = UUID(), here = UUID()
        let changes = run(&pass, [], found: [
            elsewhere: [copy(air, [task("Milk")], devices: [air])],
            stale: [copy(me, [task("Eggs")])],
            here: [copy(air, [task("Jam")])],
        ], also: [here])
        #expect(changes == SyncPass.Changes())
    }

    @Test func aListInTwoFoldersIsAddedOnce() {
        var pass = SyncPass(device: me)
        let id = UUID()
        let theirs = copy(air, [task("Milk")])
        let changes = pass.run(lists: [], here: [], folders: ["one", "two"],
                               found: ["one": [id: [theirs]], "two": [id: [theirs]]], now: at(100))
        #expect(changes.added.count == 1)
        #expect(changes.added.first?.sync?.folder == "one")
    }

    @Test func aListDeletedHereStaysGone() {
        var pass = SyncPass(device: me)
        let id = UUID()
        let milk = task("Milk")
        // This device left at 60. The other device hasn't heard: its copy still says the list comes here.
        let theirs = copy(air, [milk])
        let mine = copy(me, [milk]).leaving(at: at(60))
        #expect(mine.items.isEmpty)
        #expect(mine.devices == [air])
        #expect(mine.devicesChanged == at(60))

        // With this device's copy saying it left, the list doesn't come back, whether or not the leaving is remembered
        #expect(run(&pass, [], found: [id: [mine, theirs]], left: [id: at(60)]) == SyncPass.Changes())
        #expect(run(&pass, [], found: [id: [mine, theirs]]) == SyncPass.Changes())
        // Nor before that copy has been written
        #expect(run(&pass, [], found: [id: [theirs]], left: [id: at(60)]) == SyncPass.Changes())
    }

    @Test func saysAgainThatItLeftWhenAnOlderCopyLandsLate() throws {
        var pass = SyncPass(device: me)
        let id = UUID()
        let milk = task("Milk")
        // A copy this device wrote before it left has landed over the one saying it left
        let old = copy(me, [milk])
        let changes = run(&pass, [], found: [id: [old, copy(air, [milk])]], left: [id: at(60)])
        #expect(changes.added.isEmpty)
        let write = try #require(changes.writes.first)
        #expect(changes.writes.count == 1)
        #expect(write.list == id)
        #expect(write.copy.items.isEmpty)
        #expect(write.copy.devices == [air])
        #expect(write.copy.devicesChanged == at(60))
    }

    @Test func aListSentHereAgainAfterItWasDeletedComesBack() throws {
        var pass = SyncPass(device: me)
        let id = UUID()
        let milk = task("Milk")
        let mine = copy(me, [milk]).leaving(at: at(60))
        // Ticked for this device again on the other one, later than the leaving
        let theirs = copy(air, [milk], devices: [air, me], devicesChanged: 90)
        let changes = run(&pass, [], found: [id: [mine, theirs]], left: [id: at(60)])
        let added = try #require(changes.added.first)
        #expect(added.id == id)
        #expect(added.sync?.devices == [air, me])
        #expect(changes.writes.first?.copy.items.map(\.text) == ["Milk"])
    }

    // MARK: A folder's lists, and bringing one here

    @Test func showsTheListsInAFolderThatDontComeHere() {
        let pass = SyncPass(device: me)
        let camping = UUID(), movies = UUID(), mine = UUID(), gone = UUID(), here = UUID()
        let lists: [UUID: [SyncedList]] = [
            camping: [copy(air, [task("Tent"), task("Stove")], devices: [air, "mini"], name: "Camping", named: 0)],
            movies: [copy(air, [task("Dune")], devices: [air])],
            // Sent here already, stopped everywhere, and one this device has
            mine: [copy(air, [task("Milk")])],
            gone: [copy(air, [], devices: [])],
            here: [copy(air, [task("Jam")], devices: [air])],
        ]
        let found = pass.lists(in: lists, here: [here], names: [air: "MacBook Air", "mini": "Mac mini"], now: at(100))
        #expect(found.map(\.title) == ["Camping", "Dune"])
        #expect(found.map(\.id) == [camping, movies])
        #expect(found.first?.tasks == 2)
        #expect(found.first?.devices == ["MacBook Air", "Mac mini"])
        #expect(found.last?.detail == "1 task, on MacBook Air")
    }

    @Test func bringingAListHereJoinsItsDevices() throws {
        var pass = SyncPass(device: me)
        let id = UUID()
        // The other device's clock is ahead of this one's
        let theirs = copy(air, [task("Tent")], devices: [air], devicesChanged: 500, name: "Camping", named: 0)
        let joined = pass.joining(id, from: [theirs], in: folder, now: at(100))
        let note = try #require(joined)
        #expect(note.id == id)
        #expect(note.title == "Camping")
        #expect(note.items.map(\.text) == ["Tent"])
        #expect(note.sync?.folder == folder)
        #expect(note.sync?.devices == [air, me])
        #expect(note.sync?.devicesChanged == at(501))

        // Its copy saying so is written on the next pass, and the list stays
        let changes = run(&pass, [note], found: [id: [theirs]])
        #expect(changes.removed.isEmpty)
        #expect(changes.writes.first?.copy.devices == [air, me])

        // One that already comes here, or that nothing syncs any more, can't be brought
        let already = pass.joining(id, from: [copy(air, [task("Tent")])], in: folder, now: at(100))
        let nothing = pass.joining(id, from: [], in: folder, now: at(100))
        #expect(already == nil)
        #expect(nothing == nil)
    }

    // MARK: Starting and stopping

    @Test func startingToSyncGivesANewIdAndStampsEverything() {
        let plain = Note(kind: .list, items: [ToDo(text: "Milk"), ToDo(text: ""), ToDo(text: "Eggs", done: true)],
                         name: "Groceries")
        let note = plain.startingToSync(in: folder, from: me, to: [air], at: at(10))
        #expect(note.id != plain.id)
        #expect(note.name == "Groceries")
        #expect(note.items.map(\.text) == ["Milk", "Eggs"])
        #expect(note.items.allSatisfy { $0.changed == at(10) })
        #expect(note.items.map(\.id) == [plain.items[0].id, plain.items[2].id])
        #expect(note.sync == SyncInfo(folder: folder, devices: [me, air], devicesChanged: at(10), orderChanged: at(10),
                                      deleted: [:], nameChanged: at(10)))
        // Without a name, there's no time for one
        let unnamed = Note(kind: .list, items: [ToDo(text: "Milk")]).startingToSync(in: folder, from: me, to: [],
                                                                                    at: at(10))
        #expect(unnamed.sync?.nameChanged == nil)
        #expect(unnamed.sync?.devices == [me])
    }

    @Test func syncableLeavesOutEmptyTasks() {
        let note = Note(kind: .list, items: [ToDo(text: "Milk"), ToDo(text: "  "), ToDo(text: "")])
        #expect(note.syncable.items.map(\.text) == ["Milk"])
    }

    // MARK: A device that starts using a folder

    @Test func noticesADeviceThatStartsUsingAFolder() {
        let pass = SyncPass(device: me)
        let mine = DeviceCard(id: me, name: "This one", seen: start)
        let mac = DeviceCard(id: air, name: "MacBook Air", seen: start)
        let mini = DeviceCard(id: "mini", name: "Mac mini", seen: start)

        // The first look only remembers who's there, read yet or not
        let first = pass.noticed([mine, mac], listed: [me, air, "late"], before: nil)
        #expect(first.new.isEmpty)
        #expect(Set(first.known) == [me, air, "late"])

        // Nobody new
        let same = pass.noticed([mine, mac], listed: [me, air], before: first.known)
        #expect(same.new.isEmpty)
        #expect(same.known == first.known)

        // A new one is told of once, and this device never is
        let next = pass.noticed([mine, mac, mini], listed: [me, air, "mini"], before: [air])
        #expect(next.new == [mini])
        #expect(next.known == [air, "mini"])
        #expect(pass.noticed([mine, mac, mini], listed: [], before: next.known).new.isEmpty)

        // One listed on the first look whose card comes down later isn't new
        #expect(pass.noticed([DeviceCard(id: "late", name: "iPad", seen: start)], listed: ["late"],
                             before: first.known).new.isEmpty)
    }
}
