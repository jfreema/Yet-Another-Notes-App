import AppKit
import UniformTypeIdentifiers

/// The note window: up to four tabs of notes and to-do lists, plus any lists synced here from other devices. Closing it
/// hides it to the menu bar. Each tab has its own Undo, and a deleted tab's note or list can be put back for 30 days.
@MainActor
final class NoteWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let tabBar = TabBar()
    private let pageArea = NSView()
    private lazy var tabsShown = pageArea.topAnchor.constraint(equalTo: tabBar.bottomAnchor)
    private lazy var tabsHidden = pageArea.topAnchor.constraint(equalTo: tabBar.topAnchor)
    private var pages: [NotePage] = []
    private var selected = 0
    private let newButton = NSButton()
    private let pinButton = NSButton()
    private let menuButton = NSButton()
    private let opacitySlider = NSSlider()
    private let store: NoteStore
    private let listSync = ListSync()
    private var syncSheet: SyncSheet?
    /// Devices that have started using a sync folder, to offer its lists to once the note is showing
    private var offers: [(device: DeviceCard, folder: SyncFolder)] = []
    private var saveTimer: Timer?
    /// The status item's menu, also under the note's … button
    var menuProvider: (() -> NSMenu)?

    private enum Key {
        static let pinned = "pinned"
        static let sticky = "sticky"
        static let opacity = "opacity"
        static let textSize = "textSize"
        static let selected = "selectedNote"
        static let narrowed = "narrowed"
        static let textFolder = "textFolder"
        static let frame = "NoteWindow"
    }

    static let defaultTextSize: CGFloat = 14
    static let opacityRange = 0.2...1.0

    var isPinned: Bool {
        get { UserDefaults.standard.bool(forKey: Key.pinned) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.pinned)
            applyPinned()
        }
    }

    /// Post-it yellow with black, hand-lettered text
    var isSticky: Bool {
        get { UserDefaults.standard.bool(forKey: Key.sticky) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.sticky)
            applyLook()
        }
    }

    var count: Int { pages.count }

    /// The tests keep their notes somewhere else
    init(store: NoteStore = NoteStore()) {
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 304, height: 440),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()

        window.title = "YANA"
        // The tabs name the notes, and a title wouldn't fit beside the controls
        window.titleVisibility = .hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 240, height: 160)
        // Comes to the desktop you're on, and over full-screen apps when kept on top
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = makeContent()
        window.addTitlebarAccessoryViewController(makeAccessory())
        placeWindow()

        tabBar.onSelect = { [unowned self] in self.select($0) }
        tabBar.onDelete = { [unowned self] in self.deleteNote(at: $0) }
        tabBar.onConvert = { [unowned self] in self.convertToList(at: $0) }
        tabBar.onSync = { [unowned self] in self.showSyncSheet(for: $0) }
        tabBar.onRename = { [unowned self] in self.rename(at: $0) }
        pages = store.load().map { makePage($0) }
        listSync.host = self
        listSync.start()

        let opacity = UserDefaults.standard.object(forKey: Key.opacity) as? Double ?? 1
        opacitySlider.doubleValue = opacity
        window.alphaValue = opacity
        applyPinned()
        applyLook()
        select(min(max(UserDefaults.standard.integer(forKey: Key.selected), 0), pages.count - 1))
    }

    private func makeContent() -> NSView {
        let content = NSView()
        for view in [tabBar, pageArea] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        tabBar.isHidden = true
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pageArea.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pageArea.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pageArea.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            tabsHidden,
        ])
        return content
    }

    /// Where it was last time, else under the menu bar's right side
    private func placeWindow() {
        if window.setFrameUsingName(Key.frame) {
            // 1.1 made the note narrower, so a note placed by 1.0 narrows too, keeping its right edge where it was
            if !UserDefaults.standard.bool(forKey: Key.narrowed) {
                var frame = window.frame
                let width = max(window.minSize.width, (frame.width * 0.8).rounded())
                frame.origin.x += frame.width - width
                frame.size.width = width
                window.setFrame(frame, display: false)
                window.saveFrame(usingName: Key.frame)
            }
        } else if let screen = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: screen.maxX - window.frame.width - 80, y: screen.maxY - 8))
        }
        UserDefaults.standard.set(true, forKey: Key.narrowed)
        window.setFrameAutosaveName(Key.frame)
    }

    // MARK: Showing and hiding

    func toggle() {
        if window.isVisible && NSApp.isActive && window.isKeyWindow {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activateRegardless()
        window.makeKeyAndOrderFront(nil)
        pages[selected].focus()
        // What other devices changed while the note was hidden shows now
        listSync.run()
        showOffersSoon()
    }

    func hide() {
        save()
        listSync.run()
        window.orderOut(nil)
        // Hands the focus back to the app you were in
        NSApp.hide(nil)
    }

    /// The close button hides the note to the menu bar instead
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        save()
        listSync.run()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        showOffersSoon()
    }

    /// Each tab keeps its own Undo, so going to another tab and back loses none of it
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        pages.indices.contains(selected) ? pages[selected].undo : nil
    }

    // MARK: Tabs

    func newNote(_ kind: Note.Kind) {
        guard pages.count < Note.limit else {
            NSSound.beep()
            return
        }
        pages.append(makePage(Note(kind: kind)))
        select(pages.count - 1)
        show()
        save()
    }

    func select(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        selected = index
        UserDefaults.standard.set(index, forKey: Key.selected)
        let view = pages[index].view
        if view.superview !== pageArea {
            pageArea.subviews.forEach { $0.removeFromSuperview() }
            view.translatesAutoresizingMaskIntoConstraints = false
            pageArea.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: pageArea.topAnchor),
                view.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            ])
        }
        updateTabs()
        if window.isVisible { pages[index].focus() }
    }

    /// Asks first, unless there's nothing in it. A synced list stops syncing here and stays on the other devices.
    func deleteNote(at index: Int) {
        guard pages.count > 1, pages.indices.contains(index) else { return }
        let page = pages[index]
        let note = page.note
        let kept = "Recently Deleted, in the … menu, for 30 days"
        if note.sync != nil {
            guard Alert.confirm("Delete “\(note.title)” from this Mac?",
                                "It stops syncing here, and stays on your other devices. This Mac's copy goes to \(kept).",
                                button: "Delete", cancel: "Cancel") else { return }
        } else if !note.isEmpty {
            let what = note.kind == .list ? "to-do list" : "note"
            guard Alert.confirm("Delete “\(note.title)”?", "The \(what) goes to \(kept).", button: "Delete",
                                cancel: "Cancel") else { return }
        }
        discard(page)
    }

    /// Takes a tab away, without asking. What was in it goes to Recently Deleted, and a synced list stops syncing here.
    func discard(_ page: NotePage) {
        guard pages.count > 1, let index = pages.firstIndex(where: { $0 === page }) else { return }
        let note = page.note
        if note.sync != nil { listSync.stop(page) }
        store.keepDeleted(note)
        // Its Undo holds on to it
        page.undo.removeAllActions()
        pages.remove(at: index)
        select(index < selected ? selected - 1 : min(selected, pages.count - 1))
        save()
    }

    // MARK: Recently Deleted

    /// The notes and lists deleted in the last 30 days, latest first
    var recentlyDeleted: [NoteStore.DeletedNote] { store.loadDeleted() }

    /// Puts a deleted note or list back: in place of the tab you're on if that's an empty note, else in a new tab. It
    /// comes back as it was, except that a list which synced doesn't any more. False when there's no room for it.
    @discardableResult
    func putBack(_ id: UUID) -> Bool {
        var deleted = store.loadDeleted()
        guard let index = deleted.firstIndex(where: { $0.note.id == id }) else { return false }
        var note = deleted[index].note
        // A new id, so a list that used to sync isn't taken for the one still in its sync folder
        note.id = UUID()
        note.sync = nil
        // A file that's open in another tab by now stays that tab's
        if let file = note.file?.standardizedFileURL,
           pages.contains(where: { $0.file?.standardizedFileURL == file }) {
            note.file = nil
        }
        let current = pages[selected].note
        if current.kind == .text && current.isEmpty {
            pages[selected].undo.removeAllActions()
            pages[selected] = makePage(note)
            select(selected)
        } else if pages.count < Note.limit {
            pages.append(makePage(note))
            select(pages.count - 1)
        } else {
            return false
        }
        deleted.remove(at: index)
        store.saveDeleted(deleted)
        save()
        return true
    }

    /// Deletes everything in Recently Deleted for good
    func emptyRecentlyDeleted() {
        store.saveDeleted([])
    }

    // MARK: Naming

    /// Whether the tab you're on is a to-do list
    var isList: Bool { pages[selected].note.kind == .list }

    /// Rename…: gives a tab a name of its own in place of its first task or line. A synced list's name goes to the other
    /// devices. Leaving it empty names it after what's in it again, and Undo puts the old name back.
    func rename(at index: Int? = nil) {
        let index = index ?? selected
        guard window.attachedSheet == nil, pages.indices.contains(index) else {
            NSSound.beep()
            return
        }
        show()
        select(index)
        let page = pages[index]
        let note = page.note
        let list = note.kind == .list
        let alert = NSAlert()
        alert.messageText = list ? "Name This List" : "Name This Note"
        alert.informativeText = list ? "Leave it empty to name the list after its first task."
            : "Leave it empty to name the note after its first line."
        if note.sync != nil {
            alert.informativeText += " The name goes to the other devices the list syncs with."
        }
        let field = NSTextField(string: note.name ?? "")
        field.placeholderString = note.contentsTitle
        field.lineBreakMode = .byTruncatingTail
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .alertFirstButtonReturn {
                    self.setName(Note.name(field.stringValue), of: page)
                }
                if self.pages.indices.contains(self.selected) { self.pages[self.selected].focus() }
            }
        }
    }

    func setName(_ name: String?, of page: NotePage) {
        let old = page.name
        guard name != old, pages.contains(where: { $0 === page }) else { return }
        page.name = name
        noteChanged()
        page.undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { controller.setName(old, of: page) }
        }
        page.undo.setActionName("Rename")
    }

    // MARK: Converting

    /// Whether the tab you're on is a note, which can become a to-do list
    var canConvertToList: Bool { pages[selected].note.kind == .text }

    /// Turns a note into a to-do list in the same tab, a task to each line that has something on it. Undo turns it
    /// back into the note as it was.
    func convertToList(at index: Int? = nil) {
        let index = index ?? selected
        guard pages.indices.contains(index), pages[index].note.kind == .text else {
            NSSound.beep()
            return
        }
        show()
        convertToList(pages[index])
    }

    /// Turns a note's tab into a to-do list, whether or not the note is showing
    func convertToList(_ page: NotePage) {
        guard page.note.kind == .text else { return }
        replace(page, with: makePage(page.note.asList), actionName: "Convert to To-Do List")
    }

    // MARK: Clearing checked tasks

    /// Whether the tab you're on is a to-do list with checked tasks
    var canClearChecked: Bool { (pages[selected] as? TodoList)?.hasChecked ?? false }

    /// Deletes the checked tasks from the to-do list you're on. Undo puts them back.
    func clearChecked() {
        guard let list = pages[selected] as? TodoList, list.hasChecked else {
            NSSound.beep()
            return
        }
        show()
        list.clearChecked()
    }

    /// Puts one tab's page in place of another, and lets Undo and Redo swap them back. The tab's Undo goes with it, so
    /// what was done before the swap can still be undone after it.
    private func replace(_ page: NotePage, with replacement: NotePage, actionName: String) {
        guard let index = pages.firstIndex(where: { $0 === page }) else { return }
        replacement.undo = page.undo
        pages[index] = replacement
        // Text size or sticky note mode may have changed since an undone page was last shown
        replacement.apply(look)
        select(index)
        replacement.undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.replace(replacement, with: page, actionName: actionName)
            }
        }
        replacement.undo.setActionName(actionName)
        save()
    }

    // MARK: Syncing

    /// Whether the tab you're on is a to-do list, which can sync
    var canSync: Bool { pages[selected].note.kind == .list }

    /// Whether the tab you're on is a synced list
    var isSynced: Bool { pages[selected].sync != nil }

    /// Sync List…: picks the folder a list syncs through and the devices it goes to, or stops it syncing
    func showSyncSheet(for index: Int? = nil) {
        let index = index ?? selected
        guard window.attachedSheet == nil, pages.indices.contains(index), pages[index].note.kind == .list else {
            NSSound.beep()
            return
        }
        show()
        select(index)
        let page = pages[index]
        var lastSynced: Date?
        if case .stopped(_, let last)? = listSync.state(of: page) { lastSynced = last }
        // Kept until the next one, since its own button is still finishing when it reports back
        let sheet = SyncSheet(listTitle: page.note.title, list: page.id, current: page.sync, lastSynced: lastSynced)
        syncSheet = sheet
        sheet.begin(for: window) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .sync(let folder, let devices)?:
                if page.sync == nil {
                    self.listSync.start(page, in: folder, to: devices)
                } else {
                    self.listSync.send(page, to: devices)
                }
            case .stop?:
                self.listSync.stop(page)
            case nil:
                return
            }
            self.updateTabs()
            self.save()
        }
    }

    /// Add Sync Folder…: a folder other devices sync lists through, so they can send them here. It then shows the lists
    /// already in the folder, to bring here. Picking a folder YANA already uses shows them again.
    func addSyncFolder() {
        show()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        panel.message = "Choose the folder your other devices sync lists through, such as YANA Sync in iCloud Drive or one shared with you"
        panel.directoryURL = SyncFolders.hasICloudDrive ? SyncFolders.iCloudDrive : nil
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                do {
                    let folder = try self.listSync.add(url)
                    Task { await self.showLists(in: folder) }
                } catch {
                    Alert.show("Couldn't add “\(url.lastPathComponent)”", error.localizedDescription)
                }
            }
        }
    }

    /// The most lists or devices' lists offered at once, so the sheet fits on the screen
    private static let offeredAtOnce = 10

    /// After a sync folder is added: the lists in it that aren't on this Mac, each ticked to bring here
    private func showLists(in folder: SyncFolder) async {
        let lists = await listSync.lists(in: folder)
        guard !lists.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "“\(folder.name)” is ready to sync through"
            alert.informativeText = "No lists in it are waiting to come to this Mac. To send one from here, open the list and choose Sync This List…. Lists your other devices send to this Mac show up as tabs on their own."
            alert.beginSheetModal(for: window) { _ in }
            return
        }
        let shown = Array(lists.prefix(Self.offeredAtOnce))
        var about = "These lists sync through the folder on your other devices. A ticked one gets a tab here and stays in sync with them."
        if lists.count > shown.count {
            about += " There are \(lists.count - shown.count) more: choose Add Sync Folder… and pick this folder again to see them."
        }
        choose("Bring lists from “\(folder.name)” to this Mac?", about, from: shown.map(\.summary),
               button: "Bring Here") { [weak self] ticked in
            guard let self, !ticked.isEmpty else { return }
            let ids = ticked.map { shown[$0].id }
            Task {
                await self.listSync.join(ids, in: folder)
                // Shows the first one brought over
                if let index = self.pages.firstIndex(where: { ids.contains($0.id) }) { self.select(index) }
            }
        }
    }

    /// A sheet with a ticked checkbox for each of `titles`. Its first button gives back the ones left ticked, by their
    /// place in `titles`. Not Now gives back nothing.
    private func choose(_ message: String, _ about: String, from titles: [String], button: String,
                        then: @escaping ([Int]) -> Void) {
        let (alert, boxes) = Self.choice(message, about, from: titles, button: button)
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return then([]) }
                then(boxes.indices.filter { boxes[$0].state == .on })
            }
        }
    }

    /// The alert `choose` shows, with its checkboxes in the order of `titles`
    static func choice(_ message: String, _ about: String, from titles: [String],
                       button: String) -> (alert: NSAlert, boxes: [NSButton]) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = about
        let width: CGFloat = 260
        let boxes = titles.map { title in
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = .on
            // A long name is cut short, and shown whole when the mouse rests on it
            box.lineBreakMode = .byTruncatingTail
            box.toolTip = title
            box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return box
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let height = boxes.reduce(0) { $0 + $1.intrinsicContentSize.height } + CGFloat(max(boxes.count - 1, 0)) * 6
        stack.frame = NSRect(x: 0, y: 0, width: width, height: height)
        alert.accessoryView = stack
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Not Now")
        return (alert, boxes)
    }

    // MARK: A new device in a sync folder

    private func showOffersSoon() {
        guard !offers.isEmpty else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(showOffers), object: nil)
        perform(#selector(showOffers), with: nil, afterDelay: 0)
    }

    /// Offers the next new device the lists that sync through its folder, once the note is showing with nothing over it
    @objc private func showOffers() {
        guard window.isVisible, window.attachedSheet == nil, !offers.isEmpty else { return }
        let (device, folder) = offers.removeFirst()
        // Only the lists that still don't go to it: it may have brought some over itself by now
        let lists = Array(listSync.lists(notGoingTo: device.id, in: folder).prefix(Self.offeredAtOnce))
        guard !lists.isEmpty else { return showOffersSoon() }
        choose("“\(device.name)” now uses “\(folder.name)”",
               "Send it the lists that sync through that folder? A ticked list shows up on it and stays in sync. Sync Settings for a list changes this later.",
               from: lists.map { $0.note.title }, button: "Send") { [weak self] ticked in
            guard let self else { return }
            for page in ticked.map({ lists[$0] }) {
                guard let sync = page.sync, self.pages.contains(where: { $0 === page }) else { continue }
                self.listSync.send(page, to: sync.devices.filter { $0 != ThisDevice.id } + [device.id])
            }
            if !ticked.isEmpty {
                self.updateTabs()
                self.save()
            }
            self.showOffersSoon()
        }
    }

    // MARK: Text files

    /// The folder a text file was last opened from or saved to, where the next file panel starts
    private var textFolder: URL? {
        get { UserDefaults.standard.url(forKey: Key.textFolder) }
        set { UserDefaults.standard.set(newValue, forKey: Key.textFolder) }
    }

    /// The text file the tab you're on was opened from or last saved to
    var currentFile: URL? { pages[selected].file }

    /// Opens a text file into the tab you're on if it's an empty note, else into a new tab. With four tabs already, it
    /// offers to replace the one you're on. A file that's already open goes to its tab. A file saved from a to-do list
    /// opens as a list.
    func openTextFile() {
        show()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.directoryURL = textFolder
        panel.message = "Choose a text file to open in YANA"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.open(url) }
        }
    }

    private func open(_ url: URL) {
        textFolder = url.deletingLastPathComponent()
        if let index = pages.firstIndex(where: { $0.file?.standardizedFileURL == url.standardizedFileURL }) {
            select(index)
            return
        }
        let text: String
        do {
            text = Note.text(fromFile: try Data(contentsOf: url))
        } catch {
            logger.error("Couldn't open a text file: \(error.localizedDescription, privacy: .public)")
            Alert.show("Couldn't open “\(url.lastPathComponent)”", error.localizedDescription)
            return
        }
        let page = makePage(Note.opened(fromText: text, file: url))
        let current = pages[selected].note
        if current.kind == .text && current.isEmpty {
            pages[selected] = page
            select(selected)
        } else if pages.count < Note.limit {
            pages.append(page)
            select(pages.count - 1)
        } else {
            guard Alert.confirm("Replace “\(current.title)” with “\(url.lastPathComponent)”?",
                                "YANA holds up to \(Note.limit) notes. What's in this one goes to Recently Deleted, in the … menu, for 30 days.",
                                button: "Replace", cancel: "Cancel") else { return }
            store.keepDeleted(current)
            pages[selected].undo.removeAllActions()
            pages[selected] = page
            select(selected)
        }
        show()
        save()
    }

    /// Saves the tab you're on back to the file it was opened from or last saved to. Without one, asks where.
    func saveTextFile() {
        let page = pages[selected]
        guard let file = page.file else { return saveTextFileAs() }
        if !write(page.note, to: file) { saveTextFileAs() }
    }

    /// Saves the tab you're on as a new .txt file, starting where its file is, or else where the last one went. A to-do
    /// list's tasks go one to a line. Save then writes to this file.
    func saveTextFileAs() {
        show()
        let page = pages[selected]
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let file = page.file {
            panel.directoryURL = file.deletingLastPathComponent()
            panel.nameFieldStringValue = file.lastPathComponent
        } else {
            panel.directoryURL = textFolder
            let name = page.note.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            panel.nameFieldStringValue = name + ".txt"
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self, self.write(page.note, to: url) else { return }
                page.file = url
                self.textFolder = url.deletingLastPathComponent()
                self.save()
            }
        }
    }

    private func write(_ note: Note, to url: URL) -> Bool {
        do {
            try note.plainText.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            logger.error("Couldn't save a text file: \(error.localizedDescription, privacy: .public)")
            Alert.show("Couldn't save “\(url.lastPathComponent)”", error.localizedDescription)
            return false
        }
    }

    private func makePage(_ note: Note) -> NotePage {
        let page: NotePage = switch note.kind {
        case .text: TextPage(text: note.text)
        case .list: TodoList(items: note.items)
        }
        page.id = note.id
        page.name = note.name
        page.sync = note.sync
        page.file = note.file
        page.apply(look)
        page.onChange = { [unowned self] in self.noteChanged() }
        return page
    }

    /// Shows the tabs once there's more than one note, or once the only one has a name or has stopped syncing, so that
    /// shows
    private func updateTabs() {
        let notes = pages.map { $0.note }
        let sync = pages.map { listSync.state(of: $0) }
        let stopped = sync.contains { state in
            if case .stopped? = state { return true }
            return false
        }
        let showTabs = notes.count > 1 || notes.first?.name != nil || stopped
        if tabBar.isHidden == showTabs {
            tabBar.isHidden = !showTabs
            (showTabs ? tabsHidden : tabsShown).isActive = false
            (showTabs ? tabsShown : tabsHidden).isActive = true
        }
        tabBar.show(notes, selected: selected, sync: sync)
        newButton.isEnabled = notes.count < Note.limit
        newButton.toolTip = newButton.isEnabled ? "New note or to-do list" : "YANA holds up to \(Note.limit) notes"
    }

    // MARK: Saving

    private func noteChanged() {
        updateTabs()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.save()
                // A synced list's changes go to the other devices now, not at the next look
                self?.listSync.run()
            }
        }
    }

    func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        store.save(pages.map { listSync.note(of: $0) })
    }

    // MARK: Title bar controls

    private func makeAccessory() -> NSTitlebarAccessoryViewController {
        configure(newButton, symbol: "plus", tip: "New note or to-do list", action: #selector(showNewMenu))
        configure(menuButton, symbol: "ellipsis.circle", tip: "YANA options", action: #selector(showMenu))

        configure(pinButton, symbol: "pin", tip: "Keep on top of other windows", action: #selector(pinClicked))
        pinButton.setButtonType(.pushOnPushOff)
        pinButton.alternateImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Kept on top")

        opacitySlider.minValue = Self.opacityRange.lowerBound
        opacitySlider.maxValue = Self.opacityRange.upperBound
        opacitySlider.isContinuous = true
        opacitySlider.controlSize = .small
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.toolTip = "Transparency"
        opacitySlider.setAccessibilityLabel("Transparency")
        opacitySlider.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let dim = NSImageView(image: NSImage(systemSymbolName: "circle.lefthalf.filled",
                                             accessibilityDescription: nil) ?? NSImage())
        dim.contentTintColor = .secondaryLabelColor
        dim.toolTip = "Transparency"

        let stack = NSStackView(views: [newButton, menuButton, pinButton, dim, opacitySlider])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let width = max(stack.fittingSize.width, 170) + 10
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = container
        return accessory
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    @objc private func showNewMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let note = NSMenuItem(title: "New Note", action: #selector(newTextNote), keyEquivalent: "n")
        let list = NSMenuItem(title: "New To-Do List", action: #selector(newList), keyEquivalent: "n")
        list.keyEquivalentModifierMask = [.command, .shift]
        for item in [note, list] {
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func newTextNote() {
        newNote(.text)
    }

    @objc private func newList() {
        newNote(.list)
    }

    @objc private func showMenu(_ sender: NSButton) {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func pinClicked(_ sender: NSButton) {
        isPinned = sender.state == .on
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        window.alphaValue = sender.doubleValue
        UserDefaults.standard.set(sender.doubleValue, forKey: Key.opacity)
    }

    /// Kept on top floats over other apps' windows. Otherwise the note falls behind whatever you click.
    private func applyPinned() {
        let pinned = isPinned
        window.level = pinned ? .floating : .normal
        pinButton.state = pinned ? .on : .off
        pinButton.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
        pinButton.toolTip = pinned ? "Kept on top. Click to let it fall behind other windows."
            : "Keep on top of other windows"
    }

    // MARK: Look

    private var look: Look { Look(textSize: textSize, sticky: isSticky) }

    /// Sticky note mode turns the whole window yellow, in light mode whatever the Mac uses
    private func applyLook() {
        let look = self.look
        window.appearance = look.sticky ? NSAppearance(named: .aqua) : nil
        window.titlebarAppearsTransparent = look.sticky
        window.backgroundColor = look.sticky ? .stickyYellow : .windowBackgroundColor
        pages.forEach { $0.apply(look) }
    }

    private var textSize: CGFloat {
        let size = UserDefaults.standard.double(forKey: Key.textSize)
        return size > 0 ? size : Self.defaultTextSize
    }

    func changeTextSize(by step: CGFloat) {
        setTextSize(min(max(textSize + step, 9), 36))
    }

    func resetTextSize() {
        setTextSize(Self.defaultTextSize)
    }

    private func setTextSize(_ size: CGFloat) {
        UserDefaults.standard.set(Double(size), forKey: Key.textSize)
        applyLook()
    }
}

extension NoteWindowController: SyncHost {
    var notePages: [NotePage] { pages }

    func showSynced(_ note: Note, on page: NotePage) {
        (page as? TodoList)?.show(note.items)
        page.name = note.name
        page.sync = note.sync
        updateTabs()
        // Saved as it is, not as a change made here, which would go looking for the other devices' changes again
        save()
    }

    func addSynced(_ note: Note) {
        pages.append(makePage(note))
        updateTabs()
        save()
    }

    func removeSynced(_ page: NotePage) {
        guard let index = pages.firstIndex(where: { $0 === page }) else { return }
        // Another device took it off this Mac, so what this Mac had can still be put back
        store.keepDeleted(page.note)
        page.undo.removeAllActions()
        if pages.count == 1 {
            pages[0] = makePage(Note(kind: .text))
            select(0)
        } else {
            pages.remove(at: index)
            select(index < selected ? selected - 1 : min(selected, pages.count - 1))
        }
        // The page shown may have been the one taken away
        if page.view.superview != nil {
            page.view.removeFromSuperview()
            select(min(selected, pages.count - 1))
        }
        save()
    }

    func syncStateChanged() {
        updateTabs()
    }

    func offer(_ device: DeviceCard, in folder: SyncFolder) {
        guard !offers.contains(where: { $0.device.id == device.id && $0.folder.id == folder.id }) else { return }
        offers.append((device, folder))
        showOffersSoon()
    }
}
