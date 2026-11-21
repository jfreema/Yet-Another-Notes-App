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

/// Syncs to-do lists through sync folders. When a folder says something in it changed, right after a change here, and
/// about once a minute besides, it reads the other devices' copies of each synced list, merges them with this Mac's
/// copy, shows the result, and writes this Mac's copy when it has changed. Lists another device sends here get a tab
/// of their own. What a pass does is worked out by `SyncPass`, which YANA for iPhone uses too: this class reads and
/// writes the files, and shows the result. It also keeps track of which folders could be read, for the tabs' sync
/// marks, and notices a device that starts using a folder.
@MainActor
final class ListSync {
    weak var host: SyncHost?
    /// The sync folders this Mac uses. The tests give their own.
    var folders: () -> [SyncFolder] = { SyncFolders.all }
    private let files = SyncFiles()
    /// Where what's remembered between launches is kept. The tests give their own.
    private let defaults: UserDefaults
    private var timer: Timer?
    /// Says when something changes in a sync folder, once syncing has started
    private var watcher: FolderWatcher?
    private var reading = false
    /// Whether a sync was asked for while one was reading the folders, so another follows it
    private var again = false
    /// Each synced list as last saved, shown or merged, to tell what's changed since by comparing
    private var known: [UUID: Note] = [:]
    /// Works out each pass, and remembers each list's copy as this Mac last wrote it
    private var engine = SyncPass(device: ThisDevice.id)

    /// The lists this Mac stopped syncing, with when, so one whose tab was deleted doesn't come straight back. Kept
    /// between launches, for as long as a deleted task is.
    private var left: [UUID: Date] = [:]

    /// How long a copy just written is given to show up in the folder as written, before it's written again
    var writeSettles: TimeInterval {
        get { engine.writeSettles }
        set { engine.writeSettles = newValue }
    }

