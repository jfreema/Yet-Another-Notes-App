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
    /// A sync folder stopped being readable, or started again, so the tabs' sync marks may be out of date
    func syncStateChanged()
    /// A device started using a sync folder that lists here sync through, so they can be sent to it
    func offer(_ device: DeviceCard, in folder: SyncFolder)
}

extension SyncHost {
    func syncStateChanged() {}
    func offer(_ device: DeviceCard, in folder: SyncFolder) {}
}

/// Whether a synced list is syncing
enum SyncState: Equatable {
    case working
    /// Its sync folder can't be read, or isn't one this Mac uses any more. `last` is when it was last read.
    case stopped(folder: String?, last: Date?)

    /// What's wrong, to say on the list's tab and in its sync settings. Nil while it's working.
    func problem(now: Date = Date()) -> String? {
        guard case .stopped(let folder, let last) = self else { return nil }
        var text = folder.map { "YANA can't open its sync folder, “\($0)”, so it isn't syncing." }
            ?? "Its sync folder isn't one this Mac uses any more, so it isn't syncing."
        if let last {
            // This Mac's clock may have been set back since
            text += " It last synced \(min(last, now).formatted(.relative(presentation: .named)))."
        }
        return text
    }
}

/// A list in a sync folder that other devices have and this Mac doesn't
struct FolderList: Equatable, Sendable {
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

/// Syncs to-do lists through sync folders. Every few seconds, and right after a change here, it reads the other
/// devices' copies of each synced list, merges them with this Mac's copy, shows the result, and writes this Mac's copy
/// when it has changed. Lists another device sends here get a tab of their own. It also keeps track of which folders
/// could be read, for the tabs' sync marks, and notices a device that starts using a folder.
@MainActor
final class ListSync {
    weak var host: SyncHost?
    /// The sync folders this Mac uses. The tests give their own.
    var folders: () -> [SyncFolder] = { SyncFolders.all }
    private let files = SyncFiles()
    /// Where what's remembered between launches is kept. The tests give their own.
    private let defaults: UserDefaults
    private var timer: Timer?
    private var reading = false
    /// Each synced list as last saved, shown or merged, to tell what's changed since by comparing
    private var known: [UUID: Note] = [:]
    /// Each list's copy as this Mac last wrote it, and when
    private var written: [UUID: (copy: SyncedList, at: Date)] = [:]

    /// The lists this Mac stopped syncing, with when, so one whose tab was deleted doesn't come straight back
    private var left: [UUID: Date] = [:]

    /// How long a copy just written is given to show up in the folder as written, before it's written again
    var writeSettles: TimeInterval = 15

    /// The folders as of the last look: their names by id, and the ones that couldn't be read
    private var folderNames: [String: String] = [:]
    private var unread: Set<String> = []
    /// Whether the folders have been looked at yet. Until then every list counts as syncing.
    private var looked = false
    /// When each folder was last read, by its id, kept between launches so a list that's stopped can say when it
    /// last synced
    private var lastRead: [String: Date]
    private var lastReadSaved = Date.distantPast

    /// How often the folders' devices are looked at, for one that's new
    var devicesLookedEvery: TimeInterval = 30
    private var devicesLooked = Date.distantPast

    private enum Key {
        static let lastRead = "syncLastRead"
        static let devices = "syncKnownDevices"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastRead = (defaults.dictionary(forKey: Key.lastRead) as? [String: Date]) ?? [:]
    }

    func start() {
        let me = DeviceCard(id: ThisDevice.id, name: ThisDevice.name, seen: Date())
        let folders = self.folders()
        Task { await files.register(me, in: folders) }
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
        timer.tolerance = 0.5
        self.timer = timer
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
        // A name it already has goes with it
        note.sync = SyncInfo(folder: folder.id, devices: [ThisDevice.id] + devices, devicesChanged: now,
                             orderChanged: now, deleted: [:], nameChanged: note.name == nil ? nil : now)
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
        guard let folder = folders().first(where: { $0.id == note.sync?.folder }),
              var copy = SyncedList(note, device: ThisDevice.id) else { return }
        copy.items = []
        copy.devices.removeAll { $0 == ThisDevice.id }
        copy.devicesChanged = Date()
        left[note.id] = copy.devicesChanged
        let file = folder.copy(of: note.id, by: ThisDevice.id)
        let last = copy
        Task { await files.write(last, to: file) }
    }

