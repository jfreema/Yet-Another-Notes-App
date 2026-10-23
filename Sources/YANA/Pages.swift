import AppKit

/// What a tab shows: a text note, or a to-do list
@MainActor
protocol NotePage: AnyObject {
    var view: NSView { get }
    /// What's in it now, to save
    var note: Note { get }
    /// Called after every change
    var onChange: (() -> Void)? { get set }
    /// Puts the cursor where you'd start typing
    func focus()
    func apply(_ look: Look)
}

/// How the notes look: the text size, and whether sticky note mode is on
struct Look {
    var textSize: CGFloat
    var sticky: Bool

    /// Sticky notes are written in Chalkboard SE, which looks hand-lettered but neatly printed. It runs small, so it's
    /// a little bigger.
    var font: NSFont {
        guard sticky else { return .systemFont(ofSize: textSize) }
        let size = (textSize * 1.2).rounded()
        return NSFont(name: "ChalkboardSE-Regular", size: size) ?? NSFont(name: "Noteworthy-Bold", size: size)
            ?? .systemFont(ofSize: textSize)
    }

    var textColor: NSColor { sticky ? .black : .textColor }
    var doneColor: NSColor { sticky ? NSColor(white: 0, alpha: 0.45) : .secondaryLabelColor }
    var background: NSColor { sticky ? .stickyYellow : .textBackgroundColor }
}

extension NSColor {
    /// Post-it yellow, toned down a little so it doesn't glare, for sticky note mode
    static let stickyYellow = NSColor(srgbRed: 0.97, green: 0.93, blue: 0.64, alpha: 1)
}

/// A tab of plain text
@MainActor
final class TextPage: NSObject, NotePage, NSTextViewDelegate {
    let view: NSView
    private let textView: NSTextView
    private let defaultCaret: NSColor
    var onChange: (() -> Void)?

    init(text: String) {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        view = scroll
        self.textView = textView
        defaultCaret = textView.insertionPointColor
        super.init()

        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.string = text
        textView.delegate = self
    }

    var note: Note { Note(kind: .text, text: textView.string) }

    func focus() {
        view.window?.makeFirstResponder(textView)
    }

    func apply(_ look: Look) {
        textView.font = look.font
        textView.textColor = look.textColor
        textView.backgroundColor = look.background
        (view as? NSScrollView)?.backgroundColor = look.background
        textView.insertionPointColor = look.sticky ? .black : defaultCaret
    }

    func textDidChange(_ notification: Notification) {
        onChange?()
    }
}
