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

    /// A device's card in a folder, the way YANA on it writes one when it starts using the folder
    func writeCard(_ card: DeviceCard, in folder: OpenFolder? = nil) throws {
        let file = (folder ?? self.folder).card(of: card.id)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(card).write(to: file)
    }

    func texts(_ list: UUID) -> [String] {
        model.list(list)?.items.map(\.text) ?? []
    }

    /// Waits for something that happens a moment later, for up to 20 seconds
    func until(_ what: Comment, _ done: () -> Bool) async throws {
        let giveUp = Date().addingTimeInterval(20)
        while !done() && Date() < giveUp {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(done(), what)
    }

    /// What a list's tasks say in the file the lists are saved in, as YANA would find them the next time it opens
    func saved(_ list: UUID) throws -> [String] {
        let again = AppModel(storage: root.appendingPathComponent("Lists.json"),
                             defaults: try #require(UserDefaults(suiteName: "YANATests-" + UUID().uuidString)))
        return again.list(list)?.items.map(\.text) ?? []
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

    // MARK: Saving and syncing when there's something to save or sync

    @Test func typingIsSavedOnceItPauses() async throws {
        let id = model.newList()
        model.add("Milk", to: id)
        let milk = try #require(model.list(id)?.items.first?.id)
        #expect(try saved(id) == ["Milk"])

        // A character typed shows at once, but the lists aren't written out again for each one
        _ = model.enter("Milk,", in: milk, of: id)
        _ = model.enter("Milk, 2%", in: milk, of: id)
        #expect(texts(id) == ["Milk, 2%"])
        #expect(model.unsaved)
        #expect(try saved(id) == ["Milk"])
        // They are once the typing pauses
        try await until("what was typed is saved") { !model.unsaved }
        #expect(try saved(id) == ["Milk, 2%"])

        // And without a pause, by Return, which goes on to a new task
        _ = model.enter("Milk, 2%!", in: milk, of: id)
        #expect(model.unsaved)
        _ = model.enter("Milk, 2%!\n", in: milk, of: id)
        #expect(!model.unsaved)
        #expect(try saved(id) == ["Milk, 2%!"])

        // And by any other change, like checking a task off
        _ = model.enter("Whole milk", in: milk, of: id)
        #expect(model.unsaved)
        model.toggle(milk, in: id)
        #expect(!model.unsaved)
        #expect(try saved(id) == ["Whole milk"])
    }

    @Test func whatsTypedInASyncedListStillGoesToTheFolder() async throws {
        let sent = try await sentFromMac()
        _ = model.enter("Milk, 2%", in: sent.milk, of: sent.list)
        #expect(model.unsaved)
        // The sync a moment after the typing saves it and writes this iPhone's copy
        try await until("what was typed is saved") { !model.unsaved }
        await model.sync.flush()
        #expect(try saved(sent.list) == ["Milk, 2%", "Eggs"])
        #expect(try myCopy(of: sent.list).items.map(\.text) == ["Milk, 2%", "Eggs"])
    }

    @Test func syncsWhenSomethingChangesInTheFolder() async throws {
        let sent = try await sentFromMac()
        // Open, with the look it takes by the clock an hour away, so only the folder saying it changed can bring a
        // change in
        model.sync.readEvery = 3600
        model.sync.changesGathered = 0.1
        let before = model.syncPasses
        model.sync.start()
        defer { model.sync.stop() }
        try await until("it syncs as it opens") { model.syncPasses > before && !model.sync.running }

        // The Mac's change arrives the way iCloud Drive brings one in, with file coordination
        let now = Date()
        let oat = try SyncedList(device: mac,
                                 items: [ToDo(id: sent.milk, text: "Oat milk", changed: now),
                                         ToDo(id: sent.eggs, text: "Eggs", done: true, changed: earlier)],
                                 orderChanged: earlier, devices: [mac, model.device], devicesChanged: earlier).encoded()
        let written = PhoneFiles.coordinatedWrite(oat, to: folder.copy(of: sent.list, by: mac))
        #expect(written)
        try await until("the Mac's change shows here") { texts(sent.list) == ["Oat milk", "Eggs"] }

        // Closed, it stops listening. The sync as it closes is the last.
        model.sync.stop()
        await model.sync.flush()
        let soy = try SyncedList(device: mac,
                                 items: [ToDo(id: sent.milk, text: "Soy milk", changed: now.addingTimeInterval(1)),
                                         ToDo(id: sent.eggs, text: "Eggs", done: true, changed: earlier)],
                                 orderChanged: earlier, devices: [mac, model.device], devicesChanged: earlier).encoded()
        let writtenAgain = PhoneFiles.coordinatedWrite(soy, to: folder.copy(of: sent.list, by: mac))
        #expect(writtenAgain)
        try await Task.sleep(for: .seconds(1))
        #expect(texts(sent.list) == ["Oat milk", "Eggs"])
        // Until it's opened again
        await model.sync.flush()
        #expect(texts(sent.list) == ["Soy milk", "Eggs"])
    }

    @Test func aScreenShowingAFolderLooksAgainAfterEachSync() async throws {
        await model.sync.flush()
        let before = model.syncPasses
        await model.sync.flush()
        #expect(model.syncPasses == before + 1)
        // Not after one that couldn't read the folder
        try FileManager.default.removeItem(at: folder.url)
        await model.sync.flush()
        #expect(model.syncPasses == before + 1)
    }

    // MARK: Recently Deleted, and Undo

    @Test func aDeletedListStaysInRecentlyDeletedAndCanBePutBack() async throws {
        let sent = try await sentFromMac()
        model.renameList(sent.list, to: "Groceries")
        model.delete(sent.list)
        #expect(model.lists.isEmpty)
        let deleted = try #require(model.recentlyDeleted.first)
        #expect(deleted.note.title == "Groceries")
        #expect(deleted.note.items.map(\.text) == ["Milk", "Eggs"])
        // Kept as it was here, but it won't sync when it's back
        #expect(deleted.note.sync == nil)

        // It's still there the next time YANA opens
        let again = AppModel(storage: root.appendingPathComponent("Lists.json"),
                             defaults: try #require(UserDefaults(suiteName: "YANATests-" + UUID().uuidString)))
        #expect(again.recentlyDeleted.map { $0.note.title } == ["Groceries"])

        // Put back, it's a list again with everything in it, and no longer in Recently Deleted
        let back = try #require(model.putBack(deleted.id))
        #expect(back != sent.list)
        #expect(model.lists.map(\.id) == [back])
        #expect(model.list(back)?.title == "Groceries")
        #expect(model.list(back)?.items.map(\.done) == [false, true])
        #expect(model.list(back)?.sync == nil)
        #expect(model.recentlyDeleted.isEmpty)
        // It can't be put back twice
        #expect(model.putBack(deleted.id) == nil)

        // Deleted again, it can be deleted for good
        model.delete(back)
        #expect(model.recentlyDeleted.count == 1)
        model.emptyRecentlyDeleted()
        #expect(model.recentlyDeleted.isEmpty)
    }

    @Test func aListWithNothingInItIsntKept() {
        let id = model.newList()
        model.delete(id)
        #expect(model.lists.isEmpty)
        #expect(model.recentlyDeleted.isEmpty)
    }

    @Test func deletedListsAreKeptFor30Days() {
        let now = Date()
        func deleted(_ name: String, daysAgo: Double) -> DeletedList {
            DeletedList(note: Note(kind: .list, items: [ToDo(text: name)]),
                        deleted: now.addingTimeInterval(-daysAgo * 24 * 60 * 60))
        }
        let kept = AppModel.kept([deleted("Old", daysAgo: 31), deleted("Week", daysAgo: 7), deleted("Today", daysAgo: 0)],
                                 now: now)
        #expect(kept.map { $0.note.title } == ["Today", "Week"])
        // And only so many of them, the latest ones
        let many = (0..<60).map { deleted("List \($0)", daysAgo: Double($0) / 10) }
        let most = AppModel.kept(many, now: now)
        #expect(most.count == AppModel.deletedLimit)
        #expect(most.first?.note.title == "List 0")
    }

    @Test func aListTheMacTakesOffThisIPhoneGoesToRecentlyDeleted() async throws {
        let sent = try await sentFromMac()
        try writeMacCopy(of: sent.list, SyncedList(device: mac, items: [ToDo(id: sent.milk, text: "Milk", changed: earlier)],
                                                   orderChanged: earlier, devices: [mac], devicesChanged: Date()))
        await model.sync.flush()
        #expect(model.list(sent.list) == nil)
        // As it was here
        #expect(model.recentlyDeleted.first?.note.items.map(\.text) == ["Milk", "Eggs"])
    }

    @Test func undoPutsADeletedTaskBackHereAndOnTheMac() async throws {
        let sent = try await sentFromMac()
        model.deleteTasks(at: [1], in: sent.list)
        #expect(texts(sent.list) == ["Milk"])
        #expect(model.undo(for: sent.list)?.summary == "Deleted “Eggs”")
        await model.sync.flush()
        let gone = try #require(try myCopy(of: sent.list).deleted[sent.eggs.uuidString])

        // The Mac hears of the deletion, and deletes it too
        try writeMacCopy(of: sent.list, SyncedList(device: mac, items: [ToDo(id: sent.milk, text: "Milk", changed: earlier)],
                                                   orderChanged: gone, devices: [mac, model.device],
                                                   devicesChanged: earlier, deleted: [sent.eggs.uuidString: gone]))
        await model.sync.flush()
        #expect(texts(sent.list) == ["Milk"])

        // Undo puts it back as it was, checked off, and it's later than the deletion, so it wins on the Mac too
        model.undoDelete()
        #expect(texts(sent.list) == ["Milk", "Eggs"])
        #expect(model.list(sent.list)?.items[1].done == true)
        #expect(model.undo(for: sent.list) == nil)
        await model.sync.flush()
        #expect(texts(sent.list) == ["Milk", "Eggs"])
        let mine = try myCopy(of: sent.list)
        #expect(mine.items.map(\.text) == ["Milk", "Eggs"])
        #expect((mine.items[1].changed ?? .distantPast) > gone)
    }

    @Test func undoPutsClearedTasksBackWhereTheyWere() throws {
        let id = model.newList()
        model.add("A\nB\nC\nD", to: id)
        let items = try #require(model.list(id)?.items)
        model.toggle(items[0].id, in: id)
        model.toggle(items[2].id, in: id)
        model.clearChecked(in: id)
        #expect(texts(id) == ["B", "D"])
        #expect(model.undo(for: id)?.summary == "Deleted 2 tasks")
        model.undoDelete()
        #expect(texts(id) == ["A", "B", "C", "D"])
        #expect(model.list(id)?.items.map(\.done) == [true, false, true, false])

        // Undo is for the latest deletion, until its few seconds are up
        model.deleteTasks(at: [0], in: id)
        let at = try #require(model.undo(for: id)?.at)
        model.forgetUndo(at: at.addingTimeInterval(-5))
        #expect(model.undo(for: id) != nil)
        model.forgetUndo(at: at)
        #expect(model.undo(for: id) == nil)
        model.undoDelete()
        #expect(texts(id) == ["B", "C", "D"])
    }

    // MARK: Setting up sync, and seeing when it stops

    @Test func showsTheListsInAFolderAndBringsOneHere() async throws {
        // A list on the Mac that doesn't come to this iPhone
        let list = UUID()
        try writeMacCopy(of: list, SyncedList(device: mac, items: [ToDo(text: "Tent", changed: earlier),
                                                                    ToDo(text: "Stove", changed: earlier)],
                                              orderChanged: earlier, devices: [mac], devicesChanged: earlier,
                                              name: "Camping", nameChanged: earlier))
        try writeCard(DeviceCard(id: mac, name: "MacBook Air", seen: earlier))
        await model.sync.flush()
        #expect(model.lists.isEmpty)
        let lists = await model.sync.lists(in: folder)
        #expect(lists.map(\.title) == ["Camping"])
        #expect(lists.first?.detail == "2 tasks, on MacBook Air")

        await model.sync.join([list], in: folder)
        let here = try #require(model.list(list))
        #expect(here.title == "Camping")
        #expect(here.items.map(\.text) == ["Tent", "Stove"])
        // This iPhone's copy says the list comes here now, later than the Mac's last word on where it goes
        let mine = try myCopy(of: list)
        #expect(mine.devices == [mac, model.device])
        #expect(mine.devicesChanged > earlier)
        #expect(mine.items.map(\.text) == ["Tent", "Stove"])
        // It isn't offered again, and it stays
        let after = await model.sync.lists(in: folder)
        #expect(after.isEmpty)
        await model.sync.flush()
        #expect(model.list(list) != nil)
    }

    @Test func aListDeletedHereCanBeBroughtBackFromItsFolder() async throws {
        let sent = try await sentFromMac()
        model.delete(sent.list)
        await model.sync.flush()
        await model.sync.flush()
        #expect(model.list(sent.list) == nil)
        let lists = await model.sync.lists(in: folder)
        #expect(lists.map(\.id) == [sent.list])

        await model.sync.join([sent.list], in: folder)
        #expect(texts(sent.list) == ["Milk", "Eggs"])
        await model.sync.flush()
        #expect(texts(sent.list) == ["Milk", "Eggs"])
        #expect(try myCopy(of: sent.list).devices.contains(model.device))
    }

    @Test func saysWhenItsFolderCantBeOpenedAndWhenItLastSynced() async throws {
        let sent = try await sentFromMac()
        let list = try #require(model.list(sent.list))
        #expect(model.syncProblem(of: list) == nil)

        // The folder goes away, as when it's deleted in Files or stops being shared
        let place = folder.url
        try FileManager.default.removeItem(at: place)
        await model.sync.flush()
        #expect(model.unreadable == [folder.id])
        let problem = try #require(model.syncProblem(of: list))
        #expect(problem.hasPrefix("YANA can't open its sync folder, “YANA Sync”, so it isn't syncing. It last synced "))
        // A list that doesn't sync has nothing to say
        let own = model.newList()
        model.add("Bread", to: own)
        let mine = try #require(model.list(own))
        #expect(model.syncProblem(of: mine) == nil)

        // Back again, it syncs again
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        await model.sync.flush()
        #expect(model.unreadable.isEmpty)
        #expect(model.syncProblem(of: list) == nil)
    }

    @Test func offersADeviceThatStartsUsingTheFolderTheListsThatSyncThere() async throws {
        model.sync.devicesLookedEvery = 0
        try writeCard(DeviceCard(id: mac, name: "MacBook Air", seen: earlier))
        let sent = try await sentFromMac()
        // The list already goes to the Mac, so there's nothing to offer it
        #expect(model.offers.isEmpty)

        // Another Mac adds the folder
        let mini = UUID().uuidString
        try writeCard(DeviceCard(id: mini, name: "Mac mini", seen: Date()))
        await model.sync.flush()
        #expect(model.offers.map(\.device.name) == ["Mac mini"])
        #expect(model.lists(notGoingTo: mini, in: folder.id).map(\.id) == [sent.list])
        // Only once
        await model.sync.flush()
        #expect(model.offers.count == 1)

        // Sending it the list adds it to the list's devices, which this iPhone's copy then says
        let offer = try #require(model.offers.first)
        model.answered(offer, sending: [sent.list])
        #expect(model.offers.isEmpty)
        #expect(model.list(sent.list)?.sync?.devices == [model.device, mac, mini])
        await model.sync.flush()
        #expect(try myCopy(of: sent.list).devices == [model.device, mac, mini])
        #expect(model.offers.isEmpty)
    }

    @Test func aDeviceAlreadyInAFolderWhenItsAddedIsntNew() async throws {
        model.sync.devicesLookedEvery = 0
        // A second folder, where a Mac's card is listed but iCloud Drive hasn't downloaded it yet
        let url = root.appendingPathComponent("Shared", isDirectory: true)
        let devices = url.appendingPathComponent("devices", isDirectory: true)
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try Data().write(to: devices.appendingPathComponent(".\(mac).json.icloud"))
        let added = try model.addFolder(url)
        let shared = try #require(model.openFolder(added.id))
        let id = model.newList()
        model.add("Bread", to: id)
        model.startSyncing(id, in: added.id, to: [])
        await model.sync.flush()

        // Its card comes down: it was there all along
        try FileManager.default.removeItem(at: devices.appendingPathComponent(".\(mac).json.icloud"))
        try writeCard(DeviceCard(id: mac, name: "MacBook Air", seen: earlier), in: shared)
        await model.sync.flush()
        #expect(model.offers.isEmpty)

        // One that turns up later is new
        try writeCard(DeviceCard(id: UUID().uuidString, name: "Mac mini", seen: Date()), in: shared)
        await model.sync.flush()
        #expect(model.offers.map(\.device.name) == ["Mac mini"])
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
