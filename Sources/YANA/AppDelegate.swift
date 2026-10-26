import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let note = NoteWindowController()
    private let updater = Updater()
    private lazy var statusMenu = makeMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(target: self)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "YANA")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "YANA: click for your note, right-click for options"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        note.menuProvider = { [unowned self] in self.statusMenu }

        DistributedNotificationCenter.default().addObserver(forName: YANA.showNoteNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.note.show() }
        }
        logger.notice("YANA \(Bundle.main.shortVersion, privacy: .public) started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        note.save()
    }

    // Opening the app again from Finder or Spotlight shows the note
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        note.show()
        return false
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            // Shown only for this click, so a left click still reaches the action
            statusItem.menu = statusMenu
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            note.toggle()
        }
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Show Note", #selector(showNote)))
        menu.addItem(item("Keep on Top", #selector(togglePinned), tag: Tag.pinned))
        menu.addItem(item("Sticky Note Mode", #selector(toggleSticky), tag: Tag.sticky))
        menu.addItem(.separator())
        menu.addItem(item("Open Text File…", #selector(openTextFile)))
        menu.addItem(item("Save as Text File…", #selector(saveTextFile), tag: Tag.save))
        menu.addItem(item("Save As…", #selector(saveTextFileAs)))
        menu.addItem(.separator())
        menu.addItem(item("Open at Login", #selector(toggleOpenAtLogin), tag: Tag.openAtLogin))
        menu.addItem(.separator())
        menu.addItem(item("About YANA", #selector(showAbout)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(item("Quit YANA", #selector(quit), key: "q"))
        return menu
    }

    private enum Tag {
        static let pinned = 1
        static let openAtLogin = 2
        static let sticky = 3
        static let save = 4
    }

    private func item(_ title: String, _ action: Selector, key: String = "", tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.tag = tag
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: Tag.pinned)?.state = note.isPinned ? .on : .off
        menu.item(withTag: Tag.sticky)?.state = note.isSticky ? .on : .off
        // Names the file Save writes to, once the tab has one
        menu.item(withTag: Tag.save)?.title = note.currentFile.map { "Save to “\($0.lastPathComponent)”" }
            ?? "Save as Text File…"
        menu.item(withTag: Tag.openAtLogin)?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func showNote() {
        note.show()
    }

    @objc func togglePinned() {
        note.isPinned.toggle()
    }

    @objc func toggleSticky() {
        note.isSticky.toggle()
    }

    @objc func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            logger.error("Open at Login failed: \(error.localizedDescription, privacy: .public)")
            Alert.show("Couldn't change Open at Login", error.localizedDescription)
        }
    }

    @objc func showAbout() {
        NSApp.activateRegardless()
        let credits = NSMutableAttributedString(string: "Yet Another Notes App\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        credits.append(NSAttributedString(string: "github.com/jfreema/Yet-Another-Notes-App", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: Updater.homepage,
        ]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: Bundle.main.shortVersion,
            // Build number is always 1, so show the version alone
            .version: "",
            .credits: credits,
        ])
    }

    @objc func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Text size, from the View menu

    @objc func biggerText() { note.changeTextSize(by: 1) }
    @objc func smallerText() { note.changeTextSize(by: -1) }
    @objc func actualSizeText() { note.resetTextSize() }

    // MARK: Tabs, from the File and Window menus

    @objc func newNote() { note.newNote(.text) }
    @objc func newList() { note.newNote(.list) }
    @objc func showTab(_ sender: NSMenuItem) { note.select(sender.tag) }

    // MARK: Text files, from the File and … menus

    @objc func openTextFile() { note.openTextFile() }
    @objc func saveTextFile() { note.saveTextFile() }
    @objc func saveTextFileAs() { note.saveTextFileAs() }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newNote), #selector(newList):
            note.count < Note.limit
        case #selector(showTab(_:)):
            menuItem.tag < note.count
        default:
            true
        }
    }
}

enum Alert {
    @MainActor
    static func show(_ title: String, _ message: String) {
        NSApp.activateRegardless()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    @MainActor
    static func confirm(_ title: String, _ message: String, button: String, cancel: String = "Not Now") -> Bool {
        NSApp.activateRegardless()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension NSApplication {
    /// Since macOS 14, activate() is only a request that macOS can turn down, for example after an update check's
    /// wait. Then an alert would open behind the app you're in.
    func activateRegardless() {
        activate(ignoringOtherApps: true)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}
