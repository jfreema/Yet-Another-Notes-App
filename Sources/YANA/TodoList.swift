import AppKit

/// A to-do list. Type in the last row and press Return to add a task. Checking a task crosses it out and shows a × that
/// deletes it. Click a task to edit it, or drag it to move it.
@MainActor
final class TodoList: NSView, NotePage, NSTextFieldDelegate {
    var onChange: (() -> Void)?
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let addRow = NSStackView()
    private let addButton = NSButton()
    private let addField = NSTextField(string: "")
    private var look = Look(textSize: NoteWindowController.defaultTextSize, sticky: false)

    /// The space at the list's sides
    private static let inset: CGFloat = 8

    init(items: [ToDo]) {
        super.init(frame: .zero)

        let document = ListDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: Self.inset, bottom: 6, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add a task")
        addButton.imagePosition = .imageOnly
        addButton.isBordered = false
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addClicked)
        Self.alignLeading(addButton)

        addField.isBordered = false
        addField.drawsBackground = false
        addField.focusRingType = .none
        addField.lineBreakMode = .byTruncatingTail
        addField.cell?.sendsActionOnEndEditing = false
        addField.target = self
        addField.action = #selector(addTask)
        addField.setContentHuggingPriority(.init(1), for: .horizontal)
        addField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addRow.orientation = .horizontal
        addRow.distribution = .fill
        addRow.spacing = 4
        addRow.edgeInsets = NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)
        addRow.addArrangedSubview(addButton)
        addRow.addArrangedSubview(addField)
        arrange(addRow, at: 0)

        for item in items {
            arrange(makeRow(item), at: rows.count)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The tasks, top to bottom. The row for adding one comes after them.
    private var rows: [ToDoRow] { stack.arrangedSubviews.compactMap { $0 as? ToDoRow } }

    // MARK: NotePage

    var view: NSView { self }

    var note: Note {
        // A task emptied while it's being edited is deleted when the editing ends, so it isn't kept
        Note(kind: .list, items: rows.map(\.item).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    func focus() {
        window?.makeFirstResponder(addField)
    }

    func apply(_ look: Look) {
        self.look = look
        scroll.backgroundColor = look.background
        addField.font = look.font
        addField.textColor = look.textColor
        addField.placeholderAttributedString = NSAttributedString(string: "Add a task", attributes: [
            .font: look.font, .foregroundColor: NSColor.placeholderTextColor,
        ])
        rows.forEach { $0.apply(look) }
    }

    // MARK: Adding and deleting

    /// Checkboxes and the + share a width, so the tasks line up with the one being added
    static func alignLeading(_ view: NSView) {
        view.widthAnchor.constraint(equalToConstant: 18).isActive = true
    }

    /// Puts a row in the list, as wide as the list
    private func arrange(_ row: NSView, at index: Int) {
        stack.insertArrangedSubview(row, at: index)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true
    }

    private func makeRow(_ item: ToDo) -> ToDoRow {
        let row = ToDoRow(item: item, look: look)
        row.list = self
        row.field.delegate = self
        return row
    }

    @objc private func addClicked(_ sender: NSButton) {
        focus()
    }

    /// Return in the last row adds its task, and leaves the cursor there for the next one
    @objc private func addTask(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        arrange(makeRow(ToDo(text: text)), at: rows.count)
        sender.stringValue = ""
        onChange?()
        perform(#selector(focusLater), with: nil, afterDelay: 0)
        layoutSubtreeIfNeeded()
        addRow.scrollToVisible(addRow.bounds)
    }

    func changed() {
        onChange?()
    }

    /// Deletes a task once the event that asked for it is done, since the task's own button or text is still handling it
    func remove(_ row: ToDoRow) {
        perform(#selector(removeNow(_:)), with: row, afterDelay: 0)
    }

    @objc private func removeNow(_ row: ToDoRow) {
        guard row.superview === stack else { return }
        stack.removeArrangedSubview(row)
        row.removeFromSuperview()
        onChange?()
    }

    @objc private func focusLater() {
        focus()
    }

    // MARK: Editing

    func controlTextDidChange(_ notification: Notification) {
        guard let row = row(for: notification.object) else { return }
        row.item.text = row.field.stringValue
        onChange?()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let row = row(for: notification.object) else { return }
        let text = row.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            // Emptying a task deletes it
            remove(row)
        } else {
            row.item.text = text
            row.refresh()
            onChange?()
        }
        // Return goes on to adding a task, once this one has finished editing
        if (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue {
            perform(#selector(focusLater), with: nil, afterDelay: 0)
        }
    }

    private func row(for object: Any?) -> ToDoRow? {
        guard let field = object as? NSTextField else { return nil }
        return rows.first { $0.field === field }
    }

    // MARK: Clicking and dragging

    /// A click below the tasks goes to adding one
    override func mouseDown(with event: NSEvent) {
        focus()
    }

    /// A click on a task edits it, and a drag moves it
    func track(_ row: ToDoRow, from event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            if !dragging {
                guard hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 else { continue }
                dragging = true
                row.isLifted = true
                NSCursor.closedHand.push()
            }
            move(row, to: next.locationInWindow.y)
            _ = stack.autoscroll(with: next)
        }
        if dragging {
            NSCursor.pop()
            row.isLifted = false
            onChange?()
        } else {
            edit(row, at: start)
        }
    }

    private func move(_ row: ToDoRow, to y: CGFloat) {
        let others = rows.filter { $0 !== row }
        // Window coordinates go up, so the tasks whose middles are above the mouse stay above the one being dragged
        let index = others.filter { $0.convert(NSPoint(x: 0, y: $0.bounds.midY), to: nil).y > y }.count
        guard rows.firstIndex(where: { $0 === row }) != index else { return }
        stack.removeArrangedSubview(row)
        stack.insertArrangedSubview(row, at: index)
        stack.layoutSubtreeIfNeeded()
    }

    private func edit(_ row: ToDoRow, at point: NSPoint) {
        guard let window, window.makeFirstResponder(row.field),
              let editor = row.field.currentEditor() as? NSTextView else { return }
        // Puts the cursor where you clicked
        let index = editor.characterIndexForInsertion(at: editor.convert(point, from: nil))
        editor.setSelectedRange(NSRange(location: index, length: 0))
    }
}

/// One task: a checkbox, its text, and a × once it's checked
@MainActor
final class ToDoRow: NSView {
    var item: ToDo
    weak var list: TodoList?
    let field = NSTextField(string: "")
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let deleteButton = NSButton()
    private let content = NSStackView()
    private var look: Look

    /// Highlights it while it's being dragged
    var isLifted = false {
        didSet {
            wantsLayer = true
            layer?.cornerRadius = 4
            layer?.backgroundColor = isLifted ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor : nil
        }
    }

    init(item: ToDo, look: Look) {
        self.item = item
        self.look = look
        super.init(frame: .zero)

        checkbox.target = self
        checkbox.action = #selector(toggled)
        TodoList.alignLeading(checkbox)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.init(1), for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete task")
        deleteButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        deleteButton.imagePosition = .imageOnly
        deleteButton.isBordered = false
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.toolTip = "Delete"
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)

        content.orientation = .horizontal
        content.distribution = .fill
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [checkbox, field, deleteButton] {
            content.addArrangedSubview(view)
        }
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func apply(_ look: Look) {
        self.look = look
        refresh()
    }

    /// Shows the task as it is: crossed out with a × when it's done
    func refresh() {
        checkbox.state = item.done ? .on : .off
        checkbox.setAccessibilityLabel(item.text)
        deleteButton.isHidden = !item.done
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: look.font,
            .foregroundColor: item.done ? look.doneColor : look.textColor,
            .paragraphStyle: style,
        ]
        if item.done {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        // The font and color are for typing, and the attributes for showing it
        field.font = look.font
        field.textColor = look.textColor
        field.attributedStringValue = NSAttributedString(string: item.text, attributes: attributes)
        field.toolTip = item.text
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // The text takes clicks only while it's being edited. Otherwise they come here, so the task can be dragged.
        return hit === field || hit === content ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        list?.track(self, from: event)
    }

    @objc private func toggled(_ sender: NSButton) {
        item.done = sender.state == .on
        refresh()
        list?.changed()
    }

    @objc private func deleteClicked(_ sender: NSButton) {
        list?.remove(self)
    }
}

/// The list's scrolling content, laid out from the top
private final class ListDocument: NSView {
    override var isFlipped: Bool { true }
}