    /// How often the folders are read when nothing says they've changed. It catches a sync service that doesn't say.
    var readEvery: TimeInterval = 60
    /// How long a folder's changes are gathered before they're read, so a burst of them is read once
    var changesGathered: TimeInterval = 1

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
        static let left = "syncLeft"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastRead = (defaults.dictionary(forKey: Key.lastRead) as? [String: Date]) ?? [:]
        let forgotten = Date().addingTimeInterval(-SyncMerge.deletionsKept)
        for (key, date) in (defaults.dictionary(forKey: Key.left) as? [String: Date]) ?? [:] where date > forgotten {
            if let id = UUID(uuidString: key) { left[id] = date }
        }
    }

    /// Starts syncing: now, whenever a sync folder says something in it changed, and every `readEvery` besides
    func start() {
        let me = DeviceCard(id: ThisDevice.id, name: ThisDevice.name, seen: Date())
        let folders = self.folders()
        Task { await files.register(me, in: folders) }
        let watcher = FolderWatcher(latency: changesGathered) { [weak self] in self?.run() }
        watcher.watch(folders.map(\.url.path))
        self.watcher = watcher
        let timer = Timer.scheduledTimer(withTimeInterval: readEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
        timer.tolerance = readEvery / 6
        self.timer = timer
        // Not before the window that starts it has finished setting up
        Task { [weak self] in await self?.pass() }
    }

    /// Stops what `start` started. YANA syncs for as long as it runs, so only the tests stop.
    func stop() {
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
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
        let note = page.note.startingToSync(in: folder.id, from: ThisDevice.id, to: devices, at: now)
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
        engine.forget(note.id)
        guard let folder = folders().first(where: { $0.id == note.sync?.folder }),
              let copy = SyncedList(note, device: ThisDevice.id)?.leaving(at: Date()) else { return }
        remember(left: note.id, at: copy.devicesChanged)
        let file = folder.copy(of: note.id, by: ThisDevice.id)
        Task { await files.write(copy, to: file) }
    }

    /// Remembers when this Mac stopped syncing a list, or with no date, that it syncs it again
    private func remember(left id: UUID, at date: Date?) {
        guard left[id] != date else { return }
        left[id] = date
        defaults.set(Dictionary(uniqueKeysWithValues: left.map { ($0.key.uuidString, $0.value) }), forKey: Key.left)
    }

    // MARK: Syncing

    /// Syncs now. If the folders are being read already, it syncs again once that's done, since what was read may
    /// have changed since.
    func run() {
        guard !reading else {
            again = true
            return
        }
        guard !folders().isEmpty else { return took([], found: [:]) }
        Task { await pass() }
    }

    /// One pass of syncing: reads every sync folder, merges what's in them, and writes this Mac's copies
    func pass() async {
        let folders = self.folders()
        guard !reading else { return }
        // The folders may not be the ones watched so far
        watcher?.watch(folders.map(\.url.path))
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
        if again {
            again = false
            run()
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
    private func took(_ folders: [SyncFolder], found: FoundLists) {
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
        return engine.lists(in: found[folder.id] ?? [:], here: here, names: names, now: Date())
    }

    /// Brings lists in a sync folder to this Mac, each in a tab of its own. This Mac joins the devices each list goes
    /// to, the same as if it had been ticked on one of them.
    func join(_ ids: [UUID], in folder: SyncFolder) async {
        guard let host else { return }
        let found = await files.read([folder])
        let now = Date()
        for id in ids where !host.notePages.contains(where: { $0.id == id }) {
            guard let note = engine.joining(id, from: found[folder.id]?[id] ?? [], in: folder.id, now: now) else {
                continue
            }
            known[id] = note
            remember(left: id, at: nil)
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
            let look = engine.noticed(there, listed: there.map(\.id), before: known[folder.id])
            if look.known != known[folder.id] {
                known[folder.id] = look.known
                changed = true
            }
            offers += look.new.filter { !lists(notGoingTo: $0.id, in: folder).isEmpty }.map { ($0, folder) }
        }
        if changed { defaults.set(known, forKey: Key.devices) }
        for (device, folder) in offers {
            logger.notice("A new device uses a sync folder")
            host?.offer(device, in: folder)
        }
    }

    /// Merges what was read from the folders into the tabs, and gives back this Mac's copies to write
    private func merge(_ found: FoundLists, folders: [SyncFolder]) -> [(copy: SyncedList, file: URL)] {
        guard let host else { return [] }
        let me = ThisDevice.id
        // Only the synced lists are looked at, so a pass doesn't copy out the text of every note
        let pages = host.notePages
        var synced: [UUID: NotePage] = [:]
        var lists: [Note] = []
        var waiting: Set<UUID> = []
        for page in pages where page.sync != nil {
            let local = note(of: page)
            guard local.kind == .list, synced[local.id] == nil else { continue }
            synced[local.id] = page
            lists.append(local)
            // Only a task under the mouse makes the others' changes wait, and only until the mouse comes up. A task
            // with the cursor in it doesn't: the cursor can sit there for hours, and then nothing would sync.
            if (page as? TodoList)?.isDragging == true { waiting.insert(local.id) }
        }
        let changes = engine.run(lists: lists, here: Set(pages.map { $0.id }), folders: folders.map(\.id), found: found,
                                 left: left, waiting: waiting, now: Date())

        // Another device took this Mac off these
        for id in changes.removed {
            known[id] = nil
            if let page = synced[id] { host.removeSynced(page) }
        }
        for merged in changes.merged {
            guard let page = synced[merged.note.id] else { continue }
            known[merged.note.id] = merged.note
            if merged.looksDifferent {
                logger.info("Showing other devices' changes to a synced list")
                host.showSynced(merged.note, on: page)
            } else {
                page.sync = merged.note.sync
            }
        }
        for note in changes.added {
            known[note.id] = note
            remember(left: note.id, at: nil)
            logger.notice("Adding a list another device syncs here")
            host.addSynced(note)
        }

        let places = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for delete in changes.deletes {
            guard let file = places[delete.folder]?.copy(of: delete.list, by: me) else { continue }
            Task { await files.delete(file) }
        }
        var writes: [(copy: SyncedList, file: URL)] = []
        for write in changes.writes {
            guard let folder = places[write.folder] else { continue }
            writes.append((copy: write.copy, file: folder.copy(of: write.list, by: me)))
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
    func read(_ folders: [SyncFolder]) -> FoundLists {
        let manager = FileManager.default
        var found: FoundLists = [:]
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
