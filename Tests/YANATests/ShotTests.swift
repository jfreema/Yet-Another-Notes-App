import AppKit
import Testing
@testable import YANA

/// Temporary, for this branch only and never for main: draws the note window into a PNG, so a change to how a list
/// looks can be seen without a Mac. Does nothing unless YANA_SCREENSHOTS names the picture.
@MainActor
struct ShotTests {
    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + all(type, in: $0) }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func draw(_ view: NSView, to url: URL) throws {
        let bounds = view.bounds
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test func shots() throws {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["YANA_SCREENSHOTS"], let dir = env["YANA_SHOTS_DIR"] else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        let out = URL(fileURLWithPath: dir)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }

        let tasks: [ToDo] = [
            ToDo(text: "Book the campsite"),
            ToDo(text: "Check the tent for holes", done: true),
            ToDo(text: "Buy stove fuel"),
            ToDo(text: "Charge the lanterns", done: true),
            ToDo(text: "Print the trail map"),
            ToDo(text: "Ask Sam about borrowing the big cooler for the whole weekend, and the camp chairs",
                 done: true),
            ToDo(text: "Pack the first aid kit"),
            ToDo(text: "Marshmallows", done: true, highlight: .yellow),
            ToDo(text: "Fill the water jugs"),
            ToDo(text: "Sunscreen and bug spray"),
            ToDo(text: "Download the playlist", done: true),
            ToDo(text: "Firewood"),
            ToDo(text: "Coffee and the kettle"),
            ToDo(text: "Rain jackets", done: true),
            ToDo(text: "Leave a key with the neighbors"),
            ToDo(text: "Hiking boots"),
            ToDo(text: "Water the plants", done: true),
            ToDo(text: "Check the weather"),
            ToDo(text: "Fill the gas tank"),
            ToDo(text: "Pick up ice"),
        ]
        let store = NoteStore(folder: folder)
        store.save([Note(kind: .list, items: tasks, name: "Camping"), Note(kind: .list, items: [], name: "Errands"),
                    Note(kind: .text, text: "Ideas\n")])
        let controller = NoteWindowController(store: store)
        let sticky = name.hasSuffix("sticky")
        controller.isSticky = sticky
        if !sticky { controller.window.appearance = NSAppearance(named: .darkAqua) }
        controller.select(0)
        controller.window.setContentSize(NSSize(width: 365, height: 333))
        let list = try #require(controller.notePages[0] as? TodoList)
        for _ in 0..<4 {
            list.needsLayout = true
            controller.window.layoutIfNeeded()
            list.layoutSubtreeIfNeeded()
        }
        spin(0.6)

        let scroll = try #require(all(NSScrollView.self, in: list).first)
        print("SHOT \(name): preferred scroller style \(NSScroller.preferredScrollerStyle.rawValue),",
              "overlay width \(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)),",
              "legacy width \(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)),",
              "list \(list.bounds.size), clip \(scroll.contentView.frame)")
        for row in all(ToDoRow.self, in: list) where row.item.done {
            guard let button = all(NSButton.self, in: row).first(where: { $0.toolTip == "Delete" }) else { continue }
            let frame = button.convert(button.bounds, to: list)
            print("SHOT \(name): × of '\(row.item.text.prefix(12))' x \(frame.minX)...\(frame.maxX)",
                  "(\(list.bounds.maxX - frame.maxX) from the edge), \(frame.width) by \(frame.height),",
                  "mark \(button.intrinsicContentSize), row \(row.frame.height), checkbox \(row.checkbox.frame)")
        }

        let frameView = try #require(controller.window.contentView?.superview)
        try draw(frameView, to: out.appendingPathComponent("\(name).png"))

        // With the scroll bar showing over the list, as it does while two fingers scroll it
        scroll.scrollerStyle = .overlay
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.flashScrollers()
        spin(0.25)
        if let scroller = scroll.verticalScroller {
            print("SHOT \(name): scroller frame \(scroller.convert(scroller.bounds, to: list)),",
                  "style \(scroller.scrollerStyle.rawValue), hidden \(scroller.isHidden), alpha \(scroller.alphaValue)")
        }
        try draw(frameView, to: out.appendingPathComponent("\(name)-scrolling.png"))

        // The same with scroll bars that always show, as with a mouse plugged in
        scroll.scrollerStyle = .legacy
        for _ in 0..<3 {
            list.needsLayout = true
            list.layoutSubtreeIfNeeded()
        }
        spin(0.25)
        if let scroller = scroll.verticalScroller {
            print("SHOT \(name): legacy scroller frame \(scroller.convert(scroller.bounds, to: list)),",
                  "clip \(scroll.contentView.frame)")
        }
        try draw(frameView, to: out.appendingPathComponent("\(name)-always.png"))

        // On the screen for real, if the runner lets a test's window show
        controller.window.orderFrontRegardless()
        scroll.scrollerStyle = .overlay
        scroll.flashScrollers()
        spin(0.4)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(controller.window.windowNumber),
                             out.appendingPathComponent("\(name)-screen.png").path]
        try? capture.run()
        capture.waitUntilExit()
        print("SHOT \(name): screencapture ended \(capture.terminationStatus)")
        controller.window.orderOut(nil)
    }
}
