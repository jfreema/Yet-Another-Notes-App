import Foundation

// One pass of syncing, worked out the same way on the Mac and the iPhone. Each app reads its sync folders in its own
// way (ListSync and SyncFiles on the Mac, PhoneSync and PhoneFiles on the iPhone) and hands what it read to `SyncPass`,
// which says what to show, add, take away, write and delete. Nothing here touches a file or a screen, so one set of
// tests covers both apps. YANA for iPhone (iOS/) compiles this file too, along with Note.swift and SyncFormat.swift.
// Keep it to Foundation.

/// What was read from the sync folders: folder id → list id → the devices' copies of that list. A folder that couldn't
/// be read is left out.
typealias FoundLists = [String: [UUID: [SyncedList]]]

/// Where things are in a sync folder, which is the same on every device (see SyncFormat.swift). Each app has its own
/// kind of folder: the Mac keeps where it is, and the iPhone a bookmark to it.
protocol SyncFolderLayout {
    var url: URL { get }
}

extension SyncFolderLayout {
    var devicesFolder: URL { url.appendingPathComponent("devices", isDirectory: true) }
    var listsFolder: URL { url.appendingPathComponent("lists", isDirectory: true) }

    func listFolder(_ list: UUID) -> URL {
        listsFolder.appendingPathComponent(list.uuidString, isDirectory: true)
    }

    func copy(of list: UUID, by device: String) -> URL {
        listFolder(list).appendingPathComponent(device + ".json")
    }

    func card(of device: String) -> URL {
        devicesFolder.appendingPathComponent(device + ".json")
    }
}

/// A list in a sync folder that other devices have and this one doesn't
struct FolderList: Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var tasks: Int
    /// The names of the devices it's on
    var devices: [String]

    /// What it says under its name: “5 tasks, on Jared's MacBook Air”
    var detail: String {
        var parts = [tasks == 0 ? "No tasks" : tasks == 1 ? "1 task" : "\(tasks) tasks"]
        if !devices.isEmpty { parts.append("on " + devices.formatted(.list(type: .and))) }
        return parts.joined(separator: ", ")
    }
}

/// Works out each pass of syncing for one device, and remembers the copies it last had written
struct SyncPass {
    /// This device's id in the sync folders
    let device: String
    /// How long a copy just written is given to show up in the folder as written, before it's written again
    var writeSettles: TimeInterval = 15
    /// Each list's copy as this device last had it written, and when
    private var written: [UUID: (copy: SyncedList, at: Date)] = [:]

    init(device: String) {
        self.device = device
    }

    /// A synced list here, after the other devices' changes were merged into it
    struct Merged: Equatable {
        var note: Note
        /// Whether its tasks or its name show differently now. When they don't, only what it keeps for syncing changed.
        var looksDifferent: Bool
    }

    /// One of this device's copies to write: `copy` goes in the folder with this id, as this device's copy of `list`
    struct Write: Equatable {
        var list: UUID
        var folder: String
        var copy: SyncedList
    }

    /// One of this device's copies to delete
    struct Delete: Equatable {
        var list: UUID
        var folder: String
    }

    /// What a pass found to do
    struct Changes: Equatable {
        /// The synced lists the merge changed, as they are now
        var merged: [Merged] = []
        /// Lists another device sends here, to add
        var added: [Note] = []
        /// Lists another device took this device off, to take away
        var removed: [UUID] = []
        var writes: [Write] = []
        var deletes: [Delete] = []
    }

