import Foundation

// What's in a sync folder, and how devices' copies of a list merge. YANA for iPhone (iOS/) compiles this file too,
// along with Note.swift, so both apps read and write exactly the same files. Keep it to Foundation.
//
// How a to-do list syncs. A synced list lives in a sync folder that every device it goes to can reach, such as one in
// iCloud Drive:
//
//     YANA Sync/
//       devices/<device id>.json         each device that uses the folder: its name, and when it was last seen
//       lists/<list id>/<device id>.json  each device's copy of the list
//
// A device only ever writes its own files, so a service like iCloud Drive never has two devices writing the same file.
// Each device reads the others' copies and merges them task by task: the latest change to a task wins, and a task
// deleted after its last change stays deleted. The list's name, once it has one, is the latest name given it.
//
// Anything added to a copy has to be optional, so a device on an older version still reads the newer copies (it skips
// what it doesn't know), and a newer one reads the older copies. The list's name (1.8) was added that way.

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
    /// When it was last named, or its name taken off. Nil if it never had one while syncing.
    var nameChanged: Date? = nil
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
    /// The list's name, if it has one. Left out of the file when it hasn't, as versions before 1.8 write it.
    var name: String?
    /// When the name was last given or taken off. A copy without it, such as one from before 1.8, doesn't change it.
    var nameChanged: Date?

    init(device: String, items: [ToDo] = [], orderChanged: Date = .distantPast, devices: [String] = [],
         devicesChanged: Date = .distantPast, deleted: [String: Date] = [:], name: String? = nil,
         nameChanged: Date? = nil) {
        format = 1
        self.device = device
        self.items = items
        self.orderChanged = orderChanged
        self.devices = devices
        self.devicesChanged = devicesChanged
        self.deleted = deleted
        self.name = name
        self.nameChanged = nameChanged
    }

    /// A synced list's copy, as `device` would write it
    init?(_ note: Note, device: String) {
        guard let sync = note.sync else { return nil }
        self.init(device: device, items: note.items, orderChanged: sync.orderChanged, devices: sync.devices,
                  devicesChanged: sync.devicesChanged, deleted: sync.deleted, name: note.name,
                  nameChanged: sync.nameChanged)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension Note {
    /// The list with a merged copy's name, tasks, devices and deletions, still synced through the same folder
    func adopting(_ list: SyncedList) -> Note {
        var note = self
        note.name = Note.name(list.name)
        note.sync?.nameChanged = list.nameChanged
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
    /// follow in their own copy. The name is the latest one given, by a copy that says when.
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

        // A copy from before 1.8 has no name and no date for it, so it loses to any copy that says when it was named,
        // and when none do, this device's name stays
        let nameFrom = counted.max { ($0.nameChanged ?? .distantPast) < ($1.nameChanged ?? .distantPast) } ?? mine

        return SyncedList(device: mine.device, items: order.compactMap { latest[$0] }, orderChanged: orderFrom.orderChanged,
                          devices: devices, devicesChanged: devicesFrom.devicesChanged, deleted: deleted,
                          name: Note.name(nameFrom.name), nameChanged: nameFrom.nameChanged)
    }
}

/// A device that uses a sync folder: devices/<id>.json in it
struct DeviceCard: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var seen: Date
}
