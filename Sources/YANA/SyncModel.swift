import Foundation

// How a to-do list syncs. A synced list lives in a sync folder that every device it goes to can reach, such as one in
// iCloud Drive:
//
//     YANA Sync/
//       devices/<device id>.json         each device that uses the folder: its name, and when it was last seen
//       lists/<list id>/<device id>.json  each device's copy of the list
//
// A device only ever writes its own files, so a service like iCloud Drive never has two devices writing the same file.
// Each device reads the others' copies and merges them task by task: the latest change to a task wins, and a task
// deleted after its last change stays deleted.

/// How a synced list syncs, kept with it in Notes.json
struct SyncInfo: Codable, Equatable, Sendable {
    /// The sync folder it's in, by its id on this Mac
    var folder: String
    /// The devices it goes to, by device id
    var devices: [String]
    var devicesChanged: Date
    /// When the tasks were last put in a different order, or one was added or deleted
    var orderChanged: Date
    /// The tasks deleted from it, by id, with when. Kept a while so an older copy doesn't bring them back.
    var deleted: [String: Date]
}

/// One device's copy of a synced list: lists/<list id>/<device id>.json in its sync folder
struct SyncedList: Codable, Equatable, Sendable {
    var format: Int
    var device: String
    var items: [ToDo]
    var orderChanged: Date
    var devices: [String]
    var devicesChanged: Date
    var deleted: [String: Date]

    init(device: String, items: [ToDo] = [], orderChanged: Date = .distantPast, devices: [String] = [],
         devicesChanged: Date = .distantPast, deleted: [String: Date] = [:]) {
        format = 1
        self.device = device
        self.items = items
        self.orderChanged = orderChanged
        self.devices = devices
        self.devicesChanged = devicesChanged
        self.deleted = deleted
    }

    /// A synced list's copy, as `device` would write it
    init?(_ note: Note, device: String) {
        guard let sync = note.sync else { return nil }
        self.init(device: device, items: note.items, orderChanged: sync.orderChanged, devices: sync.devices,
                  devicesChanged: sync.devicesChanged, deleted: sync.deleted)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension Note {
    /// The list with a merged copy's tasks, devices and deletions, still synced through the same folder
    func adopting(_ list: SyncedList) -> Note {
        var note = self
        note.items = list.items
        note.sync?.devices = list.devices
        note.sync?.devicesChanged = list.devicesChanged
        note.sync?.orderChanged = list.orderChanged
        note.sync?.deleted = list.deleted
        return note
    }
}

enum SyncMerge {
    /// How long a deletion is remembered. A device away for longer could bring a deleted task back.
    static let deletionsKept: TimeInterval = 90 * 24 * 60 * 60

    /// Merges copies of a list into one, taking each copy's device from the first, which is this device's copy and wins
    /// ties. The devices the list goes to are the latest change to them. Only those devices' copies count for the tasks,
    /// so a device that stopped syncing it can't bring back old ones. Each task is its latest change, unless it was
    /// deleted after that. The order is the latest copy to change it, with tasks it doesn't have yet after the task they
    /// follow in their own copy.
    static func merge(_ copies: [SyncedList], now: Date) -> SyncedList {
        guard let mine = copies.first else { return SyncedList(device: "") }
        let devicesFrom = copies.max { $0.devicesChanged < $1.devicesChanged } ?? mine
        let devices = devicesFrom.devices
        let counted = [mine] + copies.dropFirst().filter { devices.contains($0.device) }

        var deleted: [String: Date] = [:]
        let forgotten = now.addingTimeInterval(-deletionsKept)
        for copy in counted {
            for (id, date) in copy.deleted where date > forgotten {
                deleted[id] = Swift.max(deleted[id] ?? date, date)
            }
        }

        var latest: [UUID: ToDo] = [:]
        for copy in counted {
            for item in copy.items {
                if let have = latest[item.id], (have.changed ?? .distantPast) >= (item.changed ?? .distantPast) {
                    continue
                }
                latest[item.id] = item
            }
        }
        latest = latest.filter { id, item in
            guard let gone = deleted[id.uuidString] else { return true }
            return (item.changed ?? .distantPast) > gone
        }

        let orderFrom = counted.max { $0.orderChanged < $1.orderChanged } ?? mine
        var order: [UUID] = []
        for item in orderFrom.items where latest[item.id] != nil && !order.contains(item.id) {
            order.append(item.id)
        }
        for copy in counted {
            for (index, item) in copy.items.enumerated() where latest[item.id] != nil && !order.contains(item.id) {
                if let before = copy.items[..<index].last(where: { order.contains($0.id) }),
                   let at = order.firstIndex(of: before.id) {
                    order.insert(item.id, at: at + 1)
                } else {
                    order.insert(item.id, at: 0)
                }
            }
        }

        return SyncedList(device: mine.device, items: order.compactMap { latest[$0] }, orderChanged: orderFrom.orderChanged,
                          devices: devices, devicesChanged: devicesFrom.devicesChanged, deleted: deleted)
    }
}

/// A device that uses a sync folder: devices/<id>.json in it
struct DeviceCard: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var seen: Date
}

/// A folder synced lists live in, such as YANA Sync in iCloud Drive or one shared with another Apple ID
struct SyncFolder: Codable, Equatable, Sendable {
    /// Its id on this Mac. Another device knows the same folder by its own id.
    var id: String
    var url: URL

    var name: String { url.lastPathComponent }
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

    /// Where it is, to tell folders with the same name apart: "iCloud Drive", or the folder it's in
    var place: String {
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL == SyncFolders.iCloudDrive.standardizedFileURL { return "iCloud Drive" }
        return parent.lastPathComponent
    }

    /// The devices that use it, newest first, read from its devices folder
    func devices() -> [DeviceCard] {
        let files = (try? FileManager.default.contentsOfDirectory(at: devicesFolder, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(DeviceCard.self, from: Data(contentsOf: $0)) }
            .sorted { $0.seen > $1.seen }
    }
}

/// The sync folders this Mac uses, kept in its settings
enum SyncFolders {
    private static let key = "syncFolders"

    static var all: [SyncFolder] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([SyncFolder].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }

    static func folder(_ id: String) -> SyncFolder? {
        all.first { $0.id == id }
    }

    /// Adds a folder, or finds it if it's already there, and makes its devices and lists folders
    @discardableResult
    static func add(_ url: URL) throws -> SyncFolder {
        let manager = FileManager.default
        if let folder = all.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { return folder }
        let folder = SyncFolder(id: UUID().uuidString, url: url)
        try manager.createDirectory(at: folder.devicesFolder, withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.listsFolder, withIntermediateDirectories: true)
        all.append(folder)
        return folder
    }

    /// iCloud Drive's own folder. YANA isn't sandboxed, so it can use it like any other folder.
    static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static var hasICloudDrive: Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: iCloudDrive.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// Where YANA suggests putting synced lists
    static var suggested: URL { iCloudDrive.appendingPathComponent("YANA Sync", isDirectory: true) }
}

/// This Mac, as the other devices know it
enum ThisDevice {
    private static let key = "deviceID"

    static var id: String {
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// The Mac's name from Sharing settings, like "Jared's MacBook Air"
    static var name: String { Host.current().localizedName ?? "Mac" }
}