    /// One pass: merges what was read from the folders with what's on this device.
    ///
    /// - Parameters:
    ///   - lists: This device's synced lists as they are now, with the changes made here already stamped.
    ///   - here: The id of every list and note on this device, synced or not.
    ///   - folders: The sync folders this device uses, by id, in order.
    ///   - found: What was read from them.
    ///   - left: The lists this device stopped syncing, with when, so one deleted here doesn't come straight back.
    ///   - waiting: Lists that can't show changes just now, such as one with a task being dragged. One whose merge
    ///     would change what it shows is left for a later pass.
    mutating func run(lists: [Note], here: Set<UUID>, folders: [String], found: FoundLists, left: [UUID: Date] = [:],
                      waiting: Set<UUID> = [], now: Date) -> Changes {
        var changes = Changes()
        var here = here

        for local in lists {
            guard local.kind == .list, let sync = local.sync, folders.contains(sync.folder),
                  let inFolder = found[sync.folder], let mine = SyncedList(local.syncable, device: device) else { continue }
            let copies = inFolder[local.id] ?? []
            let others = copies.filter { $0.device != device }
            let merged = SyncMerge.merge([mine] + others, now: now)

            // Another device took this one off the list
            guard merged.devices.contains(device) else {
                written[local.id] = nil
                here.remove(local.id)
                changes.removed.append(local.id)
                changes.deletes.append(Delete(list: local.id, folder: sync.folder))
                continue
            }

            // The other devices' changes, with the empty tasks just opened here kept where they are
            var result = local.adopting(merged)
            result.items = local.items.showing(merged.items)
            if result != local {
                let looksDifferent = !result.items.looksLike(local.items) || result.name != local.name
                // Nothing of this list is done until it can show them, so its copy never says more than it shows
                if looksDifferent && waiting.contains(local.id) { continue }
                changes.merged.append(Merged(note: result, looksDifferent: looksDifferent))
            }

            // This device's copy is written whenever the folder doesn't have it as it is now. One just written may not
            // have been read back yet, or couldn't be written, so it's given a while before it's written again.
            let onDisk = copies.first { $0.device == device }
            guard onDisk != merged else { continue }
            if let last = written[local.id], last.copy == merged, now.timeIntervalSince(last.at) < writeSettles {
                continue
            }
            written[local.id] = (merged, now)
            changes.writes.append(Write(list: local.id, folder: sync.folder, copy: merged))
        }

        // Lists sent here from another device
        for folder in folders {
            guard let lists = found[folder] else { continue }
            for id in lists.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !here.contains(id) {
                let copies = lists[id] ?? []
                let others = copies.filter { $0.device != device }
                guard !others.isEmpty else { continue }
                // This device's own copy counts when there is one. After the list was deleted here, it's what says the
                // list no longer comes here, until the other devices have heard and say so too.
                let mine = copies.first { $0.device == device }
                let merged = SyncMerge.merge([mine ?? SyncedList(device: device)] + others, now: now)
                guard merged.devices.contains(device) else { continue }
                if let when = left[id], merged.devicesChanged <= when {
                    // Read before this device's copy said it had left. And if a copy written before it left has
                    // landed after the one saying so, it says so again.
                    if let mine, mine.devices.contains(device) {
                        changes.writes.append(Write(list: id, folder: folder, copy: mine.leaving(at: when)))
                    }
                    continue
                }
                let sync = SyncInfo(folder: folder, devices: merged.devices, devicesChanged: merged.devicesChanged,
                                    orderChanged: merged.orderChanged, deleted: merged.deleted,
                                    nameChanged: merged.nameChanged)
                changes.added.append(Note(id: id, kind: .list, items: merged.items, name: merged.name, sync: sync))
                // Once, even if two folders have it
                here.insert(id)
                if mine != merged {
                    written[id] = (merged, now)
                    changes.writes.append(Write(list: id, folder: folder, copy: merged))
                }
            }
        }
        return changes
    }

    /// Forgets the copy last written of a list, as when it stops syncing here or starts again
    mutating func forget(_ list: UUID) {
        written[list] = nil
    }

    // MARK: A folder's lists

    /// A list's copies merged, if other devices still sync it and it doesn't come to this device
    func elsewhere(_ copies: [SyncedList], now: Date) -> SyncedList? {
        let others = copies.filter { $0.device != device }
        guard !others.isEmpty else { return nil }
        // This device's copy counts when there is one, as it does for a list sent here
        let mine = copies.first { $0.device == device } ?? SyncedList(device: device)
        let merged = SyncMerge.merge([mine] + others, now: now)
        guard !merged.devices.isEmpty, !merged.devices.contains(device) else { return nil }
        return merged
    }

