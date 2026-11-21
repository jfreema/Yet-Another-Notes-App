import Foundation

/// A list in a sync folder that other devices have and this iPhone doesn't
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

/// Syncs this iPhone's lists through the sync folders, the same way YANA on the Mac does (ListSync there). Every few
/// seconds while YANA is open, soon after each change here, and when it goes to the background, it reads the other
/// devices' copies of each synced list, merges them with this iPhone's (`SyncMerge`, shared with the Mac), shows the
/// result, and writes this iPhone's copy when the folder doesn't have it as it is. Lists another device sends here are
/// added. Nothing syncs while YANA isn't open: the other devices' changes come in when it's next opened. It also tells
/// the model which folders it could read, and about a device that starts using one.
@MainActor
final class PhoneSync {
    private weak var model: AppModel?
    let files = PhoneFiles()
    private var timer: Timer?
    private(set) var running = false
    private var runAgain = false
    /// Each list's copy as this iPhone last wrote it, and when
    private var written: [UUID: (copy: SyncedList, at: Date)] = [:]
    /// How long a copy just written is given to show up in the folder as written, before it's written again
    var writeSettles: TimeInterval = 15
    /// How often the folders' devices are looked at, for one that has started using a folder
    var devicesLookedEvery: TimeInterval = 30
    private var devicesLooked = Date.distantPast

    init(model: AppModel) {
        self.model = model
    }

    /// Syncs every 3 seconds from now on, starting now
    func start() {
        if timer == nil {
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.run() }
            }
            timer.tolerance = 0.5
            // Common modes, so it keeps going while a list is scrolled
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        run()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Syncs now, or right after the pass that's going
    func run() {
        guard !running else {
            runAgain = true
            return
        }
        Task { await pass() }
    }

