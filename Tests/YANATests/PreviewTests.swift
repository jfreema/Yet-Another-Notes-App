import AppKit
import Testing
@testable import YANA

/// TEMPORARY, on this branch only: draws the note window to PNGs, so how it looks can be checked without a Mac.
/// Runs only when YANA_PREVIEW names a folder for the pictures.
@MainActor
struct PreviewTests {
    static let out = ProcessInfo.processInfo.environment["YANA_PREVIEW"]

    private func draw(_ view: NSView, as name: String) throws {
        for _ in 0..<4 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let size = view.bounds.size
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                                pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        let folder = URL(fileURLWithPath: try #require(Self.out))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }

    @Test(.enabled(if: PreviewTests.out != nil))
    func drawsTheNote() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(folder: folder)
        let stopped = SyncInfo(folder: "gone", devices: [ThisDevice.id, "air"], devicesChanged: Date(),
                               orderChanged: Date(), deleted: [:])
        store.save([
            Note(kind: .list, items: [
                ToDo(text: "Book the campsite"),
                ToDo(text: "Ask Sam whether the big tent still has all its poles, and if not, order a set before Friday"),
                ToDo(text: "Charge the lanterns", done: true),
                ToDo(text: "Print the trail map and the parking pass, and put both in the glove box", done: true),
                ToDo(text: "Buy ice"),
            ], name: "Camping"),
            Note(kind: .text, text: "Ideas\n\nA short note with a couple of lines.\n"),
            Note(kind: .list, items: [ToDo(text: "Milk"), ToDo(text: "Eggs")], name: "Groceries", sync: stopped),
        ])
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "NSWindow Frame NoteWindow")
        defaults.set(false, forKey: "sticky")
        defaults.removeObject(forKey: "textSize")
        let controller = NoteWindowController(store: store)
        controller.window.setContentSize(NSSize(width: 304, height: 330))
        controller.select(0)
        // Looks at the sync folders, which marks the list whose folder is gone
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        let frame = try #require(controller.window.contentView?.superview)

        try draw(frame, as: "list")
        controller.window.appearance = NSAppearance(named: .darkAqua)
        try draw(frame, as: "list-dark")
        controller.window.appearance = nil
        controller.isSticky = true
        try draw(frame, as: "list-sticky")
        controller.isSticky = false
        controller.changeTextSize(by: -4)
        try draw(frame, as: "list-small")
        controller.changeTextSize(by: 12)
        try draw(frame, as: "list-large")
        controller.resetTextSize()
        controller.window.setContentSize(NSSize(width: 520, height: 300))
        try draw(frame, as: "list-wide")

        // A task being typed past the end of its line, and the row for adding one
        controller.window.setContentSize(NSSize(width: 304, height: 380))
        let list = try #require(controller.notePages[0] as? TodoList)
        func fields(_ view: NSView) -> [TaskField] {
            view.subviews.flatMap { ($0 as? TaskField).map { [$0] } ?? fields($0) }
        }
        let first = try #require(fields(list).first { $0.stringValue == "Book the campsite" })
        #expect(controller.window.makeFirstResponder(first))
        (first.currentEditor() as? NSTextView)?.insertText(" for the long weekend, the one by the lake if it's free",
                                                           replacementRange: NSRange(location: 17, length: 0))
        try draw(frame, as: "list-typing")
        let add = try #require(fields(list).first { $0.stringValue.isEmpty })
        #expect(controller.window.makeFirstResponder(add))
        (add.currentEditor() as? NSTextView)?.insertText("Pack the cooler the night before so the ice lasts the drive",
                                                         replacementRange: NSRange(location: 0, length: 0))
        try draw(frame, as: "list-adding")
        defaults.removeObject(forKey: "textSize")
    }

    @Test(.enabled(if: PreviewTests.out != nil))
    func drawsTheSheets() throws {
        let lists = NoteWindowController.choice(
            "Bring lists from “YANA Sync” to this Mac?",
            "These lists sync through the folder on your other devices. A ticked one gets a tab here and stays in sync with them.",
            from: ["Camping (5 tasks, on MacBook Air)", "Groceries (12 tasks, on MacBook Air and iPhone)",
                   "A list with a very long name that goes on and on (1 task, on MacBook Air)"],
            button: "Bring Here")
        lists.alert.layout()
        try draw(try #require(lists.alert.window.contentView), as: "sheet-lists")

        let device = NoteWindowController.choice(
            "“iPhone” now uses “YANA Sync”",
            "Send it the lists that sync through that folder? A ticked list shows up on it and stays in sync. Sync Settings for a list changes this later.",
            from: ["Camping", "Groceries"], button: "Send")
        device.alert.layout()
        try draw(try #require(device.alert.window.contentView), as: "sheet-device")
    }
}
