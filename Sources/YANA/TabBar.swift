import AppKit

/// The note window's tabs, one per note, shown once there's more than one. Right-click a tab to delete it.
@MainActor
final class TabBar: NSView {
    var onSelect: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    private let stack = NSStackView()
    private static let listImage = NSImage(systemSymbolName: "checklist", accessibilityDescription: "To-do list")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))

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

    func show(_ notes: [Note], selected: Int) {
        var buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
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
            button.toolTip = note.title
            button.image = note.kind == .list ? Self.listImage : nil
            button.imagePosition = note.kind == .list ? .imageLeading : .noImage
            button.state = index == selected ? .on : .off
            if let delete = button.menu?.items.first {
                delete.title = note.kind == .list ? "Delete List" : "Delete Note"
                delete.tag = index
            }
        }
    }

    /// A scope bar button: the selected tab stays pressed
    private func makeButton() -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(clicked))
        button.bezelStyle = .recessed
        button.setButtonType(.pushOnPushOff)
        button.showsBorderOnlyWhileMouseInside = true
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let menu = NSMenu()
        let delete = NSMenuItem(title: "Delete Note", action: #selector(deleteClicked), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        button.menu = menu
        return button
    }

    @objc private func clicked(_ sender: NSButton) {
        onSelect?(sender.tag)
    }

    @objc private func deleteClicked(_ sender: NSMenuItem) {
        onDelete?(sender.tag)
    }
}
