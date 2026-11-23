import AppKit
import Testing
@testable import YANA

// TEMPORARY: pictures of highlighted tasks for review. Never for main.

@MainActor
struct ScreenshotTests {
    private func rows(in view: NSView) -> [ToDoRow] {
        view.subviews.flatMap { ($0 as? ToDoRow).map { [$0] } ?? rows(in: $0) }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func render(_ window: NSWindow, to url: URL) throws {
        let view = try #require(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
                                                pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        print("wrote \(url.lastPathComponent)")
    }

    @Test func previews() throws {
        guard let out = ProcessInfo.processInfo.environment["YANA_SCREENSHOTS"] else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(folder: folder)
        store.save([
            Note(kind: .list, items: [
                ToDo(text: "Book flights for the conference", done: true, highlight: .blue),
                ToDo(text: "Renew passport", highlight: .yellow),
                ToDo(text: "Ask Sam about the budget review, and send the slides from last week", highlight: .green),
                ToDo(text: "Pick up dry cleaning", done: true),
                ToDo(text: "Call the dentist", highlight: .pink),
                ToDo(text: "Plan Saturday hike", highlight: .purple),
                ToDo(text: "Order the birthday cake", highlight: .orange),
                ToDo(text: "Water the plants"),
                ToDo(text: "Pay the electric bill", highlight: .yellow),
            ], name: "This Week"),
            Note(kind: .text, text: "Ideas"),
        ])
        UserDefaults.standard.set(false, forKey: "sticky")
        UserDefaults.standard.set(0, forKey: "selectedNote")
        let controller = NoteWindowController(store: store)
        controller.window.setContentSize(NSSize(width: 320, height: 380))
        controller.select(0)
        for (name, appearance, sticky) in [("mac-light", NSAppearance.Name.aqua, false),
                                           ("mac-dark", .darkAqua, false), ("mac-sticky", .aqua, true)] {
            controller.isSticky = sticky
            if !sticky { controller.window.appearance = NSAppearance(named: appearance) }
            controller.select(0)
            spin(0.6)
            try render(controller.window, to: dir.appendingPathComponent("\(name).png"))
        }

        // The menu a right-click on a task shows, from the screen while it's open
        for (name, appearance) in [("mac-menu-light", NSAppearance.Name.aqua), ("mac-menu-dark", .darkAqua)] {
            controller.isSticky = false
            controller.window.appearance = NSAppearance(named: appearance)
            NSApp.appearance = NSAppearance(named: appearance)
            controller.window.orderFrontRegardless()
            spin(0.8)
            let list = try #require(controller.notePages[0] as? TodoList)
            let row = try #require(rows(in: list).first { $0.item.text == "Call the dentist" })
            let menu = list.menu(for: row)
            let shot = dir.appendingPathComponent("\(name).png")
            let timer = Timer(timeInterval: 1.0, repeats: false) { _ in
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", shot.path]
                try? capture.run()
                capture.waitUntilExit()
                menu.cancelTracking()
            }
            RunLoop.current.add(timer, forMode: .common)
            menu.popUp(positioning: nil, at: NSPoint(x: 60, y: row.bounds.midY), in: row)
            print("menu \(name): \(FileManager.default.fileExists(atPath: shot.path))")
            // Where the window is on the screen, to crop to
            let frame = controller.window.frame
            let screen = NSScreen.main?.frame ?? .zero
            try "\(frame.minX) \(screen.height - frame.maxY) \(frame.width) \(frame.height) \(NSScreen.main?.backingScaleFactor ?? 1)"
                .write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }
        controller.window.orderOut(nil)
        UserDefaults.standard.set(false, forKey: "sticky")
        try? FileManager.default.removeItem(at: folder)
    }
}
