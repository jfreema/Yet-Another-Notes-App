import AppKit

/// The note window's tabs, one per note, shown once there's more than one or the only one has a name. Double-click a tab
/// to rename it, or right-click it to rename it, make a note a to-do list, sync a list with other devices, or delete it.
/// A synced list has a sync mark, which turns into an orange warning when its sync folder can't be read.
@MainActor
final class TabBar: NSView {
    var onSelect: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onConvert: ((Int) -> Void)?
    var onSync: ((Int) -> Void)?
    var onRename: ((Int) -> Void)?
    private let stack = NSStackView()
    private static let listImage = NSImage(systemSymbolName: "checklist", accessibilityDescription: "To-do list")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
    private static let syncedImage = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                             accessibilityDescription: "Synced to-do list")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
    private static let stoppedImage = NSImage(systemSymbolName: "exclamationmark.arrow.triangle.2.circlepath",
                                              accessibilityDescription: "Synced to-do list that isn't syncing")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange])))

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows a tab for each note. `sync` says, for each, whether it's syncing: nil for one that doesn't sync.
    func show(_ notes: [Note], selected: Int, sync: [SyncState?] = []) {
        var buttons = stack.arrangedSubviews.compactMap { $0 as? TabButton }
        while buttons.count < notes.count {
            let button = makeButton()
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        while buttons.count > notes.count {
            buttons.removeLast().removeFromSuperview()
        }
        for (index, (button, note)) in zip(buttons, notes).enumerated() {
            button.tag = index
            button.title = note.title
            let problem = (index < sync.count ? sync[index] : nil)?.problem()
            if let problem {
                button.toolTip = "\(note.title): \(problem)"
                button.image = Self.stoppedImage
            } else {
                button.toolTip = note.sync == nil ? note.title : "\(note.title) (synced)"
                button.image = note.kind == .list ? (note.sync == nil ? Self.listImage : Self.syncedImage) : nil
            }
            button.imagePosition = note.kind == .list ? .imageLeading : .noImage
            button.state = index == selected ? .on : .off
            if let items = button.menu?.items, items.count == 4 {
                items.forEach { $0.tag = index }
                items[0].title = note.kind == .list ? "Rename List…" : "Rename Note…"
                // A list is already a list, and only lists sync
                items[1].isHidden = note.kind == .list
                items[2].isHidden = note.kind != .list
                items[2].title = note.sync == nil ? "Sync List…" : "Sync Settings…"
                items[3].title = note.kind == .list ? "Delete List" : "Delete Note"
                // There's always one tab
                items[3].isHidden = notes.count == 1
            }
        }
    }

    /// A scope bar button: the selected tab stays pressed
    private func makeButton() -> TabButton {
        let button = TabButton(title: "", target: self, action: #selector(clicked))
        button.onDoubleClick = { [unowned self, unowned button] in self.onRename?(button.tag) }
        button.bezelStyle = .recessed
        button.setButtonType(.pushOnPushOff)
        button.showsBorderOnlyWhileMouseInside = true
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename Note…", action: #selector(renameClicked), keyEquivalent: "")
        let convert = NSMenuItem(title: "Convert to To-Do List", action: #selector(convertClicked), keyEquivalent: "")
        let sync = NSMenuItem(title: "Sync List…", action: #selector(syncClicked), keyEquivalent: "")
        let delete = NSMenuItem(title: "Delete Note", action: #selector(deleteClicked), keyEquivalent: "")
        for item in [rename, convert, sync, delete] {
            item.target = self
            menu.addItem(item)
        }
        button.menu = menu
        return button
    }

    @objc private func clicked(_ sender: NSButton) {
        onSelect?(sender.tag)
    }

    @objc private func renameClicked(_ sender: NSMenuItem) {
        onRename?(sender.tag)
    }

    @objc private func convertClicked(_ sender: NSMenuItem) {
        onConvert?(sender.tag)
    }

    @objc private func syncClicked(_ sender: NSMenuItem) {
        onSync?(sender.tag)
    }

    @objc private func deleteClicked(_ sender: NSMenuItem) {
        onDelete?(sender.tag)
    }
}

/// A tab, which a double-click renames
@MainActor
final class TabButton: NSButton {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // The first click has already picked the tab
        if event.clickCount == 2, let onDoubleClick {
            onDoubleClick()
            return
        }
        super.mouseDown(with: event)
    }
}
