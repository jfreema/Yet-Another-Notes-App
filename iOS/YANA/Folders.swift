import Foundation

/// A sync folder this iPhone uses, picked in Files, such as YANA Sync in iCloud Drive or a folder shared with you.
/// YANA keeps a bookmark to it, since an iPhone app can only use a folder outside its own once you've picked it.
struct PhoneFolder: Codable, Equatable, Identifiable, Sendable {
    /// Its id on this iPhone. Another device knows the same folder by its own id.
    var id: String
    var name: String
    var bookmark: Data
}

/// A sync folder, opened: its id on this iPhone and where it is. It's laid out the same as on the Mac, so where
/// things are in it comes from `SyncFolderLayout` (SyncPass.swift), which the Mac's folders use too.
struct OpenFolder: Equatable, Sendable, SyncFolderLayout {
    var id: String
    var url: URL
}
