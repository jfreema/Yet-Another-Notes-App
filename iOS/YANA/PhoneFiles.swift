import Foundation

/// Reads and writes the sync folders, away from the main thread.
///
/// A sync folder on an iPhone is usually in iCloud Drive, where a file may not be on the iPhone yet. iOS lists one of
/// those as ".<name>.icloud": it's asked for here and read on a later pass, rather than waited for. A file that's on
/// the iPhone but out of date is asked for too, and read as it is meanwhile. Reads and writes are coordinated, as
/// iOS expects of an app using files in a folder it doesn't own.
actor PhoneFiles {
    /// Copies already read, by path, with what was in the file, so one that hasn't changed isn't decoded again, and one
    /// that's being downloaded still counts as what it was
    private var cache: [String: (data: Data, list: SyncedList)] = [:]
    /// When this iPhone's card was last checked in each folder, and under what name
    private var registered: [String: (name: String, at: Date)] = [:]
    /// Whether a file was found that iCloud Drive hasn't brought down, or not as it is now, since this was last asked
    private var asked = false

    /// Whether iCloud Drive was asked for a file since the last time this was asked. While it's bringing one down,
    /// the folders are worth reading again soon: it may not say when the file is here.
    func askedForDownloads() -> Bool {
        defer { asked = false }
        return asked
    }

    /// Every list in every folder: folder id → list id → the devices' copies. A folder that can't be read is left out.
    func read(_ folders: [OpenFolder]) -> FoundLists {
        var found: FoundLists = [:]
        for folder in folders {
            let lists: [URL]
            if let contents = Self.contents(of: folder.listsFolder) {
                lists = contents
            } else if FileManager.default.fileExists(atPath: folder.url.path) {
                // There, but without a lists folder yet: writing a list makes it
                lists = []
            } else {
                continue
            }
            var copies: [UUID: [SyncedList]] = [:]
            for list in lists {
                guard let id = UUID(uuidString: list.lastPathComponent), let files = Self.contents(of: list) else { continue }
                var seen: Set<String> = []
                var listCopies: [SyncedList] = []
                for listed in files {
                    guard let found = Self.jsonFile(listed), seen.insert(found.file.path).inserted else { continue }
                    if !found.onPhone { asked = true }
                    guard let copy = read(found.file, onPhone: found.onPhone) else { continue }
                    listCopies.append(copy)
                }
                copies[id] = listCopies
            }
            found[folder.id] = copies
        }
        return found
    }

    private func read(_ file: URL, onPhone: Bool) -> SyncedList? {
        guard onPhone else { return cache[file.path]?.list }
        let download = Self.download(of: file)
        if !download.current { asked = true }
        guard download.readable, let data = Self.coordinatedRead(file) else { return cache[file.path]?.list }
        if let cached = cache[file.path], cached.data == data { return cached.list }
        guard let list = try? JSONDecoder().decode(SyncedList.self, from: data) else { return nil }
        cache[file.path] = (data, list)
        return list
    }

    /// Whether it was written
    @discardableResult
    func write(_ list: SyncedList, to file: URL) -> Bool {
        guard let data = try? list.encoded() else { return false }
        cache[file.path] = nil
        return Self.coordinatedWrite(data, to: file)
    }

    func delete(_ file: URL) {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: .forDeleting, error: &error) { url in
            try? FileManager.default.removeItem(at: url)
        }
        cache[file.path] = nil
    }

    /// Writes this iPhone's card in each folder, so other devices can send lists to it, if it's missing, renamed or a
    /// day old. It's checked once an hour, or right away after a rename.
    func register(_ card: DeviceCard, in folders: [OpenFolder]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for folder in folders {
            if let last = registered[folder.id], last.name == card.name, card.seen.timeIntervalSince(last.at) < 60 * 60 {
                continue
            }
            let file = folder.card(of: card.id)
            if let data = Self.coordinatedRead(file), let old = try? JSONDecoder().decode(DeviceCard.self, from: data),
               old.name == card.name, card.seen.timeIntervalSince(old.seen) < 24 * 60 * 60 {
                registered[folder.id] = (card.name, card.seen)
                continue
            }
            if let data = try? encoder.encode(card), Self.coordinatedWrite(data, to: file) {
                registered[folder.id] = (card.name, card.seen)
            }
        }
    }

    /// The devices that use a folder, newest first, read from its devices folder
    func devices(in folder: OpenFolder) -> [DeviceCard] {
        devicesListed(in: folder).cards
    }

    /// The devices that use a folder: the cards that can be read now, newest first, and the id of every device listed
    /// there, whether or not iCloud Drive has downloaded its card yet
    func devicesListed(in folder: OpenFolder) -> (cards: [DeviceCard], ids: [String]) {
        var cards: [DeviceCard] = []
        var ids: [String] = []
        for listed in Self.contents(of: folder.devicesFolder) ?? [] {
            guard let found = Self.jsonFile(listed) else { continue }
            let id = found.file.deletingPathExtension().lastPathComponent
            if !ids.contains(id) { ids.append(id) }
            if !found.onPhone { asked = true }
            guard found.onPhone, Self.isDownloaded(found.file),
                  let data = Self.coordinatedRead(found.file),
                  let card = try? JSONDecoder().decode(DeviceCard.self, from: data),
                  !cards.contains(where: { $0.id == card.id }) else { continue }
            cards.append(card)
        }
        return (cards.sorted { $0.seen > $1.seen }, ids)
    }

    /// When a device last wrote its copy of a list, which it does whenever it has a change to pass on
    func heard(from device: String, list: UUID, in folder: OpenFolder) -> Date? {
        let file = folder.copy(of: list, by: device)
        return (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: Files

    /// What's in a folder, hidden files too, since that's how iCloud Drive lists a file it hasn't downloaded. Nil if it
    /// can't be read.
    static func contents(of folder: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])
    }

    /// The file a listed one stands for, if it's named "<uuid>.json" as every device's files are, and whether it's on
    /// this iPhone. ".<uuid>.json.icloud" stands for one iCloud Drive hasn't downloaded yet, which is asked for here.
    /// Copies a sync service makes, like "<uuid> 2.json", don't count.
    static func jsonFile(_ listed: URL) -> (file: URL, onPhone: Bool)? {
        var name = listed.lastPathComponent
        let placeholder = name.hasPrefix(".") && name.hasSuffix(".icloud")
        if placeholder {
            name = String(name.dropFirst().dropLast(".icloud".count))
        }
        guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(".json".count))) != nil else { return nil }
        let file = listed.deletingLastPathComponent().appendingPathComponent(name)
        if placeholder {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        }
        return (file, !placeholder)
    }

    /// Whether a file can be read now without waiting on iCloud Drive. One that's out of date is asked for, and can be
    /// read as it is meanwhile.
    static func isDownloaded(_ file: URL) -> Bool {
        download(of: file).readable
    }

    /// Whether a file can be read now without waiting on iCloud Drive, and whether it's the file as it is now. One
    /// that isn't is asked for, and can be read as it is meanwhile if any of it is here.
    static func download(of file: URL) -> (readable: Bool, current: Bool) {
        guard let values = try? file.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                              .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus else {
            return (true, true)
        }
        if status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        }
        return (status != .notDownloaded, status == .current)
    }

    static func coordinatedRead(_ file: URL) -> Data? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file, options: [], error: &error) { url in
            data = try? Data(contentsOf: url)
        }
        return data
    }

    @discardableResult
    static func coordinatedWrite(_ data: Data, to file: URL) -> Bool {
        var written = false
        var error: NSError?
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: .forReplacing, error: &error) { url in
            do {
                try data.write(to: url, options: .atomic)
                written = true
            } catch {
                print("Couldn't write \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if let error { print("Couldn't write \(file.lastPathComponent): \(error.localizedDescription)") }
        return written
    }
}
