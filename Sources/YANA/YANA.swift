import AppKit
import os

let logger = Logger(subsystem: "io.github.jfreema.yana", category: "app")

@main
@MainActor
enum YANA {
    static let showNoteNotification = Notification.Name("io.github.jfreema.yana.showNote")

    static func main() {
        // One copy at a time: a second launch shows the first one's note instead
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
            DistributedNotificationCenter.default().postNotificationName(showNoteNotification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
