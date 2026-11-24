#if DEBUG
import SwiftUI

// Sample lists to take screenshots with, in debug builds only. Launch with `-YANAScreenshots YES`, plus `-YANAOpen 0`
// to open the first list, `-YANAShow sync` or `-YANAShow settings` for a sheet, and `-sticky YES` for the sticky note
// look. `-YANAShow deleted`, `folder` and `offer` show Recently Deleted, a folder's lists to bring here, and a new
// device to send lists to; `-YANAShow undo` deletes a task in the open list so Undo shows; `-YANAShow highlight`
// shows the highlighter colors for the open list's first highlighted task; and `-YANAStopped YES` shows the synced
// lists as stopped.

extension AppModel {
    static func launched() -> AppModel {
        guard UserDefaults.standard.bool(forKey: "YANAScreenshots") else { return AppModel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshots-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "Screenshots-\(UUID().uuidString)") ?? .standard
        defaults.set("My iPhone", forKey: "deviceName")
        let model = AppModel(storage: root.appendingPathComponent("Lists.json"), defaults: defaults)
        model.showSamples()
        return model
    }
}

extension ListsView {
    /// The list to open at launch, for a screenshot
    static var openAtLaunch: Int? {
        UserDefaults.standard.object(forKey: "YANAOpen") == nil ? nil : UserDefaults.standard.integer(forKey: "YANAOpen")
    }

    /// What to show at launch: "settings", "deleted", "folder" or "offer" over the lists, or "sync", "undo" or
    /// "highlight" in the open list
    static var showAtLaunch: String? { UserDefaults.standard.string(forKey: "YANAShow") }
}
#else
extension AppModel {
    static func launched() -> AppModel { AppModel() }
}

extension ListsView {
    static var openAtLaunch: Int? { nil }
    static var showAtLaunch: String? { nil }
}
#endif
