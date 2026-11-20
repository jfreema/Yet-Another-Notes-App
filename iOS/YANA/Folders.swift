import Foundation

/// A sync folder this iPhone uses, picked in Files, such as YANA Sync in iCloud Drive or a folder shared with you.
/// YANA keeps a bookmark to it, since an iPhone app can only use a folder outside its own once you've picked it.
struct PhoneFolder: Codable, Equatable, Identifiable, Sendable {
    /// Its id on this iPhone. Another device knows the same folder by its own id.
    var id: String
    var name: String
    var bookmark: Data
}

/// A sync folder, opened: its id on this iPhone and where it is. It's laid out the same as on the Mac (see
/// SyncFormat.swift).
struct OpenFolder: Equatable, Sendable {
    var id: String
    var url: URL

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
