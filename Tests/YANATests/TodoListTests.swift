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

    @Test func aTaskThatNeverHadAnythingInItJustGoes() throws {
        let list = TodoList(items: [ToDo(text: "Milk"), ToDo(text: "")])
        _ = show(list)
        list.delete(try #require(row("", in: list)))
        #expect(rows(in: list).count == 1)
        #expect(!list.undo.canUndo)
    }
}
