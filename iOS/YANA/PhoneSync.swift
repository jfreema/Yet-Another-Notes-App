import Foundation

/// Syncs this iPhone's lists through the sync folders, the same way YANA on the Mac does (ListSync there): what a pass
/// does is worked out by `SyncPass`, which both apps use, and this class reads and writes the files and hands the
/// result to the model. While YANA is open it syncs when a folder says something in it changed, soon after each change
/// here, every few seconds while iCloud Drive is still bringing a file down, about twice a minute besides, and once
/// more as it goes to the background. Nothing syncs while YANA isn't open: the other devices' changes come in when
/// it's next opened. It also tells the model which folders it could read, and about a device that starts using one.
@MainActor
final class PhoneSync {
    private weak var model: AppModel?
    let files = PhoneFiles()
    private var timer: Timer?
    private(set) var running = false
    private var runAgain = false
    /// Works out each pass, and remembers each list's copy as this iPhone last wrote it
    private var engine: SyncPass
    /// How long a copy just written is given to show up in the folder as written, before it's written again
    var writeSettles: TimeInterval {
        get { engine.writeSettles }
        set { engine.writeSettles = newValue }
    }
    /// How often the folders' devices are looked at, for one that has started using a folder
    var devicesLookedEvery: TimeInterval = 30
    private var devicesLooked = Date.distantPast