    /// Syncs once the pass that's going is done, and waits for it. A pass stuck on a file iCloud Drive is slow to hand
    /// over isn't waited for more than half a minute.
    func flush() async {
        let giveUp = Date().addingTimeInterval(30)
        while running && Date() < giveUp {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await pass()
    }

    /// One pass of syncing: reads every sync folder, merges what's in them, and writes this iPhone's copies
    func pass() async {
        guard let model, !running, !model.isSample else { return }
        let all = Set(model.folders.map(\.id))
        let folders = model.openFolders()
        guard !folders.isEmpty else {
            // None of the folders can be opened, which the lists that sync through them say
            model.synced(unreadable: all)
            return
        }
        running = true
        let card = DeviceCard(id: model.device, name: model.deviceName, seen: Date())
        await files.register(card, in: folders)
        let found = await files.read(folders)
        let changes = merge(found, folders: folders)
        for write in changes.writes {
            await files.write(write.copy, to: write.file)
        }
        for file in changes.deletes {
            await files.delete(file)
        }
        // A folder is unreadable when its bookmark wouldn't open, or what's in it couldn't be listed
        let still = Set(model.folders.map(\.id))
        model.synced(unreadable: all.subtracting(found.keys).intersection(still), read: still.intersection(found.keys))
        let now = Date()
        if now.timeIntervalSince(devicesLooked) >= devicesLookedEvery {
            devicesLooked = now
            for folder in folders where found[folder.id] != nil && still.contains(folder.id) {
                let there = await files.devicesListed(in: folder)
                model.noticed(there.cards, listed: there.ids, in: folder.id)
            }
        }
        running = false
        if runAgain {
            runAgain = false
            run()
        }
    }

    /// Stops syncing a list on this iPhone: writes its copy without tasks and without this iPhone in its devices, so the
    /// other devices hear that it no longer comes here. They keep the list.
    func leave(_ note: Note) {
        guard let model, let sync = note.sync,
              let folder = model.openFolders().first(where: { $0.id == sync.folder }),
              var copy = SyncedList(note.syncable, device: model.device) else { return }
        written[note.id] = nil
        copy.items = []
        copy.devices.removeAll { $0 == model.device }
        copy.devicesChanged = Date()
        model.remember(left: note.id, at: copy.devicesChanged)
        let file = folder.copy(of: note.id, by: model.device)
        let last = copy
        Task { await files.write(last, to: file) }
    }

    // MARK: A folder's lists

    /// The lists in a sync folder that other devices have and this iPhone doesn't, by name
    func lists(in folder: OpenFolder) async -> [FolderList] {
        guard let model else { return [] }
        let found = await files.read([folder])
        let cards = await files.devices(in: folder)
        let names = Dictionary(cards.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let here = Set(model.lists.map(\.id))
        let now = Date()
        var lists: [FolderList] = []
        for (id, copies) in found[folder.id] ?? [:] where !here.contains(id) {
            guard let merged = elsewhere(copies, me: model.device, now: now) else { continue }
            let note = Note(id: id, kind: .list, items: merged.items, name: merged.name)
            lists.append(FolderList(id: id, title: note.title, tasks: merged.items.count,
                                    devices: merged.devices.compactMap { names[$0] }))
        }
        return lists.sorted { ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }
    }

    /// A list's copies merged, if other devices still sync it and it doesn't come to this iPhone
    private func elsewhere(_ copies: [SyncedList], me: String, now: Date) -> SyncedList? {
        let others = copies.filter { $0.device != me }
        guard !others.isEmpty else { return nil }
        // This iPhone's copy counts when there is one, as it does for a list sent here
        let mine = copies.first { $0.device == me } ?? SyncedList(device: me)
        let merged = SyncMerge.merge([mine] + others, now: now)
        guard !merged.devices.isEmpty, !merged.devices.contains(me) else { return nil }
        return merged
    }

    /// Brings lists in a sync folder to this iPhone. It joins the devices each list goes to, the same as if it had
    /// been ticked on one of them, and its copy saying so is how they hear.
    func join(_ ids: [UUID], in folder: OpenFolder) async {
        guard let model else { return }
        let found = await files.read([folder])
        let now = Date()
        for id in ids where !model.lists.contains(where: { $0.id == id }) {
            guard let merged = elsewhere(found[folder.id]?[id] ?? [], me: model.device, now: now) else { continue }
            // Later than the change it follows, even if the other device's clock is ahead of this iPhone's
            let changed = max(now, merged.devicesChanged.addingTimeInterval(1))
            let sync = SyncInfo(folder: folder.id, devices: merged.devices + [model.device], devicesChanged: changed,
                                orderChanged: merged.orderChanged, deleted: merged.deleted,
                                nameChanged: merged.nameChanged)
            written[id] = nil
            model.forget(left: id)
            model.addSynced(Note(id: id, kind: .list, items: merged.items, name: merged.name, sync: sync))
        }
        await flush()
    }

    /// Merges what was read from the folders into the lists, and gives back this iPhone's copies to write and delete
    private func merge(_ found: [String: [UUID: [SyncedList]]], folders: [OpenFolder])
        -> (writes: [(copy: SyncedList, file: URL)], deletes: [URL]) {
        guard let model else { return ([], []) }
        let me = model.device
        let now = Date()
        var writes: [(copy: SyncedList, file: URL)] = []
        var deletes: [URL] = []

        for local in model.lists {
            guard let sync = local.sync, let folder = folders.first(where: { $0.id == sync.folder }),
                  let lists = found[folder.id], let mine = SyncedList(local.syncable, device: me) else { continue }
            let copies = lists[local.id] ?? []
            let others = copies.filter { $0.device != me }
            let merged = SyncMerge.merge([mine] + others, now: now)
            let file = folder.copy(of: local.id, by: me)

            // Another device took this iPhone off the list
            if !merged.devices.contains(me) {
                written[local.id] = nil
                model.removeSynced(local.id)
                deletes.append(file)
                continue
            }

            // The other devices' changes, with the empty tasks just opened here kept where they are
            var result = local.adopting(merged)
            result.items = local.items.showing(merged.items)
            if result != local {
                model.showSynced(result)
            }

            // This iPhone's copy is written whenever the folder doesn't have it as it is now. One just written may not
            // have been read back yet, or couldn't be written, so it's given a while before it's written again.
            let onDisk = copies.first { $0.device == me }
            guard onDisk != merged else { continue }
            if let last = written[local.id], last.copy == merged, now.timeIntervalSince(last.at) < writeSettles {
                continue
            }
            written[local.id] = (merged, now)
            writes.append((merged, file))
        }

        // Lists sent here from another device
        let here = Set(model.lists.map(\.id))
        for folder in folders {
            for (id, copies) in found[folder.id] ?? [:] where !here.contains(id) {
                let others = copies.filter { $0.device != me }
                guard !others.isEmpty else { continue }
                // This iPhone's own copy counts when there is one. After the list was deleted here, it's what says the
                // list no longer comes here, until the other devices have heard and say so too.
                let mine = copies.first { $0.device == me }
                let merged = SyncMerge.merge([mine ?? SyncedList(device: me)] + others, now: now)
                guard merged.devices.contains(me) else { continue }
                if let when = model.left[id], merged.devicesChanged <= when {
                    // A copy written before it left landed after the one saying it left: say so again
                    if let mine, mine.devices.contains(me) {
                        var copy = mine
                        copy.items = []
                        copy.devices.removeAll { $0 == me }
                        copy.devicesChanged = when
                        writes.append((copy, folder.copy(of: id, by: me)))
                    }
                    continue
                }
                model.forget(left: id)
                let sync = SyncInfo(folder: folder.id, devices: merged.devices, devicesChanged: merged.devicesChanged,
                                    orderChanged: merged.orderChanged, deleted: merged.deleted,
                                    nameChanged: merged.nameChanged)
                model.addSynced(Note(id: id, kind: .list, items: merged.items, name: merged.name, sync: sync))
                if mine != merged {
                    written[id] = (merged, now)
                    writes.append((merged, folder.copy(of: id, by: me)))
                }
            }
        }
        return (writes, deletes)
    }
}
