import AppKit
import UniformTypeIdentifiers

/// The note window: up to four tabs of notes and to-do lists. Closing it hides it to the menu bar.
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
    private let store = NoteStore()
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

    override init() {
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
        pages = store.load().map { makePage($0) }

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
    }

    func hide() {
        save()
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
            // Undo stays with the tab it's for
            window.undoManager?.removeAllActions()
        }
        updateTabs()
        if window.isVisible { pages[index].focus() }
    }

    /// Asks first, unless there's nothing in it
    func deleteNote(at index: Int) {
        guard pages.count > 1, pages.indices.contains(index) else { return }
        let note = pages[index].note
        if !note.isEmpty {
            let what = note.kind == .list ? "to-do list" : "note"
            guard Alert.confirm("Delete “\(note.title)”?", "The \(what) can't be brought back.", button: "Delete",
                                cancel: "Cancel") else { return }
        }
        pages.remove(at: index)
        select(index < selected ? selected - 1 : min(selected, pages.count - 1))
        save()
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
    /// offers to replace the one you're on. A file that's already open goes to its tab.
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
        let page = makePage(Note(kind: .text, text: text, file: url))
        let current = pages[selected].note
        if current.kind == .text && current.isEmpty {
            pages[selected] = page
            select(selected)
        } else if pages.count < Note.limit {
            pages.append(page)
            select(pages.count - 1)
        } else {
            guard Alert.confirm("Replace “\(current.title)” with “\(url.lastPathComponent)”?",
                                "YANA holds up to \(Note.limit) notes. What's in this one can't be brought back.",
                                button: "Replace", cancel: "Cancel") else { return }
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
        page.file = note.file
        page.apply(look)
        page.onChange = { [unowned self] in self.noteChanged() }
        return page
    }

    /// Shows the tabs once there's more than one note, named for what's in them
    private func updateTabs() {
        let notes = pages.map { $0.note }
        let showTabs = notes.count > 1
        if tabBar.isHidden == showTabs {
            tabBar.isHidden = !showTabs
            (showTabs ? tabsHidden : tabsShown).isActive = false
            (showTabs ? tabsShown : tabsHidden).isActive = true
        }
        tabBar.show(notes, selected: selected)
        newButton.isEnabled = notes.count < Note.limit
        newButton.toolTip = newButton.isEnabled ? "New note or to-do list" : "YANA holds up to \(Note.limit) notes"
    }

    // MARK: Saving

    private func noteChanged() {
        updateTabs()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        store.save(pages.map { $0.note })
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
