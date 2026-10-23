import AppKit

/// The one note: a window that hides to the menu bar when closed
@MainActor
final class NoteWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    let window: NSWindow
    private let textView: NSTextView
    private let pinButton = NSButton()
    private let menuButton = NSButton()
    private let opacitySlider = NSSlider()
    private let store = NoteStore()
    private var saveTimer: Timer?
    /// The status item's menu, also under the note's … button
    var menuProvider: (() -> NSMenu)?

    private enum Key {
        static let pinned = "pinned"
        static let opacity = "opacity"
        static let textSize = "textSize"
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

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 440),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init()

        window.title = "YANA"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 260, height: 160)
        // Comes to the desktop you're on, and over full-screen apps when kept on top
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = scroll
        window.addTitlebarAccessoryViewController(makeAccessory())

        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.font = .systemFont(ofSize: textSize)
        textView.string = store.load()
        textView.delegate = self

        // Where it was last time, else under the menu bar's right side
        if !window.setFrameUsingName(Key.frame) {
            if let screen = NSScreen.main?.visibleFrame {
                window.setFrameTopLeftPoint(NSPoint(x: screen.maxX - window.frame.width - 80, y: screen.maxY - 8))
            }
        }
        window.setFrameAutosaveName(Key.frame)

        let opacity = UserDefaults.standard.object(forKey: Key.opacity) as? Double ?? 1
        opacitySlider.doubleValue = opacity
        window.alphaValue = opacity
        applyPinned()
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
        window.makeFirstResponder(textView)
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

    // MARK: Saving

    func textDidChange(_ notification: Notification) {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        store.save(textView.string)
    }

    // MARK: Title bar controls

    private func makeAccessory() -> NSTitlebarAccessoryViewController {
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
        opacitySlider.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let dim = NSImageView(image: NSImage(systemSymbolName: "circle.lefthalf.filled",
                                             accessibilityDescription: nil) ?? NSImage())
        dim.contentTintColor = .secondaryLabelColor
        dim.toolTip = "Transparency"

        let stack = NSStackView(views: [menuButton, pinButton, dim, opacitySlider])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 190, height: 28))
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

    // MARK: Text size

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
        textView.font = .systemFont(ofSize: size)
    }
}
