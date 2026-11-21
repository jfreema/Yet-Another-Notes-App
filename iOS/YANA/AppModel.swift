import SwiftUI
import UIKit

/// A list deleted from this iPhone, kept for a while in Recently Deleted so it can be put back
struct DeletedList: Codable, Equatable, Identifiable {
    var note: Note
    var deleted: Date

    var id: UUID { note.id }
}

/// The tasks just deleted from a list, which Undo puts back for a few seconds after
struct DeletedTasks: Equatable {
    struct Entry: Equatable {
        /// Where it was among the list's tasks
        var index: Int
        var task: ToDo
    }

    var list: UUID
    var tasks: [Entry]
    var at: Date

    /// What the Undo bar says: “Deleted “Milk”” or “Deleted 3 tasks”
    var summary: String {
        guard tasks.count == 1 else { return "Deleted \(tasks.count) tasks" }
        let text = tasks[0].task.text.trimmingCharacters(in: .whitespaces)
        return "Deleted “\(text.count > 24 ? String(text.prefix(24)) + "…" : text)”"
    }
}

/// A device that has started using a sync folder, to offer it the lists that sync through that folder
struct DeviceOffer: Equatable, Identifiable {
    var device: DeviceCard
    /// The folder, by its id on this iPhone
    var folder: String

    var id: String { folder + "/" + device.id }
}

/// Everything YANA keeps on this iPhone: its lists, the sync folders it uses, and its name and id as your other
/// devices know it. The views read it and change it; `PhoneSync` merges the other devices' changes into it.
@MainActor
@Observable
final class AppModel {
    /// The lists, in the order they're shown. Only to-do lists come to the iPhone; notes stay on the Mac.
    private(set) var lists: [Note] = []
    /// The sync folders this iPhone uses
    private(set) var folders: [PhoneFolder] = []
    /// What your other devices call this iPhone
    private(set) var deviceName: String
    /// The folders that couldn't be opened on the last sync, by id
    private(set) var unreadable: Set<String> = []
    /// The lists deleted from this iPhone in the last 30 days, latest first
    private(set) var recentlyDeleted: [DeletedList] = []
    /// The tasks just deleted, while Undo is offered for them
    private(set) var undoable: DeletedTasks?
    /// Devices that have started using a folder, each waiting to be offered the lists that sync through it
    private(set) var offers: [DeviceOffer] = []

    /// This iPhone's id in the sync folders
    let device: String
    @ObservationIgnored private(set) var sync: PhoneSync!
    /// The lists this iPhone stopped syncing, with when, so one deleted here doesn't come straight back
    @ObservationIgnored private(set) var left: [UUID: Date] = [:]
    private let storage: URL
    private let defaults: UserDefaults
    /// Each folder's place, once its bookmark is opened
    @ObservationIgnored private var opened: [String: URL] = [:]
    /// Lists that got a new id when they started syncing, so a screen showing one keeps showing it
    @ObservationIgnored private var renamed: [UUID: UUID] = [:]
    @ObservationIgnored private var syncSoon: Task<Void, Never>?
    /// When each sync folder was last read, by id. It's what a list that has stopped syncing says it last synced.
    @ObservationIgnored private var lastSynced: [String: Date] = [:]
    @ObservationIgnored private var lastSyncedSaved = Date.distantPast
    /// Showing the sample lists (Screenshots.swift), which don't sync
    @ObservationIgnored private(set) var isSample = false
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private enum Keys {
        static let deviceID = "deviceID"
        static let deviceName = "deviceName"
        static let folders = "syncFolders"
        static let lastRead = "syncLastRead"
        static let knownDevices = "syncKnownDevices"
    }

    /// How long a deleted list stays in Recently Deleted, and how many it holds
    static let deletedKept: TimeInterval = 30 * 24 * 60 * 60
    static let deletedLimit = 50

