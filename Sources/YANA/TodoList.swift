import AppKit

/// A to-do list. Type in the last row and press Return to add a task, or press Return in a task to add one below it.
/// Checking a task crosses it out and shows a × that deletes it, and Clear Checked under the list deletes all the checked
/// ones. Undo puts deleted tasks back. Click a task to edit it, or drag it to move it. A long task wraps onto as many
/// lines as it needs. The tasks are numbered down the left side, like the lines of a text note.
@MainActor
final class TodoList: NSView, NotePage, NSTextFieldDelegate {
    var id = UUID()
    var name: String?
    var sync: SyncInfo?
    var file: URL?
    var onChange: (() -> Void)?
    var undo = UndoManager()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let addRow = NSView()
    private let addButton = NSButton()
    private let addField = TaskField.make()
    /// How far in the row for adding a task starts, past the numbers
    private lazy var addIndent = addButton.leadingAnchor.constraint(equalTo: addRow.leadingAnchor)
    /// Keeps the + on the first line of what's being typed
    private var addOnFirstLine: NSLayoutConstraint?
    /// Under the row for adding a task, while some tasks are checked
    private let clearRow = NSStackView()
    private let clearButton = NSButton()
    private var look = Look(textSize: NoteWindowController.defaultTextSize, sticky: false)
    /// The task being edited, whose number is bolder
    private weak var editing: ToDoRow?
    /// While a click on a task is being followed, which may become a drag
    private var tracking = false

