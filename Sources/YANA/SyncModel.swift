import Foundation
import SystemConfiguration

// The Mac's side of syncing: the sync folders it uses and its own id. What goes in the folders, and how copies
// merge, is in SyncFormat.swift, and where things are in a folder is in SyncPass.swift (`SyncFolderLayout`).

/// A folder synced lists live in, such as YANA Sync in iCloud Drive or one shared with another Apple ID
struct SyncFolder: Codable, Equatable, Sendable, SyncFolderLayout {
    /// Its id on this Mac. Another device knows the same folder by its own id.
    var id: String
    var url: URL

    var name: String { url.lastPathComponent }

    /// Where it is, to tell folders with the same name apart: "iCloud Drive", or the folder it's in
    var place: String {
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL == SyncFolders.iCloudDrive.standardizedFileURL { return "iCloud Drive" }
        return parent.lastPathComponent
    }

    /// Whether YANA can read what's in it. It can't when the folder is gone, or when macOS hasn't let YANA use the
    /// place it's in, such as iCloud Drive.
    var canBeRead: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: listsFolder.path)) != nil
    }

    /// The devices that use it, newest first, read from its devices folder
    func devices() -> [DeviceCard] {
        let files = (try? FileManager.default.contentsOfDirectory(at: devicesFolder, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { file -> DeviceCard? in
                // A card is its device's own, and small
                guard SyncLimits.fits(file, SyncLimits.cardBytes), let data = try? Data(contentsOf: file) else {
                    return nil
                }
                return DeviceCard.read(data, device: file.deletingPathExtension().lastPathComponent)
            }
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

    /// The Mac's name from Sharing settings, like "Jared's MacBook Air". Read from System Configuration, which answers
    /// at once, where Host can wait on the network.
    static var name: String { (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac" }
}
