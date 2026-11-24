import AppKit
import Testing
@testable import YANA

struct SyncTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func task(_ text: String, done: Bool = false, at seconds: TimeInterval = 0) -> ToDo {
        ToDo(text: text, done: done, changed: at(seconds))
    }

    private func copy(_ device: String, _ items: [ToDo], order: TimeInterval = 0, devices: [String] = ["mac", "air"],
                      devicesAt: TimeInterval = 0, deleted: [UUID: TimeInterval] = [:]) -> SyncedList {
        SyncedList(device: device, items: items, orderChanged: at(order), devices: devices, devicesChanged: at(devicesAt),
                   deleted: Dictionary(uniqueKeysWithValues: deleted.map { ($0.key.uuidString, at($0.value)) }))
    }

    private func synced(_ items: [ToDo]) -> Note {
        Note(kind: .list, items: items, sync: SyncInfo(folder: "f", devices: ["mac", "air"], devicesChanged: at(0),
                                                       orderChanged: at(0), deleted: [:]))
    }

    // MARK: Stamping

    @Test func stampsWhatChanged() {
        let milk = task("Milk"), eggs = task("Eggs"), jam = task("Jam")
        let before = synced([milk, eggs, jam])
        var now = before
        now.items[0].done = true
        now.items.remove(at: 2)
        now.items.append(ToDo(text: "Bread"))
        let stamped = now.stamped(since: before, at: at(10))
        #expect(stamped.items.map(\.changed) == [at(10), at(0), at(10)])
        #expect(stamped.sync?.deleted == [jam.id.uuidString: at(10)])
        #expect(stamped.sync?.orderChanged == at(10))
    }

    @Test func leavesAnUnchangedListAlone() {
        let before = synced([task("Milk"), task("Eggs")])
        // A page doesn't keep change times, so they come from the copy before
        var now = before
        now.items = now.items.map { ToDo(id: $0.id, text: $0.text, done: $0.done) }
        #expect(now.stamped(since: before, at: at(10)) == before)
    }

    @Test func stampsAMoveAsAnOrderChange() {
        let before = synced([task("Milk"), task("Eggs")])
        var now = before
        now.items.reverse()
        let stamped = now.stamped(since: before, at: at(10))
        #expect(stamped.sync?.orderChanged == at(10))
        #expect(stamped.items.map(\.changed) == [at(0), at(0)])
    }

    @Test func forgetsADeletionWhenTheTaskComesBack() {
        let milk = task("Milk")
        var before = synced([])
        before.sync?.deleted = [milk.id.uuidString: at(5)]
        var now = before
        now.items = [milk]
        let stamped = now.stamped(since: before, at: at(10))
        #expect(stamped.sync?.deleted == [:])
        #expect(stamped.items.first?.changed == at(10))
    }

    @Test func stampsARename() {
        let before = synced([task("Milk")])
        var now = before
        now.name = "Groceries"
        let stamped = now.stamped(since: before, at: at(10))
        #expect(stamped.sync?.nameChanged == at(10))
        #expect(stamped.sync?.orderChanged == at(0))
        #expect(stamped.items.map(\.changed) == [at(0)])
        // Taking the name off is a change too
        var unnamed = stamped
        unnamed.name = nil
        #expect(unnamed.stamped(since: stamped, at: at(20)).sync?.nameChanged == at(20))
        // And keeping it isn't
        #expect(stamped.stamped(since: stamped, at: at(30)).sync?.nameChanged == at(10))
        #expect(before.stamped(since: before, at: at(30)).sync?.nameChanged == nil)
    }

    @Test func onlyStampsSyncedLists() {
        let before = Note(kind: .list, items: [ToDo(text: "Milk")])
        var now = before
        now.items[0].text = "Oat milk"
        #expect(now.stamped(since: before, at: at(10)) == now)
    }

    // MARK: Merging

    @Test func keepsChangesToDifferentTasks() {
        let milk = task("Milk"), eggs = task("Eggs")
        var mine = [milk, eggs], theirs = [milk, eggs]
        mine[0].done = true
        mine[0].changed = at(10)
        theirs[1].text = "Brown eggs"
        theirs[1].changed = at(20)
        let merged = SyncMerge.merge([copy("mac", mine), copy("air", theirs)], now: at(30))
        #expect(merged.items.map(\.shown) == ["[x] Milk", "[ ] Brown eggs"])
        #expect(merged.device == "mac")
    }

    @Test func takesTheLatestChangeToATask() {
        let milk = task("Milk")
        var mine = milk, theirs = milk
        mine.text = "Oat milk"
        mine.changed = at(20)
        theirs.text = "Skim milk"
        theirs.changed = at(10)
        #expect(SyncMerge.merge([copy("mac", [mine]), copy("air", [theirs])], now: at(30)).items.map(\.text)
            == ["Oat milk"])
        #expect(SyncMerge.merge([copy("air", [theirs]), copy("mac", [mine])], now: at(30)).items.map(\.text)
            == ["Oat milk"])
    }

    @Test func keepsATaskDeletedAfterItsLastChangeDeleted() {
        let milk = task("Milk", at: 5), eggs = task("Eggs", at: 5)
        let mine = copy("mac", [milk, eggs])
        let theirs = copy("air", [eggs], order: 10, deleted: [milk.id: 10])
        let merged = SyncMerge.merge([mine, theirs], now: at(30))
        #expect(merged.items.map(\.text) == ["Eggs"])
        #expect(merged.deleted == [milk.id.uuidString: at(10)])
    }

    @Test func keepsATaskEditedAfterItWasDeleted() {
        var milk = task("Milk", at: 5)
        let theirs = copy("air", [], order: 10, deleted: [milk.id: 10])
        milk.text = "Oat milk"
        milk.changed = at(20)
        let merged = SyncMerge.merge([copy("mac", [milk]), theirs], now: at(30))
        #expect(merged.items.map(\.text) == ["Oat milk"])
    }

    @Test func takesTheLatestOrderAndFitsInNewTasks() {
        let a = task("A"), b = task("B"), c = task("C")
        let added = task("New", at: 15)
        // This Mac added a task after A, then the other device reversed the order
        let mine = copy("mac", [a, added, b, c], order: 15)
        let theirs = copy("air", [c, b, a], order: 20)
        let merged = SyncMerge.merge([mine, theirs], now: at(30))
        #expect(merged.items.map(\.text) == ["C", "B", "A", "New"])
        #expect(merged.orderChanged == at(20))
    }

    @Test func putsANewFirstTaskFirst() {
        let a = task("A"), b = task("B")
        let first = task("First", at: 15)
        let mine = copy("mac", [a, b], order: 20)
        let theirs = copy("air", [first, a, b], order: 15)
        #expect(SyncMerge.merge([mine, theirs], now: at(30)).items.map(\.text) == ["First", "A", "B"])
    }

    @Test func takesTheLatestDevices() {
        let mine = copy("mac", [], devices: ["mac", "air"], devicesAt: 5)
        let theirs = copy("air", [], devices: ["mac", "air", "work"], devicesAt: 10)
        #expect(SyncMerge.merge([mine, theirs], now: at(30)).devices == ["mac", "air", "work"])
    }

    @Test func ignoresADeviceTheListNoLongerGoesTo() {
        let milk = task("Milk", at: 5)
        // The work Mac was taken off the list, and its copy has a task nobody else has
        let mine = copy("mac", [milk], devices: ["mac", "air"], devicesAt: 20)
        let work = copy("work", [milk, task("Old", at: 30)], devices: ["mac", "air", "work"], devicesAt: 10)
        let merged = SyncMerge.merge([mine, work], now: at(40))
        #expect(merged.items.map(\.text) == ["Milk"])
        #expect(merged.devices == ["mac", "air"])
    }

    @Test func aDeviceThatLeftTheListStaysOffIt() {
        let milk = task("Milk", at: 5)
        // The list's tab was deleted on the work Mac, whose copy is now empty and says the list doesn't go there
        let work = copy("work", [], devices: ["mac"], devicesAt: 20)
        let mac = copy("mac", [milk], devices: ["mac", "work"], devicesAt: 10)
        // On the work Mac, which finds the list in the folder, it doesn't come back
        #expect(SyncMerge.merge([work, mac], now: at(30)).devices == ["mac"])
        // And the Mac it came from keeps its tasks
        let merged = SyncMerge.merge([mac, work], now: at(30))
        #expect(merged.devices == ["mac"])
        #expect(merged.items.map(\.text) == ["Milk"])
        // Until it's sent to the work Mac again
        let again = SyncMerge.merge([work, copy("mac", [milk], devices: ["mac", "work"], devicesAt: 40)], now: at(50))
        #expect(again.devices == ["mac", "work"])
        #expect(again.items.map(\.text) == ["Milk"])
    }

    // MARK: Names

    private func named(_ device: String, _ name: String?, at seconds: TimeInterval?) -> SyncedList {
        var list = copy(device, [task("Milk")])
        list.name = name
        list.nameChanged = seconds.map { at($0) }
        return list
    }

    @Test func takesTheLatestName() {
        let merged = SyncMerge.merge([named("mac", "Groceries", at: 5), named("air", "Shopping", at: 7)], now: at(10))
        #expect(merged.name == "Shopping")
        #expect(merged.nameChanged == at(7))
        #expect(merged.device == "mac")
        #expect(SyncMerge.merge([named("mac", "Groceries", at: 8), named("air", "Shopping", at: 7)], now: at(10)).name
                == "Groceries")
        // Taking the name off goes to the others too
        let off = SyncMerge.merge([named("mac", "Groceries", at: 5), named("air", nil, at: 9)], now: at(10))
        #expect(off.name == nil)
        #expect(off.nameChanged == at(9))
    }

    @Test func aCopyFromBeforeNamesDoesntChangeTheName() {
        // Copies from 1.7 have no name and no date for it
        #expect(SyncMerge.merge([named("mac", "Groceries", at: 5), named("air", nil, at: nil)], now: at(10)).name
                == "Groceries")
        let fromOld = SyncMerge.merge([named("mac", nil, at: nil), named("air", "Groceries", at: 5)], now: at(10))
        #expect(fromOld.name == "Groceries")
        #expect(fromOld.nameChanged == at(5))
        // With no dates at all, this device's name stays
        #expect(SyncMerge.merge([named("mac", "Groceries", at: nil), named("air", nil, at: nil)], now: at(10)).name
                == "Groceries")
        #expect(SyncMerge.merge([named("mac", nil, at: nil), named("air", nil, at: nil)], now: at(10)).name == nil)
    }

    @Test func onlyCountsTheNameFromDevicesTheListGoesTo() {
        var gone = named("old", "Old name", at: 9)
        gone.devices = ["mac", "air", "old"]
        let merged = SyncMerge.merge([named("mac", "Groceries", at: 5), gone], now: at(10))
        #expect(merged.name == "Groceries")
    }

    @Test func takesTheNameFromAMergedCopy() {
        var note = synced([task("Milk")])
        note.name = "Old"
        var list = SyncedList(note, device: "mac")!
        list.name = "Groceries"
        list.nameChanged = at(5)
        let adopted = note.adopting(list)
        #expect(adopted.name == "Groceries")
        #expect(adopted.title == "Groceries")
        #expect(adopted.sync?.nameChanged == at(5))
        list.name = nil
        #expect(note.adopting(list).name == nil)
        #expect(note.adopting(list).title == "Milk")
    }

    // MARK: Highlights

    private func colored(_ item: ToDo, _ color: Highlight?, at seconds: TimeInterval?) -> ToDo {
        var item = item
        item.highlight = color
        item.highlightChanged = seconds.map { at($0) }
        return item
    }

    @Test func stampsAHighlight() {
        let milk = task("Milk"), eggs = task("Eggs")
        let before = synced([milk, eggs])
        var now = before
        now.items[0].highlight = .yellow
        let stamped = now.stamped(since: before, at: at(10))
        #expect(stamped.items[0].highlightChanged == at(10))
        // Coloring a task isn't a change to its words or the order
        #expect(stamped.items.map(\.changed) == [at(0), at(0)])
        #expect(stamped.items[1].highlightChanged == nil)
        #expect(stamped.sync?.orderChanged == at(0))
        // Nor is it undone by a page that keeps no times
        var page = stamped
        page.items = page.items.map { ToDo(id: $0.id, text: $0.text, done: $0.done, highlight: $0.highlight) }
        #expect(page.stamped(since: stamped, at: at(20)) == stamped)
        // Taking it off is a change too, and keeps when
        var off = stamped
        off.items[0].highlight = nil
        let unstamped = off.stamped(since: stamped, at: at(30))
        #expect(unstamped.items[0].highlight == nil)
        #expect(unstamped.items[0].highlightChanged == at(30))
        // A new task that's highlighted, like the second half of one split in two, is dated now
        var split = stamped
        split.items.append(ToDo(text: "Bread", highlight: .green))
        #expect(split.stamped(since: stamped, at: at(40)).items[2].highlightChanged == at(40))
    }

    @Test func takesTheLatestHighlight() {
        let milk = task("Milk")
        let merged = SyncMerge.merge([copy("mac", [colored(milk, .yellow, at: 5)]),
                                      copy("air", [colored(milk, .blue, at: 7)])], now: at(10))
        #expect(merged.items.map(\.highlight) == [.blue])
        #expect(merged.items.map(\.highlightChanged) == [at(7)])
        // Taken off later, it's off
        let off = SyncMerge.merge([copy("mac", [colored(milk, .yellow, at: 5)]),
                                   copy("air", [colored(milk, nil, at: 9)])], now: at(10))
        #expect(off.items.map(\.highlight) == [nil])
        // A tie goes to this device
        #expect(SyncMerge.merge([copy("mac", [colored(milk, .pink, at: 5)]),
                                 copy("air", [colored(milk, .blue, at: 5)])], now: at(10)).items[0].highlight == .pink)
    }

    @Test func keepsAHighlightAndAnEditFromDifferentDevices() {
        let milk = task("Milk")
        // Colored on this Mac, and its words changed later on the other
        var edited = milk
        edited.text = "Oat milk"
        edited.changed = at(8)
        let merged = SyncMerge.merge([copy("mac", [colored(milk, .green, at: 6)]), copy("air", [edited])], now: at(10))
        #expect(merged.items.map(\.text) == ["Oat milk"])
        #expect(merged.items.map(\.highlight) == [.green])
        #expect(merged.items.map(\.highlightChanged) == [at(6)])
        // And the other way round
        let back = SyncMerge.merge([copy("air", [edited]), copy("mac", [colored(milk, .green, at: 6)])], now: at(10))
        #expect(back.items.map(\.text) == ["Oat milk"])
        #expect(back.items.map(\.highlight) == [.green])
    }

    @Test func aCopyFromBeforeHighlightsDoesntTakeOneOff() {
        // A version before highlights writes its copy without them, even after changing the task's words
        let milk = task("Milk")
        var old = milk
        old.text = "Milk, 2 pints"
        old.changed = at(9)
        let merged = SyncMerge.merge([copy("mac", [colored(milk, .orange, at: 5)]), copy("air", [old])], now: at(10))
        #expect(merged.items.map(\.text) == ["Milk, 2 pints"])
        #expect(merged.items.map(\.highlight) == [.orange])
        // Nor from a device that has highlights but never dated this one
        let air = SyncMerge.merge([copy("air", [old]), copy("mac", [colored(milk, .orange, at: 5)])], now: at(10))
        #expect(air.items.map(\.highlight) == [.orange])
    }

    @Test func aHighlightDatedFarAheadHasNoSay() {
        let milk = task("Milk")
        let ahead = SyncMerge.clockSlack + 100
        // Another device's: it loses to one that could be right
        let theirs = SyncMerge.merge([copy("mac", [colored(milk, .yellow, at: 5)]),
                                      copy("air", [colored(milk, .blue, at: ahead)])], now: at(10))
        #expect(theirs.items.map(\.highlight) == [.yellow])
        // This device's own is dated now
        let mine = SyncMerge.merge([copy("mac", [colored(milk, .blue, at: ahead)]),
                                    copy("air", [colored(milk, .yellow, at: 5)])], now: at(10))
        #expect(mine.items.map(\.highlight) == [.blue])
        #expect(mine.items.map(\.highlightChanged) == [at(10)])
    }

    @Test func aDeletedTaskStaysDeletedThoughItWasHighlighted() {
        let milk = task("Milk")
        let merged = SyncMerge.merge([copy("mac", [colored(milk, .pink, at: 5)]),
                                      copy("air", [], deleted: [milk.id: 7])], now: at(10))
        #expect(merged.items.isEmpty)
    }

    @Test func aListStartingToSyncDatesItsHighlights() {
        let note = Note(kind: .list, items: [ToDo(text: "Milk", highlight: .purple), ToDo(text: "Eggs")])
        let syncing = note.startingToSync(in: "f", from: "mac", to: ["air"], at: at(10))
        #expect(syncing.items.map(\.highlight) == [.purple, nil])
        #expect(syncing.items.map(\.highlightChanged) == [at(10), nil])
    }

    @Test func showsAHighlightFromAnotherDevice() {
        let milk = task("Milk")
        #expect(!milk.looksLike(colored(milk, .yellow, at: 5)))
        #expect(milk.readsLike(colored(milk, .yellow, at: 5)))
    }

    @Test func forgetsOldDeletions() {
        let gone = UUID()
        let mine = copy("mac", [], deleted: [gone: 0])
        let later = at(SyncMerge.deletionsKept + 1)
        #expect(SyncMerge.merge([mine], now: later).deleted.isEmpty)
        #expect(SyncMerge.merge([mine], now: at(10)).deleted == [gone.uuidString: at(0)])
    }

    @Test func mergingTheSameCopiesTwiceChangesNothing() {
        let milk = task("Milk", done: true, at: 3), eggs = task("Eggs", at: 4)
        let once = SyncMerge.merge([copy("mac", [milk], order: 3), copy("air", [eggs, milk], order: 4)], now: at(10))
        let twice = SyncMerge.merge([once, copy("air", [eggs, milk], order: 4)], now: at(10))
        #expect(twice == once)
    }

    @Test func turnsAMergedCopyBackIntoTheList() {
        let note = synced([task("Milk")])
        var list = SyncedList(note, device: "mac")!
        list.items.append(task("Eggs", at: 5))
        list.devices = ["mac"]
        let adopted = note.adopting(list)
        #expect(adopted.items.map(\.text) == ["Milk", "Eggs"])
        #expect(adopted.sync?.devices == ["mac"])
        #expect(adopted.sync?.folder == "f")
        #expect(adopted.id == note.id)
        #expect(SyncedList(Note(kind: .list), device: "mac") == nil)
    }

    // MARK: Showing

    @Test func keepsAnEmptyTaskWhereItIsWhenChangesComeIn() {
        let a = task("A"), b = task("B"), c = task("C")
        // An empty task was just opened under A, when another device deleted B and added a task
        let empty = ToDo(text: "")
        let shown = [a, empty, b, c].showing([a, c, task("New", at: 5)])
        #expect(shown.map(\.text) == ["A", "", "C", "New"])
        #expect(shown[1].id == empty.id)
    }

    @Test func keepsAnEmptyTaskAfterTheTaskItFollows() {
        let a = task("A"), b = task("B"), c = task("C")
        let empty = ToDo(text: " ")
        #expect([empty, a].showing([a]).map(\.text) == [" ", "A"])
        // The task it followed is gone, so it follows the one before that, wherever that went
        #expect([a, b, empty, c].showing([c, a]).map(\.text) == ["C", "A", " "])
        // Two in a row stay in a row
        let other = ToDo(text: "")
        #expect([a, empty, other, b].showing([b, a]).map(\.id) == [b.id, a.id, empty.id, other.id])
    }

    @Test func showsAnotherDevicesChangeToATaskEmptiedHere() {
        var milk = task("Milk")
        let theirs = ToDo(id: milk.id, text: "Oat milk", changed: at(9))
        milk.text = ""
        #expect([milk].showing([theirs]) == [theirs])
        // Each task shows once
        #expect([ToDo]().showing([theirs, theirs]) == [theirs])
    }

    @MainActor @Test func showsOtherDevicesChangesInTheList() {
        let a = task("A"), b = task("B"), c = task("C")
        let list = TodoList(items: [a, b, c])
        // Another device edited B, moved it first, deleted C and added a task
        var edited = b
        edited.text = "B again"
        edited.done = true
        edited.changed = at(5)
        let new = task("New", at: 6)
        list.show([edited, a, new])
        #expect(list.note.items == [edited, a, new])
        #expect(list.hasChecked)
        // The same again changes nothing
        list.show([edited, a, new])
        #expect(list.note.items == [edited, a, new])
        list.show([])
        #expect(list.note.items.isEmpty)
        #expect(!list.isDragging)
    }

    // MARK: Files

    @Test func readsBackWhatItWrites() throws {
        var list = copy("mac", [task("Milk", done: true, at: 1.234567), task("Eggs")], deleted: [UUID(): 2.5])
        let data = try list.encoded()
        // Exactly, or a device would write its copy again and again
        #expect(try JSONDecoder().decode(SyncedList.self, from: data) == list)
        list.name = "Groceries"
        list.nameChanged = at(3.5)
        #expect(try JSONDecoder().decode(SyncedList.self, from: list.encoded()) == list)
        list.items[1].highlight = .green
        list.items[1].highlightChanged = at(4.25)
        #expect(try JSONDecoder().decode(SyncedList.self, from: list.encoded()) == list)
    }

    /// A copy as YANA 1.7 reads and writes it, before lists had names
    private struct CopyBeforeNames: Codable {
        var format: Int
        var device: String
        var items: [ToDo]
        var orderChanged: Date
        var devices: [String]
        var devicesChanged: Date
        var deleted: [String: Date]
    }

    @Test func staysReadableByOlderVersions() throws {
        // An unnamed list's copy is the same as before names
        let unnamed = copy("mac", [task("Milk")])
        let text = try #require(String(data: unnamed.encoded(), encoding: .utf8))
        #expect(!text.contains("name"))
        // A named one still reads in 1.7, which skips the name
        var list = copy("mac", [task("Milk", done: true, at: 1), task("Eggs")], deleted: [UUID(): 2])
        list.name = "Groceries"
        list.nameChanged = at(3)
        let old = try JSONDecoder().decode(CopyBeforeNames.self, from: list.encoded())
        #expect(old.items == list.items)
        #expect(old.devices == list.devices)
        #expect(old.deleted == list.deleted)
        // And what 1.7 writes reads here without a name
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let back = try JSONDecoder().decode(SyncedList.self, from: encoder.encode(old))
        #expect(back.name == nil)
        #expect(back.nameChanged == nil)
        #expect(back.items == list.items)
    }

    /// A task as versions before highlights read and write it
    private struct TaskBeforeHighlights: Codable, Equatable {
        var id: UUID
        var text: String
        var done: Bool
        var changed: Date?
    }

    private struct CopyBeforeHighlights: Codable {
        var format: Int
        var device: String
        var items: [TaskBeforeHighlights]
        var orderChanged: Date
        var devices: [String]
        var devicesChanged: Date
        var deleted: [String: Date]
        var name: String?
        var nameChanged: Date?
    }

    @Test func highlightsStayReadableByOlderVersions() throws {
        // A task without a highlight is written as before
        let plain = copy("mac", [task("Milk")])
        let text = try #require(String(data: plain.encoded(), encoding: .utf8))
        #expect(!text.contains("highlight"))
        // A highlighted one still reads in 1.9, which skips the highlight
        var list = copy("mac", [task("Milk", done: true, at: 1), task("Eggs", at: 2)])
        list.items[0].highlight = .yellow
        list.items[0].highlightChanged = at(3)
        list.name = "Groceries"
        list.nameChanged = at(4)
        let old = try JSONDecoder().decode(CopyBeforeHighlights.self, from: list.encoded())
        #expect(old.items.map(\.text) == ["Milk", "Eggs"])
        #expect(old.items.map(\.changed) == [at(1), at(2)])
        #expect(old.name == "Groceries")
        // And what 1.9 writes reads here without highlights
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let back = try JSONDecoder().decode(SyncedList.self, from: encoder.encode(old))
        #expect(back.items.map(\.highlight) == [nil, nil])
        #expect(back.items.map(\.text) == ["Milk", "Eggs"])
        // A color from a later version that this one doesn't know reads as none, and the task still reads
        let later = Data(#"{"id":"\#(UUID().uuidString)","text":"Milk","done":false,"highlight":"teal"}"#.utf8)
        let task = try JSONDecoder().decode(ToDo.self, from: later)
        #expect(task.text == "Milk")
        #expect(task.highlight == nil)
    }

    @Test func readsTheDevicesCopiesFromAFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = SyncFolder(id: "here", url: root)
        let files = SyncFiles()
        let id = UUID()
        let mac = UUID().uuidString, air = UUID().uuidString
        await files.write(copy(mac, [task("Milk")]), to: folder.copy(of: id, by: mac))
        await files.write(copy(air, [task("Eggs")]), to: folder.copy(of: id, by: air))
        // A copy a sync service made is left alone
        try Data("{}".utf8).write(to: folder.listFolder(id).appendingPathComponent("\(air) 2.json"))

        let found = await files.read([folder, SyncFolder(id: "gone", url: root.appendingPathComponent("nope"))])
        let copies = try #require(found["here"]?[id])
        #expect(Set(copies.map(\.device)) == [mac, air])
        #expect(found["gone"] == nil)
        #expect(folder.canBeRead)
        #expect(!SyncFolder(id: "gone", url: root.appendingPathComponent("nope")).canBeRead)

        await files.register(DeviceCard(id: mac, name: "Daedalus-22", seen: at(0)), in: [folder])
        #expect(folder.devices().map(\.name) == ["Daedalus-22"])
    }

    @Test func readsACopyThatChangedThoughItsDateDidnt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = SyncFolder(id: "here", url: root)
        let files = SyncFiles()
        let id = UUID()
        let air = UUID().uuidString
        let file = folder.copy(of: id, by: air)
        // A sync service may keep dates only to the second, so two changes in a second have the same one
        let date = [FileAttributeKey.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)]

        let wroteFirst = await files.write(copy(air, [task("Milk")]), to: file)
        #expect(wroteFirst)
        try FileManager.default.setAttributes(date, ofItemAtPath: file.path)
        let first = await files.read([folder])
        #expect(first["here"]?[id]?.first?.items.map(\.text) == ["Milk"])

        let wroteSecond = await files.write(copy(air, [task("Oat milk")]), to: file)
        #expect(wroteSecond)
        try FileManager.default.setAttributes(date, ofItemAtPath: file.path)
        let second = await files.read([folder])
        #expect(second["here"]?[id]?.first?.items.map(\.text) == ["Oat milk"])

        // And one that can't be written says so
        let nowhere = URL(fileURLWithPath: "/dev/null/lists/\(id)/\(air).json")
        let wroteNowhere = await files.write(copy(air, []), to: nowhere)
        #expect(!wroteNowhere)
    }
}