    /// The space at the list's right side. The numbers make the space on the left.
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
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: Self.inset)
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

        addField.cell?.sendsActionOnEndEditing = false
        addField.target = self
        addField.action = #selector(addTask)

        // Laid out like a task, so what's typed here wraps the way it will once it's one
        for view in [addButton, addField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addRow.addSubview(view)
        }
        addOnFirstLine = addField.fit(addRow, beside: addButton)
        NSLayoutConstraint.activate([
            addIndent,
            addField.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: ToDoRow.spacing),
            addField.trailingAnchor.constraint(equalTo: addRow.trailingAnchor),
        ])
        arrange(addRow, at: 0)

        clearButton.isBordered = false
        clearButton.toolTip = "Delete the checked tasks"
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        clearRow.orientation = .horizontal
        clearRow.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 1, right: 0)
        clearRow.addView(clearButton, in: .leading)
        arrange(clearRow, at: 1)

        for item in items {
            arrange(makeRow(item), at: rows.count)
        }
        renumber()
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
        Note(id: id, kind: .list, items: rows.map(\.item).filter { !$0.isBlank }, name: name, file: file, sync: sync)
    }

    /// The list's own Undo, which is also what a task being edited uses
    override var undoManager: UndoManager? { undo }

    /// Whether a task is being clicked or dragged, when changes from other devices wait for the mouse to come up
    var isDragging: Bool { tracking }

    /// Shows the tasks as merged with other devices' changes. A task that's still there keeps its row, so the one being
    /// edited keeps its cursor and what's typed, unless another device changed or deleted that very task. An empty task
    /// just opened here stays where it is, and so does what's being typed in the row for adding a task.
    func show(_ items: [ToDo]) {
        let before = rows
        let shown = before.map(\.item).showing(items)

        var stoppedEditing = false
        if let row = editing, shown.first(where: { $0.id == row.item.id })?.looksLike(row.item) != true {
            stopEditing(row)
            stoppedEditing = true
        }

        var have: [UUID: ToDoRow] = [:]
        for row in before where have[row.item.id] == nil {
            have[row.item.id] = row
        }
        let after: [ToDoRow] = shown.map { item in
            guard let row = have[item.id] else { return makeRow(item) }
            let same = row.item.looksLike(item)
            row.item = item
            // Not the one being edited, which looks the same: showing it again would end its editing
            if !same { row.refresh() }
            return row
        }
        for row in before where !after.contains(where: { $0 === row }) {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for (index, row) in after.enumerated() {
            let placed = rows
            if index < placed.count, placed[index] === row { continue }
            if row.superview === stack {
                // Stays in the list as it moves, like a task being dragged, so one being edited keeps its cursor
                stack.removeArrangedSubview(row)
                stack.insertArrangedSubview(row, at: index)
            } else {
                arrange(row, at: index)
            }
        }
        renumber()
        // Undo would put back rows that are gone
        undo.removeAllActions(withTarget: self)
        if stoppedEditing { focus() }
    }

    /// Ends a task's editing, for one another device changed or deleted
    private func stopEditing(_ row: ToDoRow) {
        if row.field.currentEditor() != nil { window?.makeFirstResponder(nil) }
        // Ending the editing of an empty task asks for it to be deleted, but what happens to it is the other device's say
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(removeNow(_:)), object: row)
        editing = nil
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
        addOnFirstLine?.constant = TaskField.firstLineCenter(look.font)
        rows.forEach { $0.apply(look) }
        renumber()
    }

    /// Whether any tasks are checked, for Clear Checked
    var hasChecked: Bool { rows.contains { $0.item.done } }

    // MARK: Numbering

    /// Numbers the tasks from 1, top to bottom. The row for adding one has no number, but lines up with the tasks.
    private func renumber() {
        let tasks = rows
        let width = look.lineNumberWidth(lines: tasks.count)
        for (index, row) in tasks.enumerated() {
            row.number(index + 1, width: width, current: row === editing)
        }
        addIndent.constant = width + ToDoRow.gutterGap
        clearRow.edgeInsets.left = width + ToDoRow.gutterGap
        updateClearButton()
    }

    /// Shows Clear Checked while some tasks are checked, with how many
    private func updateClearButton() {
        let count = rows.filter(\.item.done).count
        clearRow.isHidden = count == 0
        let size = (look.font.pointSize * 0.85).rounded()
        clearButton.attributedTitle = NSAttributedString(string: "Clear Checked (\(count))", attributes: [
            .font: NSFont(descriptor: look.font.fontDescriptor, size: size) ?? look.font,
            .foregroundColor: look.doneColor,
        ])
    }

    /// Called when a task starts being edited
    func startedEditing(_ row: ToDoRow) {
        editing = row
        row.textBefore = row.item.text
        renumber()
    }

    // MARK: Adding and deleting

    /// Checkboxes and the + share a width, so the tasks line up with the one being added
    static func alignLeading(_ view: NSView) {
        view.widthAnchor.constraint(equalToConstant: 18).isActive = true
    }

    /// Puts a row in the list, as wide as the list
    private func arrange(_ row: NSView, at index: Int) {
        stack.insertArrangedSubview(row, at: index)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Self.inset).isActive = true
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
        renumber()
        sender.stringValue = ""
        onChange?()
        perform(#selector(focusLater), with: nil, afterDelay: 0)
        layoutSubtreeIfNeeded()
        addRow.scrollToVisible(addRow.bounds)
    }

    func changed() {
        updateClearButton()
        onChange?()
    }

    // MARK: Clearing checked tasks

    @objc private func clearClicked(_ sender: NSButton) {
        clearChecked()
    }

    /// Deletes all the checked tasks. Undo puts them back where they were.
    func clearChecked() {
        let checked = rows.filter(\.item.done)
        guard !checked.isEmpty else { return }
        // A checked task being edited finishes first, so its field editor isn't left behind
        if let editing, checked.contains(where: { $0 === editing }) {
            window?.makeFirstResponder(nil)
        }
        take(checked, as: "Clear Checked")
        focus()
    }

    /// Takes tasks out of the list, and lets Undo put them back
    private func take(_ taken: [ToDoRow], as action: String) {
        let places = taken.compactMap { row in stack.arrangedSubviews.firstIndex(of: row).map { (row: row, index: $0) } }
        for row in taken {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        renumber()
        onChange?()
        undo.registerUndo(withTarget: self) { list in
            MainActor.assumeIsolated { list.putBack(places, as: action) }
        }
        undo.setActionName(action)
    }

    /// Puts taken tasks back where they were, top to bottom, and lets Redo take them again
    private func putBack(_ places: [(row: ToDoRow, index: Int)], as action: String) {
        for place in places.sorted(by: { $0.index < $1.index }) {
            arrange(place.row, at: min(place.index, rows.count))
        }
        renumber()
        onChange?()
        undo.registerUndo(withTarget: self) { list in
            MainActor.assumeIsolated { list.take(places.map(\.row), as: action) }
        }
        undo.setActionName(action)
    }

    /// Deletes a task once the event that asked for it is done, since the task's own button or text is still handling it
    func remove(_ row: ToDoRow) {
        perform(#selector(removeNow(_:)), with: row, afterDelay: 0)
    }

    @objc private func removeNow(_ row: ToDoRow) {
        delete(row)
    }

    /// Deletes a task. Undo puts it back where it was. One emptied to delete it comes back as it was before it was
    /// emptied, and one that never had anything typed in it just goes.
    func delete(_ row: ToDoRow) {
        guard row.superview === stack else { return }
        // One being edited finishes first, so its field editor isn't left behind
        if editing === row { window?.makeFirstResponder(nil) }
        if row.item.isBlank, let before = row.textBefore { row.item.text = before }
        row.textBefore = nil
        guard !row.item.isBlank else {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
            renumber()
            onChange?()
            return
        }
        row.refresh()
        take([row], as: "Delete Task")
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
        if editing === row {
            editing = nil
            renumber()
        }
        let text = row.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            // Emptying a task deletes it
            remove(row)
        } else {
            row.item.text = text
            row.textBefore = nil
            row.refresh()
            onChange?()
        }
        // Return in an empty task goes on to adding one at the bottom, once this one has finished editing. In a task with
        // text, Return opens a new task next to it instead (see below).
        if (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue {
            perform(#selector(focusLater), with: nil, afterDelay: 0)
        }
    }

    /// Return in a task opens a new one below it, like starting a new line in a note: at the end of the task it's empty,
    /// and in the middle it takes the text after the cursor. At the start of the task the new one opens above it.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), let row = row(for: control),
              let index = stack.arrangedSubviews.firstIndex(of: row) else { return false }
        let task = ToDo(text: textView.string, done: row.item.done)
        // Return in an empty task deletes it and goes on to adding one, when its editing ends
        guard !task.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let new: ToDoRow
        if let split = task.split(at: textView.selectedRange()) {
            textView.string = split.kept.text
            row.item.text = split.kept.text
            new = makeRow(split.below)
            arrange(new, at: index + 1)
        } else {
            new = makeRow(ToDo(text: ""))
            arrange(new, at: index)
        }
        renumber()
        onChange?()
        // Once the field editor is done with this Return. A new task left empty is deleted when its editing ends.
        perform(#selector(editLater(_:)), with: new, afterDelay: 0)
        return true
    }

    /// Edits a task with the cursor at its start
    @objc private func editLater(_ row: ToDoRow) {
        guard row.superview === stack, let window, window.makeFirstResponder(row.field) else { return }
        row.field.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
        layoutSubtreeIfNeeded()
        row.scrollToVisible(row.bounds)
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
        tracking = true
        defer { tracking = false }
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
        renumber()
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

/// One task: its number, a checkbox, its text, and a × once it's checked. The text wraps, and the rest stays on its
/// first line.
@MainActor
final class ToDoRow: NSView {
    var item: ToDo
    weak var list: TodoList?
    let field = TaskField.make()
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// What it said when its editing began, which Undo brings back if it's emptied to delete it
    var textBefore: String?
    private let numberLabel = NSTextField(labelWithString: "")
    private lazy var numberWidth = numberLabel.widthAnchor.constraint(equalToConstant: 0)
    private let deleteButton = NSButton()
    /// The text runs to the ×, or to the row's edge when there isn't one
    private lazy var toDelete = field.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor,
                                                                constant: -Self.spacing)
    private lazy var toEdge = field.trailingAnchor.constraint(equalTo: trailingAnchor)
    /// Keeps the checkbox on the first line of the text
    private var onFirstLine: NSLayoutConstraint?
    private var look: Look

    /// The space between the numbers' column and the checkboxes
    static let gutterGap: CGFloat = 4
    /// The space between a checkbox, its task's text, and the ×
    static let spacing: CGFloat = 4

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

        field.onFocus = { [unowned self] in self.list?.startedEditing(self) }

        numberLabel.setAccessibilityElement(false)

        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete task")
        deleteButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        deleteButton.imagePosition = .imageOnly
        deleteButton.isBordered = false
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.toolTip = "Delete"
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)

        for view in [numberLabel, checkbox, field, deleteButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        onFirstLine = field.fit(self, beside: checkbox)
        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            numberWidth,
            // On the same line as the start of the task's text, like a text note's line numbers
            numberLabel.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
            checkbox.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor,
                                              constant: Look.lineNumberMargin + Self.gutterGap),
            field.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: Self.spacing),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            deleteButton.centerYAnchor.constraint(equalTo: checkbox.centerYAnchor),
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

    /// Shows the task's number, in a column `width` wide like a text note's line numbers. The one being edited is bolder.
    func number(_ number: Int, width: CGFloat, current: Bool) {
        numberWidth.constant = width - Look.lineNumberMargin
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        numberLabel.attributedStringValue = NSAttributedString(string: String(number), attributes: [
            .font: current ? look.currentLineNumberFont : look.lineNumberFont,
            .foregroundColor: current ? look.currentLineNumberColor : look.lineNumberColor,
            .paragraphStyle: style,
        ])
    }

    /// Shows the task as it is: crossed out with a × when it's done
    func refresh() {
        checkbox.state = item.done ? .on : .off
        checkbox.setAccessibilityLabel(item.text)
        deleteButton.isHidden = !item.done
        if item.done {
            toEdge.isActive = false
            toDelete.isActive = true
        } else {
            toDelete.isActive = false
            toEdge.isActive = true
        }
        onFirstLine?.constant = TaskField.firstLineCenter(look.font)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
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
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // The text takes clicks only while it's being edited. Otherwise they come here, so the task can be dragged.
        return hit === field ? self : hit
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

/// A task's text. It wraps onto as many lines as it needs, growing as you type, and tells its row when you start
/// editing it.
@MainActor
final class TaskField: NSTextField {
    var onFocus: (() -> Void)?
    /// The width its height was last worked out for
    private var fittedWidth: CGFloat = -1

    static func make() -> TaskField {
        let field = TaskField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentHuggingPriority(.init(1), for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    /// As tall as its lines need at the width it has, which its row gives it. Before it has a width, it's one line.
    override var intrinsicContentSize: NSSize {
        let line = Self.lineHeight(font)
        guard var cell, bounds.width > 0 else { return NSSize(width: NSView.noIntrinsicMetric, height: line) }
        // While it's being edited, what's typed so far is in the field editor and not in the cell yet. A copy of the
        // cell measures it, so the editing itself isn't touched.
        if let editor = currentEditor(), let typed = cell.copy() as? NSCell {
            typed.stringValue = editor.string
            cell = typed
        }
        let needs = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: 100_000))
        return NSSize(width: NSView.noIntrinsicMetric, height: max(ceil(needs.height), line))
    }

    override func layout() {
        super.layout()
        // The text wraps differently at another width, so it's another height
        if bounds.width != fittedWidth {
            fittedWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    /// Grows and shrinks a line at a time as you type
    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        invalidateIntrinsicContentSize()
    }

    /// Makes `row` as tall as this text's lines need, with a point clear above and below, and keeps `control`, at its
    /// left, on the first line however many there are. Gives back the constraint that keeps it there, which goes by
    /// the font (`firstLineCenter`).
    func fit(_ row: NSView, beside control: NSView) -> NSLayoutConstraint {
        let top = topAnchor.constraint(equalTo: row.topAnchor, constant: 1)
        let bottom = row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 1)
        // No taller than the text, unless the control is taller than a line of small text
        top.priority = .defaultLow
        bottom.priority = .defaultLow
        let onFirstLine = control.centerYAnchor.constraint(equalTo: firstBaselineAnchor)
        NSLayoutConstraint.activate([
            top, bottom, onFirstLine,
            topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 1),
            row.bottomAnchor.constraint(greaterThanOrEqualTo: bottomAnchor, constant: 1),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
            row.bottomAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor),
        ])
        return onFirstLine
    }

    /// Where the middle of a line's capital letters is from its baseline, which is where a checkbox looks level with
    /// the text. It's above the baseline, so it's negative.
    static func firstLineCenter(_ font: NSFont) -> CGFloat {
        let capitals = font.capHeight > 0 ? font.capHeight : font.ascender * 0.7
        return -(capitals / 2).rounded()
    }

    /// The height of one line of text
    static func lineHeight(_ font: NSFont?) -> CGFloat {
        let font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }
}

/// The list's scrolling content, laid out from the top
private final class ListDocument: NSView {
    override var isFlipped: Bool { true }
}
