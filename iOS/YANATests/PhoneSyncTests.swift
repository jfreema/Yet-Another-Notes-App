import Foundation
import Testing
@testable import YANA

/// Syncs this iPhone's lists through a real folder, with a Mac's copies written by hand the way YANA on the Mac
/// writes them (SyncedList, from the same SyncFormat.swift)
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PhoneSyncTests {
    let root: URL
    let model: AppModel
    let mac = UUID().uuidString
    let earlier = Date(timeIntervalSinceNow: -60)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folderURL = root.appendingPathComponent("YANA Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "YANATests-" + UUID().uuidString))
        model = AppModel(storage: root.appendingPathComponent("Lists.json"), defaults: defaults)
        try model.addFolder(folderURL)
        model.sync.writeSettles = 0
    }

    var folder: OpenFolder { model.openFolders()[0] }

    func writeMacCopy(of list: UUID, _ copy: SyncedList) throws {
        let file = folder.copy(of: list, by: copy.device)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copy.encoded().write(to: file)
    }

    func myCopy(of list: UUID) throws -> SyncedList {
        try JSONDecoder().decode(SyncedList.self, from: Data(contentsOf: folder.copy(of: list, by: model.device)))
    }

    /// A list the Mac sends to this iPhone: Milk, and Eggs checked off
    func sentFromMac() async throws -> (list: UUID, milk: UUID, eggs: UUID) {
        let list = UUID()
        let milk = ToDo(text: "Milk", changed: earlier)
        let eggs = ToDo(text: "Eggs", done: true, changed: earlier)
        try writeMacCopy(of: list, SyncedList(device: mac, items: [milk, eggs], orderChanged: earlier,
                                              devices: [mac, model.device], devicesChanged: earlier))
        await model.sync.flush()
        return (list, milk.id, eggs.id)
    }

    @Test func addsThisIPhoneToTheFolder() async throws {
        model.rename("My iPhone")
        await model.sync.flush()
        let data = try Data(contentsOf: folder.card(of: model.device))
        let card = try JSONDecoder().decode(DeviceCard.self, from: data)
        #expect(card.name == "My iPhone")
    }

    @Test func picksUpAListTheMacSendsHere() async throws {
        let sent = try await sentFromMac()
        let here = try #require(model.list(sent.list))
        #expect(here.items.map(\.text) == ["Milk", "Eggs"])
        #expect(here.items.map(\.done) == [false, true])
        #expect(here.sync?.devices == [mac, model.device])
        // And says so in its own copy, which is what the Mac's "Last heard from" goes by
        #expect(try myCopy(of: sent.list).items.map(\.text) == ["Milk", "Eggs"])
    }

    @Test func leavesOutListsNotSentHere() async throws {
        try writeMacCopy(of: UUID(), SyncedList(device: mac, items: [ToDo(text: "Work", changed: earlier)],
                                                orderChanged: earlier, devices: [mac], devicesChanged: earlier))
        await model.sync.flush()
        #expect(model.lists.isEmpty)
    }

    @Test func changesHereGoToTheFolder() async throws {
        let sent = try await sentFromMac()
        model.toggle(sent.milk, in: sent.list)
        _ = model.enter("Milk, 2%", in: sent.milk, of: sent.list)
        model.deleteTasks(at: [1], in: sent.list)
        await model.sync.flush()
        let mine = try myCopy(of: sent.list)
        #expect(mine.items.map(\.text) == ["Milk, 2%"])
        #expect(mine.items[0].done)
        #expect((mine.items[0].changed ?? .distantPast) > earlier)
        #expect(mine.deleted[sent.eggs.uuidString] != nil)
    }

    @Test func changesOnTheMacShowHere() async throws {
        let sent = try await sentFromMac()
        let now = Date()
        try writeMacCopy(of: sent.list, SyncedList(
            device: mac,
            items: [ToDo(id: sent.eggs, text: "Brown eggs", done: false, changed: now),
                    ToDo(id: sent.milk, text: "Milk", changed: earlier),
                    ToDo(text: "Bread", changed: now)],
            orderChanged: now, devices: [mac, model.device], devicesChanged: earlier))
        await model.sync.flush()
        let here = try #require(model.list(sent.list))
        #expect(here.items.map(\.text) == ["Brown eggs", "Milk", "Bread"])
        #expect(here.items[0].done == false)
    }

    @Test func emptyTasksStayHere() async throws {
        let sent = try await sentFromMac()
        // Return at the end of Milk opens an empty task below it
        let next = model.enter("Milk\n", in: sent.milk, of: sent.list)
        guard case .task(let empty) = next else {
            Issue.record("Return didn't open a task: \(next)")
            return
        }
        await model.sync.flush()
        #expect(try myCopy(of: sent.list).items.map(\.text) == ["Milk", "Eggs"])
        let here = try #require(model.list(sent.list))
        #expect(here.items.map(\.id) == [sent.milk, empty, sent.eggs])
    }

    @Test func takenOffWhenTheMacUnticksThisIPhone() async throws {
        let sent = try await sentFromMac()
        try writeMacCopy(of: sent.list, SyncedList(device: mac, items: [ToDo(id: sent.milk, text: "Milk", changed: earlier)],
                                                   orderChanged: earlier, devices: [mac], devicesChanged: Date()))
        await model.sync.flush()
        #expect(model.list(sent.list) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.copy(of: sent.list, by: model.device).path))
    }

    @Test func aListDeletedHereStaysOff() async throws {
        let sent = try await sentFromMac()
        model.delete(sent.list)
        await model.sync.flush()
        await model.sync.flush()
        #expect(model.list(sent.list) == nil)
        let mine = try myCopy(of: sent.list)
        #expect(mine.items.isEmpty)
        #expect(!mine.devices.contains(model.device))
        // Until the Mac sends it here again
        try writeMacCopy(of: sent.list, SyncedList(device: mac, items: [ToDo(id: sent.milk, text: "Milk", changed: earlier)],
                                                   orderChanged: earlier, devices: [mac, model.device],
                                                   devicesChanged: Date().addingTimeInterval(5)))
        await model.sync.flush()
        #expect(model.list(sent.list)?.items.map(\.text) == ["Milk"])
    }

    @Test func aListStartedHereGoesToTheMac() async throws {
        let id = model.newList()
        model.add("Bread\nButter", to: id)
        model.startSyncing(id, in: folder.id, to: [mac])
        let list = try #require(model.list(id))
        #expect(list.id != id)
        await model.sync.flush()
        let mine = try myCopy(of: list.id)
        #expect(mine.items.map(\.text) == ["Bread", "Butter"])
        #expect(mine.devices == [model.device, mac])
    }

    @Test func namesGoBothWays() async throws {
        let sent = try await sentFromMac()
        #expect(model.list(sent.list)?.title == "Milk")
        // Named on the Mac
        try writeMacCopy(of: sent.list, SyncedList(
            device: mac, items: [ToDo(id: sent.milk, text: "Milk", changed: earlier),
                                 ToDo(id: sent.eggs, text: "Eggs", done: true, changed: earlier)],
            orderChanged: earlier, devices: [mac, model.device], devicesChanged: earlier, name: "Groceries",
            nameChanged: Date()))
        await model.sync.flush()
        #expect(model.list(sent.list)?.name == "Groceries")
        #expect(model.list(sent.list)?.title == "Groceries")
        // Renamed here
        model.renameList(sent.list, to: " Shopping ")
        await model.sync.flush()
        #expect(model.list(sent.list)?.title == "Shopping")
        let mine = try myCopy(of: sent.list)
        #expect(mine.name == "Shopping")
        #expect(mine.items.map(\.text) == ["Milk", "Eggs"])
        // Nothing typed takes the name off
        model.renameList(sent.list, to: "")
        await model.sync.flush()
        #expect(model.list(sent.list)?.title == "Milk")
        #expect(try myCopy(of: sent.list).name == nil)
    }

    @Test func aNamedListStaysWithNoTasksYet() async throws {
        let id = model.newList()
        model.renameList(id, to: "Packing")
        model.closed(id)
        #expect(model.list(id)?.title == "Packing")
        model.startSyncing(id, in: folder.id, to: [mac])
        let list = try #require(model.list(id))
        await model.sync.flush()
        #expect(try myCopy(of: list.id).name == "Packing")
    }

    @Test func stopSyncingKeepsTheListHere() async throws {
        let sent = try await sentFromMac()
        model.stopSyncing(sent.list)
        await model.sync.flush()
        await model.sync.flush()
        #expect(model.list(sent.list)?.sync == nil)
        #expect(model.list(sent.list)?.items.count == 2)
        let mine = try myCopy(of: sent.list)
        #expect(!mine.devices.contains(model.device))
    }

    @Test func listsAreSavedAndLoadedAgain() async throws {
        let sent = try await sentFromMac()
        let again = AppModel(storage: root.appendingPathComponent("Lists.json"),
                             defaults: try #require(UserDefaults(suiteName: "YANATests-" + UUID().uuidString)))
        #expect(again.list(sent.list)?.items.map(\.text) == ["Milk", "Eggs"])
    }
}

/// Typing in a task, which is how Return makes new tasks
struct TypingTests {
    func list(_ texts: String...) -> Note {
        Note(kind: .list, items: texts.map { ToDo(text: $0) })
    }

    @Test func returnAtTheEndOpensATaskBelow() {
        var note = list("Milk", "Eggs")
        let next = note.enter("Milk\n", in: note.items[0].id)
        #expect(note.items.map(\.text) == ["Milk", "", "Eggs"])
        #expect(next == .task(note.items[1].id))
    }

    @Test func returnInTheMiddleSplitsTheTask() {
        var note = list("Milk and eggs")
        let next = note.enter("Milk\nand eggs", in: note.items[0].id)
        #expect(note.items.map(\.text) == ["Milk", "and eggs"])
        #expect(next == .task(note.items[1].id))
    }

    @Test func returnAtTheStartOpensATaskAbove() {
        var note = list("Milk")
        let milk = note.items[0].id
        let next = note.enter("\nMilk", in: milk)
        #expect(note.items.map(\.text) == ["", "Milk"])
        #expect(note.items[1].id == milk)
        #expect(next == .task(note.items[0].id))
    }

    @Test func returnInAnEmptyTaskGoesToAdding() {
        var note = list("Milk", "")
        let next = note.enter("\n", in: note.items[1].id)
        #expect(next == .add)
        #expect(note.items.map(\.text) == ["Milk", ""])
    }

    @Test func pastingLinesMakesATaskOfEach() {
        var note = list("")
        let next = note.enter("Milk\nEggs\n\nBread", in: note.items[0].id)
        #expect(note.items.map(\.text) == ["Milk", "Eggs", "Bread"])
        #expect(next == .task(note.items[2].id))
    }

    @Test func aCheckedTaskSplitStaysChecked() {
        var note = Note(kind: .list, items: [ToDo(text: "Milk eggs", done: true)])
        _ = note.enter("Milk\neggs", in: note.items[0].id)
        #expect(note.items.map(\.done) == [true, true])
        _ = note.enter("Milk\n", in: note.items[0].id)
        #expect(note.items[1].done == false)
    }

    @Test func emptyTasksArentSyncedOrStamped() {
        let now = Date()
        var synced = list("Milk")
        synced.sync = SyncInfo(folder: "f", devices: ["me"], devicesChanged: now, orderChanged: now, deleted: [:])
        var typed = synced
        _ = typed.enter("Milk\n", in: typed.items[0].id)
        let stamped = typed.stamped(after: synced, at: now.addingTimeInterval(1))
        #expect(stamped.items.count == 2)
        #expect(stamped.syncable.items.count == 1)
        #expect(stamped.sync?.orderChanged == now)
        #expect(stamped.sync?.deleted.isEmpty == true)
    }
}