    init(storage: URL = AppModel.defaultStorage, defaults: UserDefaults = .standard) {
        self.storage = storage
        self.defaults = defaults
        let id = defaults.string(forKey: Keys.deviceID) ?? UUID().uuidString
        defaults.set(id, forKey: Keys.deviceID)
        device = id
        // Since iOS 16 this is just "iPhone", unless you rename it in Settings here
        deviceName = defaults.string(forKey: Keys.deviceName) ?? UIDevice.current.name
        if let data = defaults.data(forKey: Keys.folders),
           let folders = try? JSONDecoder().decode([PhoneFolder].self, from: data) {
            self.folders = folders
        }
        lastSynced = (defaults.dictionary(forKey: Keys.lastRead) as? [String: Date]) ?? [:]
        load()
        sync = PhoneSync(model: self)
    }

    nonisolated static var defaultStorage: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Lists.json")
    }

    // MARK: Saving

    private struct Saved: Codable {
        var lists: [Note]
        var left: [String: Date]
        /// Recently Deleted. Left out when there's nothing in it, and by versions before it.
        var deleted: [DeletedList]?
    }

    private func load() {
        guard let data = try? Data(contentsOf: storage),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        lists = saved.lists.filter { $0.kind == .list }
        let forgotten = Date().addingTimeInterval(-SyncMerge.deletionsKept)
        for (key, date) in saved.left where date > forgotten {
            if let id = UUID(uuidString: key) { left[id] = date }
        }
        recentlyDeleted = Self.kept(saved.deleted ?? [], now: Date())
    }

    func save() {
        let saved = Saved(lists: lists.map(\.syncable),
                          left: Dictionary(uniqueKeysWithValues: left.map { ($0.key.uuidString, $0.value) }),
                          deleted: recentlyDeleted.isEmpty ? nil : recentlyDeleted)
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: storage, options: .atomic)
        } catch {
            print("Couldn't save the lists: \(error.localizedDescription)")
        }
    }

    private func saveFolders() {
        defaults.set(try? JSONEncoder().encode(folders), forKey: Keys.folders)
    }

    /// Saves, and syncs a moment later, after a change made here
    private func changed() {
        save()
        syncSoon?.cancel()
        syncSoon = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.sync.run()
        }
    }

    // MARK: Lists

    private func resolve(_ id: UUID) -> UUID {
        var id = id
        var hops = 0
        while let next = renamed[id], hops < 20 {
            id = next
            hops += 1
        }
        return id
    }

    private func index(of id: UUID) -> Int? {
        let id = resolve(id)
        return lists.firstIndex { $0.id == id }
    }

    func list(_ id: UUID) -> Note? {
        index(of: id).map { lists[$0] }
    }

    func folderName(_ id: String?) -> String? {
        folders.first { $0.id == id }?.name
    }

    /// Makes a new, empty list at the top, and gives its id
    func newList() -> UUID {
        let note = Note(kind: .list)
        lists.insert(note, at: 0)
        changed()
        return note.id
    }

    /// Changes a list, as it was changed here. A synced list gets the change times its other devices go by.
    func change(_ id: UUID, _ body: (inout Note) -> Void) {
        guard let index = index(of: id) else { return }
        let old = lists[index]
        var new = old
        body(&new)
        guard new != old else { return }
        lists[index] = new.stamped(after: old, at: Date())
        changed()
    }

    func toggle(_ task: UUID, in list: UUID) {
        change(list) { $0.toggle(task) }
    }

    /// Typing in a task. Gives back where typing goes next.
    func enter(_ text: String, in task: UUID, of list: UUID) -> NextFocus {
        var next = NextFocus.stay
        change(list) { next = $0.enter(text, in: task) }
        return next
    }

    @discardableResult
    func add(_ text: String, to list: UUID) -> Bool {
        var added = false
        change(list) { added = $0.add(text) }
        return added
    }

    func removeBlank(_ task: UUID, in list: UUID) {
        change(list) { $0.removeBlank(task) }
    }

    func deleteTasks(at offsets: IndexSet, in list: UUID) {
        removeTasks(in: list) { note in Array(offsets).filter { note.items.indices.contains($0) } }
    }

    func moveTasks(from offsets: IndexSet, to destination: Int, in list: UUID) {
        change(list) { $0.items.move(fromOffsets: offsets, toOffset: destination) }
    }

    func clearChecked(in list: UUID) {
        removeTasks(in: list) { note in Array(note.items.indices).filter { note.items[$0].done } }
    }

    /// Deletes the tasks at the places `which` picks, and remembers them so Undo can put them back. Empty ones, which
    /// were never saved, just go.
    private func removeTasks(in list: UUID, _ which: (Note) -> [Int]) {
        guard let index = index(of: list) else { return }
        let note = lists[index]
        let gone = which(note).sorted()
        guard !gone.isEmpty else { return }
        let entries = gone.map { DeletedTasks.Entry(index: $0, task: note.items[$0]) }.filter { !$0.task.isBlank }
        change(note.id) { $0.items.remove(atOffsets: IndexSet(gone)) }
        if !entries.isEmpty {
            undoable = DeletedTasks(list: note.id, tasks: entries, at: Date())
        }
    }

    /// Puts the tasks just deleted back where they were. In a synced list they count as changed now, so they come
    /// back on your other devices too.
    func undoDelete() {
        guard let undo = undoable else { return }
        undoable = nil
        change(undo.list) { note in
            for entry in undo.tasks where !note.items.contains(where: { $0.id == entry.task.id }) {
                note.items.insert(entry.task, at: min(entry.index, note.items.count))
            }
        }
    }

    /// The tasks just deleted from a list, while Undo is offered for them
    func undo(for list: UUID) -> DeletedTasks? {
        guard let undo = undoable, resolve(undo.list) == resolve(list) else { return nil }
        return undo
    }

    /// Undo's few seconds are up. `at` names the deletion they were for, so a later one keeps its own.
    func forgetUndo(at: Date? = nil) {
        guard let undo = undoable, at == nil || undo.at == at else { return }
        undoable = nil
    }

    /// Gives a list a name of its own in place of its first task, or with nothing typed, takes its name off. A synced
    /// list's name goes to the other devices.
    func renameList(_ list: UUID, to name: String) {
        change(list) { $0.name = Note.name(name) }
    }

    func moveLists(from offsets: IndexSet, to destination: Int) {
        lists.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    /// Takes a list off this iPhone, and keeps it in Recently Deleted. A synced list stays on your other devices,
    /// which hear that it no longer comes here.
    func delete(_ id: UUID) {
        guard let index = index(of: id) else { return }
        let note = lists.remove(at: index)
        if note.sync != nil { sync.leave(note) }
        if undo(for: note.id) != nil { undoable = nil }
        keepDeleted(note)
        changed()
    }

    /// A list screen was left: Undo for a task deleted there is over, and a new list nothing was typed in goes away
    /// again, unless it was given a name
    func closed(_ id: UUID) {
        guard let note = list(id) else { return }
        if undo(for: note.id) != nil { undoable = nil }
        guard note.sync == nil, note.syncable.items.isEmpty, note.name == nil else { return }
        delete(id)
    }

    // MARK: Recently Deleted

    /// The deleted lists still kept at `now`, latest first
    static func kept(_ deleted: [DeletedList], now: Date) -> [DeletedList] {
        Array(deleted.filter { now.timeIntervalSince($0.deleted) < deletedKept }
            .sorted { $0.deleted > $1.deleted }
            .prefix(deletedLimit))
    }

    /// Keeps a list taken off this iPhone in Recently Deleted, as it was here but without its syncing. One with
    /// nothing in it isn't worth keeping.
    private func keepDeleted(_ note: Note, at now: Date = Date()) {
        var note = note.syncable
        guard !note.items.isEmpty || note.name != nil else { return }
        note.sync = nil
        recentlyDeleted = Self.kept([DeletedList(note: note, deleted: now)] + recentlyDeleted.filter { $0.id != note.id },
                                    now: now)
    }

    /// Puts a deleted list back, at the top of the lists, and gives its id. It gets a new id and doesn't sync, so
    /// nothing left in a sync folder from before mixes in.
    @discardableResult
    func putBack(_ id: UUID) -> UUID? {
        guard let index = recentlyDeleted.firstIndex(where: { $0.id == id }) else { return nil }
        var note = recentlyDeleted.remove(at: index).note
        note.id = UUID()
        note.sync = nil
        lists.insert(note, at: 0)
        changed()
        return note.id
    }

    /// Deletes a list in Recently Deleted for good
    func deleteForGood(_ id: UUID) {
        recentlyDeleted.removeAll { $0.id == id }
        save()
    }

    func emptyRecentlyDeleted() {
        recentlyDeleted = []
        save()
    }

    // MARK: Syncing a list

    /// Starts syncing a list through a folder to `devices` as well as this iPhone. It gets a new id, as on the Mac, so
    /// nothing left from an earlier time it synced mixes in.
    func startSyncing(_ id: UUID, in folder: String, to devices: [String]) {
        guard let index = index(of: id) else { return }
        let now = Date()
        var note = lists[index].syncable
        let oldID = note.id
        note.id = UUID()
        note.items = note.items.map { item in
            var item = item
            item.changed = now
            return item
        }
        // A name it already has goes with it
        note.sync = SyncInfo(folder: folder, devices: [device] + devices, devicesChanged: now, orderChanged: now,
                             deleted: [:], nameChanged: note.name == nil ? nil : now)
        renamed[oldID] = note.id
        lists[index] = note
        changed()
    }

    /// Changes which devices a synced list goes to
    func send(_ id: UUID, to devices: [String]) {
        guard let index = index(of: id), var sync = lists[index].sync else { return }
        let all = [device] + devices
        guard Set(all) != Set(sync.devices) else { return }
        sync.devices = all
        sync.devicesChanged = Date()
        lists[index].sync = sync
        changed()
    }

    /// Stops syncing a list on this iPhone. It stays here, and on your other devices.
    func stopSyncing(_ id: UUID) {
        guard let index = index(of: id), lists[index].sync != nil else { return }
        sync.leave(lists[index])
        lists[index].sync = nil
        changed()
    }

    // MARK: What syncing does

    /// Shows a synced list as merged with the other devices' changes
    func showSynced(_ note: Note) {
        guard let index = lists.firstIndex(where: { $0.id == note.id }) else { return }
        lists[index] = note
        save()
    }

    /// Adds a list another device sent here
    func addSynced(_ note: Note) {
        lists.append(note)
        save()
    }

    /// Takes away a list another device stopped sending here. It's kept in Recently Deleted as it was here.
    func removeSynced(_ id: UUID) {
        if let note = lists.first(where: { $0.id == id }) { keepDeleted(note) }
        if undo(for: id) != nil { undoable = nil }
        lists.removeAll { $0.id == id }
        save()
    }

    func remember(left id: UUID, at date: Date) {
        left[id] = date
        save()
    }

    func forget(left id: UUID) {
        left[id] = nil
    }

    /// A sync pass is done: `unreadable` are the folders it couldn't open, and `read` the ones it read
    func synced(unreadable: Set<String>, read: Set<String> = [], at now: Date = Date()) {
        if unreadable != self.unreadable { self.unreadable = unreadable }
        guard !read.isEmpty else { return }
        for id in read { lastSynced[id] = now }
        // Kept for the next time YANA opens, about once a minute
        if now.timeIntervalSince(lastSyncedSaved) >= 60 {
            lastSyncedSaved = now
            defaults.set(lastSynced, forKey: Keys.lastRead)
        }
    }

    /// What's stopping a list from syncing, to say on its row and at the top of it, with when it last synced. Nil
    /// while it's syncing, and for a list that doesn't sync.
    func syncProblem(of list: Note, now: Date = Date()) -> String? {
        guard let sync = list.sync else { return nil }
        guard let folder = folders.first(where: { $0.id == sync.folder }) else {
            return "Its sync folder isn't one this iPhone uses any more, so it isn't syncing."
        }
        guard unreadable.contains(folder.id) else { return nil }
        var text = "YANA can't open its sync folder, “\(folder.name)”, so it isn't syncing."
        if let last = lastSynced[folder.id] {
            // This iPhone's clock may have been set back since
            text += " It last synced \(min(last, now).formatted(.relative(presentation: .named)))."
        }
        return text
    }

    // MARK: A device that starts using a folder

    /// Notices a device that has started using a folder since the last look, and offers it the lists that sync through
    /// the folder when there are any it doesn't get. `cards` are the devices whose cards could be read, and `listed`
    /// every device in the folder, read yet or not. The first look at a folder only remembers who's there: they were
    /// there before anything could be offered.
    func noticed(_ cards: [DeviceCard], listed: [String], in folder: String) {
        var known = (defaults.dictionary(forKey: Keys.knownDevices) as? [String: [String]]) ?? [:]
        guard let before = known[folder] else {
            known[folder] = Array(Set(listed + cards.map(\.id))).sorted()
            defaults.set(known, forKey: Keys.knownDevices)
            return
        }
        let new = cards.filter { $0.id != device && !before.contains($0.id) }
        guard !new.isEmpty else { return }
        known[folder] = before + new.map(\.id)
        defaults.set(known, forKey: Keys.knownDevices)
        for card in new where !lists(notGoingTo: card.id, in: folder).isEmpty {
            let offer = DeviceOffer(device: card, folder: folder)
            if !offers.contains(where: { $0.id == offer.id }) { offers.append(offer) }
        }
    }

    /// The lists here that sync through a folder and don't go to `device` yet
    func lists(notGoingTo device: String, in folder: String) -> [Note] {
        lists.filter { note in
            guard let sync = note.sync else { return false }
            return sync.folder == folder && !sync.devices.contains(device)
        }
    }

    /// An offer was answered: the lists picked go to its device as well, and it isn't made again
    func answered(_ offer: DeviceOffer, sending picked: [UUID] = []) {
        offers.removeAll { $0.id == offer.id }
        for id in picked {
            guard let sync = list(id)?.sync, !sync.devices.contains(offer.device.id) else { continue }
            send(id, to: sync.devices.filter { $0 != device } + [offer.device.id])
        }
    }

    // MARK: Folders and this iPhone

    /// The sync folders that can be opened, ready to read and write
    func openFolders() -> [OpenFolder] {
        folders.compactMap { openBookmark($0) }
    }

    func openFolder(_ id: String) -> OpenFolder? {
        folders.first { $0.id == id }.flatMap { openBookmark($0) }
    }

    private func openBookmark(_ folder: PhoneFolder) -> OpenFolder? {
        if let url = opened[folder.id] { return OpenFolder(id: folder.id, url: url) }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        // Kept open for as long as YANA runs. It's false for a folder YANA can use anyway, as in the tests.
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil,
                                                    relativeTo: nil),
           let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index].bookmark = fresh
            saveFolders()
        }
        opened[folder.id] = url
        return OpenFolder(id: folder.id, url: url)
    }

    /// Starts using a folder picked in Files, and adds this iPhone to its devices, so your other devices can send lists
    /// here through it
    @discardableResult
    func addFolder(_ url: URL) throws -> PhoneFolder {
        let path = url.standardizedFileURL.path
        for folder in openFolders() where opened[folder.id]?.standardizedFileURL.path == path {
            if let existing = folders.first(where: { $0.id == folder.id }) { return existing }
        }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            let folder = PhoneFolder(id: UUID().uuidString, name: url.lastPathComponent, bookmark: bookmark)
            let open = OpenFolder(id: folder.id, url: url)
            try FileManager.default.createDirectory(at: open.devicesFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: open.listsFolder, withIntermediateDirectories: true)
            folders.append(folder)
            opened[folder.id] = url
            saveFolders()
            sync.run()
            return folder
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Stops using a folder. The lists that synced through it stay here, but stop syncing.
    func removeFolder(_ id: String) {
        for note in lists where note.sync?.folder == id {
            stopSyncing(note.id)
        }
        folders.removeAll { $0.id == id }
        unreadable.remove(id)
        offers.removeAll { $0.folder == id }
        lastSynced[id] = nil
        defaults.set(lastSynced, forKey: Keys.lastRead)
        var known = (defaults.dictionary(forKey: Keys.knownDevices) as? [String: [String]]) ?? [:]
        known[id] = nil
        defaults.set(known, forKey: Keys.knownDevices)
        saveFolders()
    }

    func rename(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != deviceName else { return }
        deviceName = name
        defaults.set(name, forKey: Keys.deviceName)
        sync.run()
    }

    #if DEBUG
    /// Sample lists, for screenshots (Screenshots.swift)
    func showSamples() {
        isSample = true
        let now = Date()
        let folder = sampleFolder(now: now)
        folders = [folder]
        let sync = SyncInfo(folder: folder.id, devices: [device], devicesChanged: now, orderChanged: now, deleted: [:])
        lists = [
            Note(kind: .list, items: [
                ToDo(text: "Book flights for the conference", done: true),
                ToDo(text: "Renew passport"),
                ToDo(text: "Ask Sam about the budget review, and send the slides from last week's meeting"),
                ToDo(text: "Pick up dry cleaning", done: true),
                ToDo(text: "Call the dentist"),
            ], name: "This Week", sync: sync),
            Note(kind: .list, items: [ToDo(text: "Milk"), ToDo(text: "Eggs", done: true), ToDo(text: "Coffee beans"),
                                      ToDo(text: "Lemons"), ToDo(text: "Sourdough", done: true)],
                 name: "Groceries", sync: sync),
            Note(kind: .list, items: [ToDo(text: "Fix the garden gate"), ToDo(text: "Return library books", done: true),
                                      ToDo(text: "Plan Saturday hike")],
                 name: "Weekend", sync: sync),
            Note(kind: .list, items: [ToDo(text: "Scarf for Mom"), ToDo(text: "Board game for Alex")],
                 name: "Gift Ideas"),
        ]
        // What the newer screens show, each only when its launch argument asks for it
        let show = UserDefaults.standard.string(forKey: "YANAShow")
        if show == "deleted" {
            recentlyDeleted = [
                DeletedList(note: Note(kind: .list, items: [ToDo(text: "Sunscreen", done: true), ToDo(text: "Beach towels"),
                                                            ToDo(text: "Cooler")], name: "Beach Day"),
                            deleted: now.addingTimeInterval(-26 * 60 * 60)),
                DeletedList(note: Note(kind: .list, items: [ToDo(text: "Paint the fence")]),
                            deleted: now.addingTimeInterval(-9 * 24 * 60 * 60)),
            ]
        }
        if show == "offer" {
            offers = [DeviceOffer(device: DeviceCard(id: UUID().uuidString, name: "Mac mini", seen: now),
                                  folder: folder.id)]
        }
        if UserDefaults.standard.bool(forKey: "YANAStopped") {
            unreadable = [folder.id]
            lastSynced[folder.id] = now.addingTimeInterval(-2 * 60 * 60)
        }
    }

    /// A real folder for the sample lists to sync through, with a Mac in it and two of the Mac's lists that this
    /// iPhone doesn't have, for the screen that brings lists here
    private func sampleFolder(now: Date) -> PhoneFolder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Samples-\(UUID().uuidString)/YANA Sync", isDirectory: true)
        let open = OpenFolder(id: UUID().uuidString, url: url)
        let mac = UUID().uuidString
        func write(_ data: Data?, to file: URL) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data?.write(to: file)
        }
        write(try? JSONEncoder().encode(DeviceCard(id: mac, name: "MacBook Air", seen: now)), to: open.card(of: mac))
        let lists = [("Camping", ["Tent", "Stove", "Lantern", "Sleeping bags", "Trail map"]),
                     ("Movies to Watch", ["Dune", "Arrival"])]
        for (name, tasks) in lists {
            let copy = SyncedList(device: mac, items: tasks.map { ToDo(text: $0, changed: now) }, orderChanged: now,
                                  devices: [mac], devicesChanged: now, name: name, nameChanged: now)
            write(try? copy.encoded(), to: open.copy(of: UUID(), by: mac))
        }
        let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        return PhoneFolder(id: open.id, name: "YANA Sync", bookmark: bookmark ?? Data())
    }
    #endif

    // MARK: Coming and going

    func became(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // Lists deleted more than 30 days ago go
            let kept = Self.kept(recentlyDeleted, now: Date())
            if kept != recentlyDeleted {
                recentlyDeleted = kept
                save()
            }
            sync.start()
        case .background:
            save()
            defaults.set(lastSynced, forKey: Keys.lastRead)
            sync.stop()
            syncBeforeSuspending()
        default:
            break
        }
    }

    /// Writes the last changes out before iOS suspends YANA
    private func syncBeforeSuspending() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Sync lists") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        Task {
            await sync.flush()
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