    // MARK: Syncing

    /// Syncs now, unless it already is
    func run() {
        guard !reading else { return }
        guard !folders().isEmpty else { return took([], found: [:]) }
        Task { await pass() }
    }

    /// One pass of syncing: reads every sync folder, merges what's in them, and writes this Mac's copies
    func pass() async {
        let folders = self.folders()
        guard !reading else { return }
        guard !folders.isEmpty else { return took([], found: [:]) }
        reading = true
        let found = await files.read(folders)
        reading = false
        took(folders, found: found)
        for write in merge(found, folders: folders) {
            await files.write(write.copy, to: write.file)
        }
        let now = Date()
        if now.timeIntervalSince(devicesLooked) >= devicesLookedEvery {
            devicesLooked = now
            noticed(await files.cards(in: folders), in: folders)
        }
    }

    // MARK: Whether it's working

    /// Whether a tab's list is syncing. Nil for a tab that doesn't sync.
    func state(of page: NotePage) -> SyncState? {
        guard let sync = page.sync else { return nil }
        guard looked else { return .working }
        guard let name = folderNames[sync.folder] else { return .stopped(folder: nil, last: lastRead[sync.folder]) }
        return unread.contains(sync.folder) ? .stopped(folder: name, last: lastRead[sync.folder]) : .working
    }

    /// Takes note of which folders were read just now, and tells the host when one stops or starts being readable
    private func took(_ folders: [SyncFolder], found: [String: [UUID: [SyncedList]]]) {
        let now = Date()
        var names: [String: String] = [:]
        var stopped: Set<String> = []
        var read = false
        for folder in folders {
            names[folder.id] = folder.name
            if found[folder.id] == nil {
                stopped.insert(folder.id)
            } else {
                lastRead[folder.id] = now
                read = true
            }
        }
        let changed = !looked || stopped != unread || names != folderNames
        looked = true
        unread = stopped
        folderNames = names
        // Saved about once a minute, so a list that has stopped can say when it last synced after YANA reopens
        if read, changed || now.timeIntervalSince(lastReadSaved) >= 60 {
            lastReadSaved = now
            defaults.set(lastRead, forKey: Key.lastRead)
        }
        if changed { host?.syncStateChanged() }
    }

    // MARK: A folder's lists, and its devices