    /// How often the folders are read when nothing says they've changed. It catches a change iOS didn't report.
    var readEvery: TimeInterval = 30
    /// How long a folder's changes are gathered before they're read, so a burst of them is read once
    var changesGathered: TimeInterval = 0.7
    /// How soon the folders are read again while iCloud Drive is bringing a file down
    var downloadsCheckedEvery: TimeInterval = 3
    /// Says when something changes in each sync folder, by the folder's id, while YANA is open
    private var presenters: [String: FolderPresenter] = [:]
    private var changeSoon: Task<Void, Never>?
    private var downloadSoon: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        engine = SyncPass(device: model.device)
    }

    /// Whether YANA is open and syncing as things change
    private var started: Bool { timer != nil }

    /// Syncs from now on, starting now: when a sync folder changes, and every `readEvery` besides
    func start() {
        if timer == nil {
            let timer = Timer(timeInterval: readEvery, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.run() }
            }
            timer.tolerance = readEvery / 6
            // Common modes, so it keeps going while a list is scrolled
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        run()
    }

    /// Stops syncing as things change, as YANA goes to the background. iOS doesn't tell an app in the background
    /// about a folder's changes, and expects it to have stopped asking.
    func stop() {
        timer?.invalidate()
        timer = nil
        changeSoon?.cancel()
        changeSoon = nil
        downloadSoon?.cancel()
        downloadSoon = nil
        for presenter in presenters.values {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presenters = [:]
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
        watch(folders)
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
        let downloading = await files.askedForDownloads()
        running = false
        if runAgain {
            runAgain = false
            run()
        } else if downloading {
            downloadsComing()
        }
    }

    // MARK: When a folder changes

    /// Asks iOS to say when something changes in each of these folders, and stops asking about any other. Only while
    /// YANA is open: a pass run as it goes to the background doesn't ask.
    private func watch(_ folders: [OpenFolder]) {
        guard started else { return }
        for (id, presenter) in presenters where !folders.contains(where: { $0.id == id && $0.url == presenter.url }) {
            NSFileCoordinator.removeFilePresenter(presenter)
            presenters[id] = nil
        }
        for folder in folders where presenters[folder.id] == nil {
            let presenter = FolderPresenter(folder.url) { [weak self] in
                Task { @MainActor in self?.folderChanged() }
            }
            NSFileCoordinator.addFilePresenter(presenter)
            presenters[folder.id] = presenter
        }
    }

    /// Something changed in a sync folder: syncs in a moment, once for a burst of changes
    private func folderChanged() {
        guard started, changeSoon == nil else { return }
        let wait = changesGathered
        changeSoon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            // Stopped meanwhile, as YANA went to the background
            guard let self, !Task.isCancelled else { return }
            self.changeSoon = nil
            if self.started { self.run() }
        }
    }

    /// iCloud Drive is bringing a file down, and may not say when it's here: syncs again in a few seconds
    private func downloadsComing() {
        guard started, downloadSoon == nil else { return }
        let wait = downloadsCheckedEvery
        downloadSoon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            // Stopped meanwhile, as YANA went to the background
            guard let self, !Task.isCancelled else { return }
            self.downloadSoon = nil
            if self.started { self.run() }
        }
    }

    // MARK: Starting and stopping a list

    /// Stops syncing a list on this iPhone: writes its copy without tasks and without this iPhone in its devices, so the
    /// other devices hear that it no longer comes here. They keep the list.
    func leave(_ note: Note) {
        guard let model, let sync = note.sync,
              let folder = model.openFolders().first(where: { $0.id == sync.folder }),
              let copy = SyncedList(note.syncable, device: model.device)?.leaving(at: Date()) else { return }
        engine.forget(note.id)
        model.remember(left: note.id, at: copy.devicesChanged)
        let file = folder.copy(of: note.id, by: model.device)
        Task { await files.write(copy, to: file) }
    }

    // MARK: A folder's lists and devices, for the screens that show them

    /// The lists in a sync folder that other devices have and this iPhone doesn't, by name
    func lists(in folder: OpenFolder) async -> [FolderList] {
        guard let model else { return [] }
        let found = await files.read([folder])
        let cards = await files.devices(in: folder)
        if await files.askedForDownloads() { downloadsComing() }
        let names = Dictionary(cards.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return engine.lists(in: found[folder.id] ?? [:], here: Set(model.lists.map(\.id)), names: names, now: Date())
    }

    /// The devices that use a sync folder, newest first
    func devices(in folder: OpenFolder) async -> [DeviceCard] {
        let cards = await files.devices(in: folder)
        // A screen showing them looks again after the sync that follows, when a card was still on its way
        if await files.askedForDownloads() { downloadsComing() }
        return cards
    }

    /// Brings lists in a sync folder to this iPhone. It joins the devices each list goes to, the same as if it had
    /// been ticked on one of them, and its copy saying so is how they hear.
    func join(_ ids: [UUID], in folder: OpenFolder) async {
        guard let model else { return }
        let found = await files.read([folder])
        let now = Date()
        for id in ids where !model.lists.contains(where: { $0.id == id }) {
            guard let note = engine.joining(id, from: found[folder.id]?[id] ?? [], in: folder.id, now: now) else {
                continue
            }
            model.forget(left: id)
            model.addSynced(note)
        }
        await flush()
    }

    /// Merges what was read from the folders into the lists, and gives back this iPhone's copies to write and delete
    private func merge(_ found: FoundLists, folders: [OpenFolder])
        -> (writes: [(copy: SyncedList, file: URL)], deletes: [URL]) {
        guard let model else { return ([], []) }
        let me = model.device
        let changes = engine.run(lists: model.lists.filter { $0.sync != nil }, here: Set(model.lists.map(\.id)),
                                 folders: folders.map(\.id), found: found, left: model.left, now: Date())
        // Another device took this iPhone off these
        for id in changes.removed {
            model.removeSynced(id)
        }
        for merged in changes.merged {
            model.showSynced(merged.note)
        }
        for note in changes.added {
            model.forget(left: note.id)
            model.addSynced(note)
        }

        let places = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var writes: [(copy: SyncedList, file: URL)] = []
        for write in changes.writes {
            guard let folder = places[write.folder] else { continue }
            writes.append((copy: write.copy, file: folder.copy(of: write.list, by: me)))
        }
        var deletes: [URL] = []
        for delete in changes.deletes {
            guard let folder = places[delete.folder] else { continue }
            deletes.append(folder.copy(of: delete.list, by: me))
        }
        return (writes, deletes)
    }
}

/// Hears from iOS when something changes in a sync folder, or in a folder inside it, and says so. iOS tells an app
/// that presents a folder about the changes other apps make to it with file coordination, which is how iCloud Drive
/// brings in a file from another device.
final class FolderPresenter: NSObject, NSFilePresenter {
    let url: URL
    private let changed: @Sendable () -> Void
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(_ url: URL, changed: @escaping @Sendable () -> Void) {
        self.url = url
        self.changed = changed
        super.init()
    }

    var presentedItemURL: URL? { url }
    var presentedItemOperationQueue: OperationQueue { queue }

    func presentedItemDidChange() {
        changed()
    }

    func presentedSubitemDidAppear(at url: URL) {
        changed()
    }

    func presentedSubitemDidChange(at url: URL) {
        changed()
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        changed()
    }

    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
        changed()
    }
}
