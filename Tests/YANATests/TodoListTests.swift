import AppKit
import Testing
@testable import YANA

/// A real list in a window that's never shown: how long tasks wrap, and how deleted ones come back
@MainActor
struct TodoListTests {
    private let long = "Call the dentist about moving the cleaning to the week after next, and ask about the bill"

    /// A list in a narrow window, laid out
    private func show(_ list: TodoList, width: CGFloat = 260) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = list
        list.apply(Look(textSize: 14, sticky: false))
        settle(list)
        return window
    }

    /// Lays the list out until it stays put: a task's height follows from the width a first pass gives it
    private func settle(_ list: TodoList) {
        for _ in 0..<4 {
            list.needsLayout = true
            list.layoutSubtreeIfNeeded()
        }
    }

    private func rows(in view: NSView) -> [ToDoRow] {
        view.subviews.flatMap { ($0 as? ToDoRow).map { [$0] } ?? rows(in: $0) }
    }

    private func row(_ text: String, in list: TodoList) -> ToDoRow? {
        rows(in: list).first { $0.item.text == text }
    }

    /// How far below the top of its row a view's middle is
    private func fromTop(_ view: NSView, in row: ToDoRow) -> CGFloat {
        row.isFlipped ? view.frame.midY : row.bounds.height - view.frame.midY
    }

    @Test func aLongTaskWrapsWithItsCheckboxOnTheFirstLine() throws {
        let list = TodoList(items: [ToDo(text: "Milk"), ToDo(text: long), ToDo(text: "Eggs", done: true)])
        _ = show(list)
        let short = try #require(row("Milk", in: list))
        let tall = try #require(row(long, in: list))
        let line = TaskField.lineHeight(short.field.font)

        // One line for the short task, and at least three for the long one in a note this narrow
        #expect(short.field.frame.height < line * 1.5)
        #expect(tall.field.frame.height >= line * 3)
        #expect(tall.frame.height >= short.frame.height + line * 2)
        // The text has all the height it asks for at its width, so none of it is cut off
        #expect(tall.field.frame.height >= tall.field.intrinsicContentSize.height)
        #expect(tall.field.frame.width > 100)

        // The checkbox is as far from the top of a tall task as of a short one: on the first line, not in the middle
        #expect(abs(fromTop(tall.checkbox, in: tall) - fromTop(short.checkbox, in: short)) < 1)
        #expect(fromTop(tall.checkbox, in: tall) < line)

        // The tasks follow one another without overlapping
        let frames = rows(in: list).map { $0.convert($0.bounds, to: list) }.sorted { $0.minY < $1.minY }
        #expect(frames.count == 3)
        for (one, next) in zip(frames, frames.dropFirst()) {
            #expect(one.maxY <= next.minY + 0.5)
        }
    }

    @Test func aTaskWrapsAgainWhenTheNoteIsMadeWider() throws {
        let list = TodoList(items: [ToDo(text: long)])
        let window = show(list)
        let tall = try #require(row(long, in: list))
        let narrow = tall.frame.height
        window.setContentSize(NSSize(width: 900, height: 400))
        settle(list)
        #expect(tall.frame.height < narrow)
        #expect(tall.field.frame.height < TaskField.lineHeight(tall.field.font) * 1.5)
    }

    @Test func aTaskGrowsAsItsTypedPastTheEndOfTheLine() throws {
        let list = TodoList(items: [ToDo(text: "Milk")])
        let window = show(list)
        let milk = try #require(row("Milk", in: list))
        let before = milk.frame.height
        #expect(window.makeFirstResponder(milk.field))
        let editor = try #require(milk.field.currentEditor() as? NSTextView)
        editor.insertText(" and a great many other things that won't fit on one line of a narrow note",
                          replacementRange: NSRange(location: 4, length: 0))
        settle(list)
        #expect(milk.frame.height >= before + TaskField.lineHeight(milk.field.font))
        #expect(milk.field.currentEditor() != nil)
        #expect(list.note.items.map(\.text)
            == ["Milk and a great many other things that won't fit on one line of a narrow note"])
    }

    @Test func undoPutsADeletedTaskBackWhereItWas() throws {
        let list = TodoList(items: [ToDo(text: "Milk"), ToDo(text: "Eggs", done: true), ToDo(text: "Bread")])
        _ = show(list)
        var changes = 0
        list.onChange = { changes += 1 }
        list.delete(try #require(row("Eggs", in: list)))
        #expect(list.note.items.map(\.text) == ["Milk", "Bread"])
        #expect(changes == 1)

        list.undo.undo()
        #expect(list.note.items.map(\.shown) == ["[ ] Milk", "[x] Eggs", "[ ] Bread"])
        list.undo.redo()
        #expect(list.note.items.map(\.text) == ["Milk", "Bread"])
        list.undo.undo()
        #expect(list.note.items.map(\.text) == ["Milk", "Eggs", "Bread"])
        #expect(changes == 4)
    }

    @Test func undoBringsBackATaskEmptiedToDeleteItAsItWas() throws {
        let list = TodoList(items: [ToDo(text: "Milk"), ToDo(text: "Eggs")])
        let window = show(list)
        let eggs = try #require(row("Eggs", in: list))
        #expect(window.makeFirstResponder(eggs.field))
        let editor = try #require(eggs.field.currentEditor() as? NSTextView)
        editor.insertText("", replacementRange: NSRange(location: 0, length: 4))
        #expect(list.note.items.map(\.text) == ["Milk"])

        // Clicking away ends its editing, and the empty task is deleted a turn later
        #expect(window.makeFirstResponder(nil))
        list.delete(eggs)
        #expect(rows(in: list).count == 1)

        list.undo.undo()
        #expect(list.note.items.map(\.text) == ["Milk", "Eggs"])
        #expect(row("Eggs", in: list)?.field.stringValue == "Eggs")
    }

    // MARK: Highlights

    /// Picks a menu item as a click would. In the app each click is its own event, so its own step to undo. A test
    /// never turns the run loop, which is what ends an event's undo group, so the test makes the groups itself (with
    /// `groupsByEvent` off, or they'd sit inside the event's one group).
    private func choose(_ title: String, for row: ToDoRow, in list: TodoList) throws {
        let menu = list.menu(for: row)
        let index = try #require(menu.items.firstIndex { $0.title == title })
        list.undo.beginUndoGrouping()
        menu.performActionForItem(at: index)
        list.undo.endUndoGrouping()
    }

    @Test func aRightClickHighlightsATask() throws {
        let list = TodoList(items: [ToDo(text: "Milk"), ToDo(text: "Eggs")])
        _ = show(list)
        let milk = try #require(row("Milk", in: list))
        var changes = 0
        list.onChange = { changes += 1 }
        list.undo.groupsByEvent = false

        let menu = list.menu(for: milk)
        #expect(menu.items.map(\.title) == ["Highlight", "Yellow", "Green", "Blue", "Purple", "Pink", "Orange",
                                            "Remove Highlight"])
        #expect(menu.items.allSatisfy { $0.state == .off })
        #expect(menu.items.last?.action == nil)

        try choose("Green", for: milk, in: list)
        #expect(list.note.items.map(\.highlight) == [.green, nil])
        #expect(changes == 1)
        // The menu ticks the task's color, and can take it off
        let again = list.menu(for: milk)
        #expect(again.items.filter { $0.state == .on }.map(\.title) == ["Green"])
        #expect(again.items.last?.action != nil)
        // The same color again is no change, and nothing to undo
        again.performActionForItem(at: try #require(again.items.firstIndex { $0.title == "Green" }))
        #expect(changes == 1)

        try choose("Pink", for: milk, in: list)
        #expect(list.note.items.map(\.highlight) == [.pink, nil])
        list.undo.undo()
        #expect(list.note.items.map(\.highlight) == [.green, nil])
        list.undo.undo()
        #expect(list.note.items.map(\.highlight) == [nil, nil])
        list.undo.redo()
        #expect(list.note.items.map(\.highlight) == [.green, nil])

        try choose("Remove Highlight", for: milk, in: list)
        #expect(list.note.items.map(\.highlight) == [nil, nil])
        #expect(list.undo.undoActionName == "Remove Highlight")
    }

    @Test func aTaskBeingEditedShowsTheColorsAboveCutCopyAndPaste() throws {
        let list = TodoList(items: [ToDo(text: "Milk", highlight: .blue)])
        let window = show(list)
        let milk = try #require(row("Milk", in: list))
        #expect(window.makeFirstResponder(milk.field))
        let editor = try #require(milk.field.currentEditor() as? NSTextView)
        let editing = NSMenu()
        editing.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(milk.field.textView(editor, menu: editing, for: event, at: 0))
        #expect(menu.items.map(\.title) == ["Highlight", "Yellow", "Green", "Blue", "Purple", "Pink", "Orange",
                                            "Remove Highlight", "", "Cut"])
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["Blue"])
    }

    @Test func aHighlightFromAnotherDeviceLeavesTheTaskBeingEditedAlone() throws {
        let milk = ToDo(text: "Milk"), eggs = ToDo(text: "Eggs")
        let list = TodoList(items: [milk, eggs])
        let window = show(list)
        let edited = try #require(row("Milk", in: list))
        #expect(window.makeFirstResponder(edited.field))
        let editor = try #require(edited.field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))

        var yellow = milk
        yellow.highlight = .yellow
        yellow.highlightChanged = Date()
        list.show([yellow, eggs])
        // Still being edited, with the cursor where it was, and now yellow
        #expect(edited.field.currentEditor() === editor)
        #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
        #expect(list.note.items.map(\.highlight) == [.yellow, nil])
    }

    @Test func aHighlightDrawsItsLine() throws {
        let list = TodoList(items: [ToDo(text: "Milk", highlight: .orange), ToDo(text: "Eggs")])
        _ = show(list)
        let milk = try #require(row("Milk", in: list))
        // The whole line, number and all
        #expect(milk.highlightFrame.minX < milk.checkbox.frame.minX)
        #expect(milk.highlightFrame.maxX == milk.bounds.maxX)
        #expect(milk.highlightFrame.height > milk.field.frame.height - 2)

        // Each color is see-through in light and dark mode, and solid on a sticky note
        let plain = Look(textSize: 14, sticky: false), sticky = Look(textSize: 14, sticky: true)
        for color in Highlight.allCases {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                var alpha: CGFloat = 0
                NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                    alpha = plain.color(of: color).usingColorSpace(.sRGB)?.alphaComponent ?? 0
                }
                #expect(alpha > 0.2 && alpha < 0.6)
            }
            #expect(sticky.color(of: color).usingColorSpace(.sRGB)?.alphaComponent == 1)
        }
    }

    @Test func aTaskThatNeverHadAnythingInItJustGoes() throws {
        let list = TodoList(items: [ToDo(text: "Milk"), ToDo(text: "")])
        _ = show(list)
        list.delete(try #require(row("", in: list)))
        #expect(rows(in: list).count == 1)
        #expect(!list.undo.canUndo)
    }
}