    /// The lists in a sync folder that other devices have and this one doesn't, by name. `lists` is what was read from
    /// the folder, `here` the id of every list and note on this device, and `names` the folder's devices' names by id.
    func lists(in lists: [UUID: [SyncedList]], here: Set<UUID>, names: [String: String], now: Date) -> [FolderList] {
        var found: [FolderList] = []
        for (id, copies) in lists where !here.contains(id) {
            guard let merged = elsewhere(copies, now: now) else { continue }
            let note = Note(id: id, kind: .list, items: merged.items, name: merged.name)
            found.append(FolderList(id: id, title: note.title, tasks: merged.items.count,
                                    devices: merged.devices.compactMap { names[$0] }))
        }
        return found.sorted { ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }
    }

    /// A list in a sync folder as it comes to this device when it's brought here: this device joins the devices the
    /// list goes to, the same as if it had been ticked on one of them. Nil if the list doesn't sync any more, or
    /// already comes here. `copies` are the devices' copies of it, and `folder` the folder's id on this device.
    mutating func joining(_ id: UUID, from copies: [SyncedList], in folder: String, now: Date) -> Note? {
        guard let merged = elsewhere(copies, now: now) else { return nil }
        // Later than the change it follows, even if the other device's clock is ahead of this one's
        let changed = max(now, merged.devicesChanged.addingTimeInterval(1))
        let sync = SyncInfo(folder: folder, devices: merged.devices + [device], devicesChanged: changed,
                            orderChanged: merged.orderChanged, deleted: merged.deleted, nameChanged: merged.nameChanged)
        written[id] = nil
        return Note(id: id, kind: .list, items: merged.items, name: merged.name, sync: sync)
    }

    // MARK: A folder's devices

    /// The devices that have started using a sync folder since it was last looked at, and the devices to remember for
    /// the next look. `cards` are the devices whose cards could be read, `listed` every device in the folder whether
    /// or not its card could be read yet, and `before` the ones remembered from the last look. The first look at a
    /// folder (`before` is nil) only remembers who's there: they were there before anything could be offered them.
    func noticed(_ cards: [DeviceCard], listed: [String], before: [String]?) -> (known: [String], new: [DeviceCard]) {
        guard let before else { return (Array(Set(listed + cards.map(\.id))).sorted(), []) }
        var new: [DeviceCard] = []
        for card in cards where card.id != device && !before.contains(card.id) {
            if !new.contains(where: { $0.id == card.id }) { new.append(card) }
        }
        return (before + new.map(\.id), new)
    }
}

extension SyncedList {
    /// This copy as its device writes it when it stops syncing the list: without tasks and without that device in the
    /// devices the list goes to, which is how the others hear that it no longer goes there. They keep the list.
    func leaving(at when: Date) -> SyncedList {
        var copy = self
        copy.items = []
        copy.devices.removeAll { $0 == device }
        copy.devicesChanged = when
        return copy
    }
}

extension Note {
    /// The list as it's saved and synced: without empty tasks, which are ones just opened to type in
    var syncable: Note {
        var note = self
        note.items = items.filter { !$0.isBlank }
        return note
    }

    /// The list as it starts syncing through a folder, from `device` to `devices` as well. It gets a new id, so nothing
    /// left in the folder from an earlier time it synced mixes in, every task counts as changed now, and a name it
    /// already has goes with it.
    func startingToSync(in folder: String, from device: String, to devices: [String], at now: Date) -> Note {
        var note = syncable
        note.id = UUID()
        note.items = note.items.map { item in
            var item = item
            item.changed = now
            return item
        }
        note.sync = SyncInfo(folder: folder, devices: [device] + devices, devicesChanged: now, orderChanged: now,
                             deleted: [:], nameChanged: note.name == nil ? nil : now)
        return note
    }
}
