import SwiftUI
import UIKit

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
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private enum Keys {
        static let deviceID = "deviceID"
        static let deviceName = "deviceName"
        static let folders = "syncFolders"
    }

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
    }

    private func load() {
        guard let data = try? Data(contentsOf: storage),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        lists = saved.lists.filter { $0.kind == .list }
        let forgotten = Date().addingTimeInterval(-SyncMerge.deletionsKept)
        for (key, date) in saved.left where date > forgotten {
            if let id = UUID(uuidString: key) { left[id] = date }
        }
    }

    func save() {
        let saved = Saved(lists: lists.map(\.syncable),
                          left: Dictionary(uniqueKeysWithValues: left.map { ($0.key.uuidString, $0.value) }))
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
        change(list) { $0.items.remove(atOffsets: offsets) }
    }

    func moveTasks(from offsets: IndexSet, to destination: Int, in list: UUID) {
        change(list) { $0.items.move(fromOffsets: offsets, toOffset: destination) }
    }

    func clearChecked(in list: UUID) {
        change(list) { $0.clearChecked() }
    }

    func moveLists(from offsets: IndexSet, to destination: Int) {
        lists.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    /// Takes a list off this iPhone. A synced list stays on your other devices, which hear that it no longer comes here.
    func delete(_ id: UUID) {
        guard let index = index(of: id) else { return }
        let note = lists.remove(at: index)
        if note.sync != nil { sync.leave(note) }
        changed()
    }

    /// A list screen was left: a new list nothing was typed in goes away again
    func closed(_ id: UUID) {
        guard let note = list(id), note.sync == nil, note.syncable.items.isEmpty else { return }
        delete(id)
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
        note.sync = SyncInfo(folder: folder, devices: [device] + devices, devicesChanged: now, orderChanged: now,
                             deleted: [:])
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

    /// Takes away a list another device stopped sending here
    func removeSynced(_ id: UUID) {
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

    func synced(unreadable: Set<String>) {
        if unreadable != self.unreadable { self.unreadable = unreadable }
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
        saveFolders()
    }

    func rename(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != deviceName else { return }
        deviceName = name
        defaults.set(name, forKey: Keys.deviceName)
        sync.run()
    }

    // MARK: Coming and going

    func became(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sync.start()
        case .background:
            save()
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