    /// The lists in a sync folder that other devices have and this Mac doesn't, by name
    func lists(in folder: SyncFolder) async -> [FolderList] {
        let found = await files.read([folder])
        let cards = await files.cards(in: [folder])[folder.id] ?? []
        let names = Dictionary(cards.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let here = Set(host?.notePages.map { $0.id } ?? [])
        let now = Date()
        var lists: [FolderList] = []
        for (id, copies) in found[folder.id] ?? [:] where !here.contains(id) {
            guard let merged = elsewhere(copies, now: now) else { continue }
            let note = Note(id: id, kind: .list, items: merged.items, name: merged.name)
            lists.append(FolderList(id: id, title: note.title, tasks: merged.items.count,
                                    devices: merged.devices.compactMap { names[$0] }))
        }
        return lists.sorted { ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }
    }

    /// A list's copies merged, if other devices still sync it and it doesn't come to this Mac
    private func elsewhere(_ copies: [SyncedList], now: Date) -> SyncedList? {
        let me = ThisDevice.id
        let others = copies.filter { $0.device != me }
        guard !others.isEmpty else { return nil }
        // This Mac's copy counts when there is one, as it does for a list sent here
        let mine = copies.first { $0.device == me } ?? SyncedList(device: me)
        let merged = SyncMerge.merge([mine] + others, now: now)
        guard !merged.devices.isEmpty, !merged.devices.contains(me) else { return nil }
        return merged
    }

    /// Brings lists in a sync folder to this Mac, each in a tab of its own. This Mac joins the devices each list goes
    /// to, the same as if it had been ticked on one of them.
    func join(_ ids: [UUID], in folder: SyncFolder) async {
        guard let host else { return }
        let found = await files.read([folder])
        let now = Date()
        for id in ids where !host.notePages.contains(where: { $0.id == id }) {
            guard let merged = elsewhere(found[folder.id]?[id] ?? [], now: now) else { continue }
            // Later than the change it follows, even if the other device's clock is ahead of this Mac's
            let changed = max(now, merged.devicesChanged.addingTimeInterval(1))
            let sync = SyncInfo(folder: folder.id, devices: merged.devices + [ThisDevice.id], devicesChanged: changed,
                                orderChanged: merged.orderChanged, deleted: merged.deleted,
                                nameChanged: merged.nameChanged)
            let note = Note(id: id, kind: .list, items: merged.items, name: merged.name, sync: sync)
            known[id] = note
            left[id] = nil
            logger.notice("Bringing a list in a sync folder to this Mac")
            host.addSynced(note)
        }
        // Writes this Mac's copies, which is how the other devices hear
        await pass()
    }

    /// The lists here that sync through `folder` and don't go to `device` yet
    func lists(notGoingTo device: String, in folder: SyncFolder) -> [NotePage] {
        (host?.notePages ?? []).filter { page in
            guard let sync = page.sync else { return false }
            return sync.folder == folder.id && !sync.devices.contains(device)
        }
    }

    /// Tells the host about a device that has started using a folder since the last look, when lists here could go to
    /// it. The first look at a folder only remembers who's there: they were there before anything could be offered.
    private func noticed(_ cards: [String: [DeviceCard]], in folders: [SyncFolder]) {
        var known = (defaults.dictionary(forKey: Key.devices) as? [String: [String]]) ?? [:]
        var offers: [(DeviceCard, SyncFolder)] = []
        var changed = false
        for folder in folders {
            guard let there = cards[folder.id] else { continue }
            guard let before = known[folder.id] else {
                known[folder.id] = there.map(\.id)
                changed = true
                continue
            }
            let new = there.filter { $0.id != ThisDevice.id && !before.contains($0.id) }
            guard !new.isEmpty else { continue }
            known[folder.id] = before + new.map(\.id)
            changed = true
            offers += new.filter { !lists(notGoingTo: $0.id, in: folder).isEmpty }.map { ($0, folder) }
        }
        if changed { defaults.set(known, forKey: Key.devices) }
        for (device, folder) in offers {
            logger.notice("A new device uses a sync folder")
            host?.offer(device, in: folder)
        }
    }

    /// Merges what was read from the folders into the tabs, and gives back this Mac's copies to write
    private func merge(_ found: [String: [UUID: [SyncedList]]],
                       folders: [SyncFolder]) -> [(copy: SyncedList, file: URL)] {
        guard let host else { return [] }
        let me = ThisDevice.id
        let now = Date()
        var writes: [(copy: SyncedList, file: URL)] = []

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
            if !result.items.looksLike(local.items) || result.name != local.name {
                // Only a task under the mouse makes the others' changes wait, and only until the mouse comes up. A
                // task with the cursor in it doesn't: the cursor can sit there for hours, and then nothing would sync.
                if (page as? TodoList)?.isDragging == true { continue }
                known[local.id] = result
                logger.info("Showing other devices' changes to a synced list")
                host.showSynced(result, on: page)
            } else {
                known[local.id] = result
                page.sync = result.sync
            }

            // This Mac's copy is written whenever the folder doesn't have it as it is now. One just written may not have
            // been read back yet, or couldn't be written, so it's given a while before it's written again.
            let onDisk = copies.first { $0.device == me }
            guard onDisk != merged else { continue }
            if let last = written[local.id], last.copy == merged,
               now.timeIntervalSince(last.at) < writeSettles { continue }
            written[local.id] = (merged, now)
            writes.append((merged, file))
        }

        // Lists sent here from another device
        let here = Set(host.notePages.map { $0.id })
        for folder in folders {
            for (id, copies) in found[folder.id] ?? [:] where !here.contains(id) {
                let others = copies.filter { $0.device != me }
                guard !others.isEmpty else { continue }
                // This Mac's own copy counts when there is one. After the list's tab was deleted here, it's what says
                // the list no longer comes here, until the other devices have heard and say so too.
                let mine = copies.first { $0.device == me } ?? SyncedList(device: me)
                let merged = SyncMerge.merge([mine] + others, now: now)
                guard merged.devices.contains(me) else { continue }
                // Read before this Mac's copy said it had left
                if let when = left[id], merged.devicesChanged <= when { continue }
                left[id] = nil
                let sync = SyncInfo(folder: folder.id, devices: merged.devices, devicesChanged: merged.devicesChanged,
                                    orderChanged: merged.orderChanged, deleted: merged.deleted,
                                    nameChanged: merged.nameChanged)
                let note = Note(id: id, kind: .list, items: merged.items, name: merged.name, sync: sync)
                known[id] = note
                logger.notice("Adding a list another device syncs here")
                host.addSynced(note)
            }
        }
        return writes
    }
}

/// Reads and writes the sync folders, away from the main thread, since a file in iCloud Drive may have to download
actor SyncFiles {
    /// Copies already read, by path, with what was in the file, so one that hasn't changed isn't worked out again. The
    /// file is read each time: its modification date can't tell whether it changed, since a sync service may keep dates
    /// only to the second, and two changes in the same second would look like one.
    private var cache: [String: (data: Data, list: SyncedList)] = [:]
    /// The folders that couldn't be read last time, so each is logged once, not every few seconds
    private var unreadable: Set<String> = []

    /// Every list in every folder: folder id → list id → the devices' copies. A folder that can't be read is left out.
    func read(_ folders: [SyncFolder]) -> [String: [UUID: [SyncedList]]] {
        let manager = FileManager.default
        var found: [String: [UUID: [SyncedList]]] = [:]
        for folder in folders {
            let lists: [URL]
            do {
                lists = try manager.contentsOfDirectory(at: folder.listsFolder, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
                unreadable.remove(folder.id)
            } catch {
                if unreadable.insert(folder.id).inserted {
                    logger.error("Couldn't read a sync folder: \(error.localizedDescription, privacy: .public)")
                }
                // A folder that's there but has lost its lists folder has no lists yet, and writing one makes it again
                guard manager.fileExists(atPath: folder.url.path) else { continue }
                lists = []
            }
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
        guard let data = try? Data(contentsOf: file) else { return nil }
        if let cached = cache[file.path], cached.data == data { return cached.list }
        guard let list = try? JSONDecoder().decode(SyncedList.self, from: data) else { return nil }
        cache[file.path] = (data, list)
        return list
    }

    /// Whether it was written
    @discardableResult
    func write(_ list: SyncedList, to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try list.encoded().write(to: file, options: .atomic)
            return true
        } catch {
            logger.error("Couldn't write a synced list: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func delete(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        cache[file.path] = nil
    }

    /// The devices that use each folder, by the folder's id. A folder whose devices can't be listed is left out.
    func cards(in folders: [SyncFolder]) -> [String: [DeviceCard]] {
        var cards: [String: [DeviceCard]] = [:]
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder.devicesFolder,
                                                                           includingPropertiesForKeys: nil,
                                                                           options: [.skipsHiddenFiles]) else { continue }
            cards[folder.id] = files.filter { $0.pathExtension == "json" }
                .compactMap { try? JSONDecoder().decode(DeviceCard.self, from: Data(contentsOf: $0)) }
                .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        }
        return cards
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
