import AppKit

/// What the note window does for syncing: the tabs to sync, and changing them when other devices' changes come in
@MainActor
protocol SyncHost: AnyObject {
    var notePages: [NotePage] { get }
    /// Shows a synced list as merged with the other devices' changes
    func showSynced(_ note: Note, on page: NotePage)
    /// Adds a tab for a list another device sent here
    func addSynced(_ note: Note)
    /// Takes away a list another device stopped sending here
    func removeSynced(_ page: NotePage)
}

/// Syncs to-do lists through sync folders. Every few seconds it reads the other devices' copies of each synced list,
/// merges them with this Mac's copy, shows the result, and writes this Mac's copy when it has changed. Lists another
/// device sends here get a tab of their own.
@MainActor
final class ListSync {
    weak var host: SyncHost?
    private let files = SyncFiles()
    private var timer: Timer?
    private var reading = false
    /// Each synced list as last saved, shown or merged, to tell what's changed since by comparing
    private var known: [UUID: Note] = [:]
    /// Each list's copy as this Mac last wrote it
    private var written: [UUID: SyncedList] = [:]

    func start() {
        let me = DeviceCard(id: ThisDevice.id, name: ThisDevice.name, seen: Date())
        let folders = SyncFolders.all
        Task { await files.register(me, in: folders) }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
    }

    /// A tab's note, and for a synced list, stamped with when each change was made since it was last known
    func note(of page: NotePage) -> Note {
        let note = page.note
        guard note.kind == .list, note.sync != nil else { return note }
        guard let before = known[note.id] else {
            known[note.id] = note
            return note
        }
        let stamped = note.stamped(since: before, at: Date())
        page.sync = stamped.sync
        known[note.id] = stamped
        return stamped
    }

    // MARK: Starting and stopping

    /// Starts syncing a list through `folder` to `devices` as well as this Mac. It gets a new id, so nothing left from an
    /// earlier time it synced mixes in.
    func start(_ page: NotePage, in folder: SyncFolder, to devices: [String]) {
        let now = Date()
        var note = page.note
        note.id = UUID()
        note.items = note.items.map { item in
            var item = item
            item.changed = now
            return item
        }
        note.sync = SyncInfo(folder: folder.id, devices: [ThisDevice.id] + devices, devicesChanged: now,
                             orderChanged: now, deleted: [:])
        page.id = note.id
        page.sync = note.sync
        known[note.id] = note
        let me = DeviceCard(id: ThisDevice.id, name: ThisDevice.name, seen: now)
        Task { await files.register(me, in: [folder]) }
        run()
    }

    /// Adds a sync folder, and this Mac to its devices, so other devices can send lists here through it
    @discardableResult
    func add(_ url: URL) throws -> SyncFolder {
        let folder = try SyncFolders.add(url)
        let me = DeviceCard(id: ThisDevice.id, name: ThisDevice.name, seen: Date())
        Task { await files.register(me, in: [folder]) }
        run()
        return folder
    }

    /// Changes which devices a synced list goes to
    func send(_ page: NotePage, to devices: [String]) {
        guard var sync = page.sync else { return }
        sync.devices = [ThisDevice.id] + devices
        sync.devicesChanged = Date()
        page.sync = sync
        run()
    }

    /// Stops syncing a list on this Mac. Its copy here stays, but the other devices hear that it no longer comes here.
    func stop(_ page: NotePage) {
        let note = self.note(of: page)
        page.sync = nil
        known[note.id] = nil
        written[note.id] = nil
        guard let folder = note.sync.flatMap({ SyncFolders.folder($0.folder) }),
              var copy = SyncedList(note, device: ThisDevice.id) else { return }
        copy.items = []
        copy.devices.removeAll { $0 == ThisDevice.id }
        copy.devicesChanged = Date()
        let file = folder.copy(of: note.id, by: ThisDevice.id)
        let last = copy
        Task { await files.write(last, to: file) }
    }

    // MARK: Syncing

    /// Reads every sync folder, then merges what's in them
    func run() {
        let folders = SyncFolders.all
        guard !reading, !folders.isEmpty else { return }
        reading = true
        Task {
            let found = await files.read(folders)
            reading = false
            merge(found, folders: folders)
        }
    }

