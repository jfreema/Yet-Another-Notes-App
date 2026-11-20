#if DEBUG
import SwiftUI

// Sample lists to take screenshots with, in debug builds only. Launch with `-YANAScreenshots YES`, plus `-YANAOpen 0`
// to open the first list and `-sticky YES` for the sticky note look.

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
}
#else
extension AppModel {
    static func launched() -> AppModel { AppModel() }
}

extension ListsView {
    static var openAtLaunch: Int? { nil }
}
#endif