    private func merge(_ found: [String: [UUID: [SyncedList]]], folders: [SyncFolder]) {
        guard let host else { return }
        let me = ThisDevice.id
        let now = Date()

        for page in host.notePages {
            let local = note(of: page)
            guard local.kind == .list, let sync = local.sync,
                  let folder = folders.first(where: { $0.id == sync.folder }),
                  let lists = found[folder.id] else { continue }
            let copies = lists[local.id] ?? []
            let others = copies.filter { $0.device != me }
            guard let mine = SyncedList(local, device: me) else { continue }
            let merged = SyncMerge.merge([mine] + others, now: now)
            let file = folder.copy(of: local.id, by: me)

            // Another device took this Mac off the list
            if !merged.devices.contains(me) {
                known[local.id] = nil
                written[local.id] = nil
                host.removeSynced(page)
                Task { await files.delete(file) }
                continue
            }

            let result = local.adopting(merged)
            if !result.items.looksLike(local.items) {
                // A task being edited or dragged waits for the next time
                if (page as? TodoList)?.isBusy == true { continue }
                known[local.id] = result
                host.showSynced(result, on: page)
            } else {
                known[local.id] = result
                page.sync = result.sync
            }

            let onDisk = copies.first { $0.device == me }
            if onDisk != merged && (onDisk == nil || written[local.id] != merged) {
                written[local.id] = merged
                Task { await files.write(merged, to: file) }
            }
        }

        // Lists sent here from another device
        let here = Set(host.notePages.map { $0.id })
        for folder in folders {
            for (id, copies) in found[folder.id] ?? [:] where !here.contains(id) {
                let others = copies.filter { $0.device != me }
                guard !others.isEmpty else { continue }
                let merged = SyncMerge.merge([SyncedList(device: me)] + others, now: now)
                guard merged.devices.contains(me) else { continue }
                let sync = SyncInfo(folder: folder.id, devices: merged.devices, devicesChanged: merged.devicesChanged,
                                    orderChanged: merged.orderChanged, deleted: merged.deleted)
                let note = Note(id: id, kind: .list, items: merged.items, sync: sync)
                known[id] = note
                host.addSynced(note)
            }
        }
    }
}

/// Reads and writes the sync folders, away from the main thread, since a file in iCloud Drive may have to download
actor SyncFiles {
    /// Copies already read, by path, with their modification dates, so unchanged files aren't read again
    private var cache: [String: (date: Date, list: SyncedList)] = [:]

    /// Every list in every folder: folder id → list id → the devices' copies. A folder that can't be read is left out.
    func read(_ folders: [SyncFolder]) -> [String: [UUID: [SyncedList]]] {
        let manager = FileManager.default
        var found: [String: [UUID: [SyncedList]]] = [:]
        for folder in folders {
            guard let lists = try? manager.contentsOfDirectory(at: folder.listsFolder, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else { continue }
            var copies: [UUID: [SyncedList]] = [:]
            for list in lists {
                guard let id = UUID(uuidString: list.lastPathComponent),
                      let files = try? manager.contentsOfDirectory(at: list, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles]) else { continue }
                // Only <device id>.json, not a copy a sync service made of one
                copies[id] = files.filter { file in
                    file.pathExtension == "json" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil
                }.compactMap { read($0) }
            }
            found[folder.id] = copies
        }
        return found
    }

    private func read(_ file: URL) -> SyncedList? {
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
        if let cached = cache[file.path], cached.date == date { return cached.list }
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode(SyncedList.self, from: data) else { return nil }
        cache[file.path] = (date, list)
        return list
    }

    func write(_ list: SyncedList, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try list.encoded().write(to: file, options: .atomic)
        } catch {
            logger.error("Couldn't write a synced list: \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        cache[file.path] = nil
    }

    /// Writes this Mac's card in each folder, so other devices can send lists to it, if it's missing, renamed or old
    func register(_ card: DeviceCard, in folders: [SyncFolder]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for folder in folders {
            let file = folder.card(of: card.id)
            if let data = try? Data(contentsOf: file), let old = try? JSONDecoder().decode(DeviceCard.self, from: data),
               old.name == card.name, card.seen.timeIntervalSince(old.seen) < 24 * 60 * 60 { continue }
            do {
                try FileManager.default.createDirectory(at: folder.devicesFolder, withIntermediateDirectories: true)
                try encoder.encode(card).write(to: file, options: .atomic)
            } catch {
                logger.error("Couldn't add this Mac to a sync folder: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
