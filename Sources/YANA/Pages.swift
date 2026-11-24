import AppKit

/// What a tab shows: a text note, or a to-do list
@MainActor
protocol NotePage: AnyObject {
    var view: NSView { get }
    /// What's in it now, to save
    var note: Note { get }
    /// The tab's name, which is its note's title. Asked on every keystroke, so a page gives it the quickest way it can.
    var title: String { get }
    /// The note's id, which stays with the tab
    var id: UUID { get set }
    /// The name you gave it, if you did
    var name: String? { get set }
    /// How it syncs, if it's a synced to-do list
    var sync: SyncInfo? { get set }
    /// The text file it was opened from or last saved to
    var file: URL? { get set }
    /// Called after every change
    var onChange: (() -> Void)? { get set }
    /// Its own Undo, which stays with it while another tab is shown
    var undo: UndoManager { get set }
    /// Puts the cursor where you'd start typing
    func focus()
    func apply(_ look: Look)
}

extension NotePage {
    var title: String { note.title }
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
    var lineNumberColor: NSColor { sticky ? NSColor(white: 0, alpha: 0.35) : .tertiaryLabelColor }
    var currentLineNumberColor: NSColor { sticky ? .black : .labelColor }

    /// Line numbers are a little smaller than the text, with digits that all take the same width
    var lineNumberFont: NSFont { .monospacedDigitSystemFont(ofSize: (textSize * 0.85).rounded(), weight: .regular) }
    /// The number of the line you're on is bolder
    var currentLineNumberFont: NSFont {
        .monospacedDigitSystemFont(ofSize: (textSize * 0.85).rounded(), weight: .semibold)
    }

    /// How wide the line numbers' column is, with room for at least two digits and more as the note grows. Each number
    /// ends `lineNumberMargin` from its right side.
    func lineNumberWidth(lines: Int) -> CGFloat {
        let digits = max(2, String(lines).count)
        let width = ("8" as NSString).size(withAttributes: [.font: lineNumberFont]).width
        return (CGFloat(digits) * width + 14).rounded()
    }

    static let lineNumberMargin: CGFloat = 8

    /// A highlighted task's line: see-through over the usual background, in light or dark mode as the note is, and
    /// solid on a sticky note
    func color(of highlight: Highlight) -> NSColor {
        if sticky { return NSColor(highlight.sticky) }
        return NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? highlight.dark : highlight.light)
        }
    }
}

extension NSColor {
    convenience init(_ shade: Highlight.Shade) {
        self.init(srgbRed: shade.red, green: shade.green, blue: shade.blue, alpha: shade.alpha)
    }
}

extension Highlight {
    /// A dot of the color, as the highlighter's own ink, for a menu
    var swatch: NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            var ink = light
            ink.alpha = 1
            NSColor(ink).setFill()
            dot.fill()
            NSColor(white: 0, alpha: 0.2).setStroke()
            dot.lineWidth = 0.5
            dot.stroke()
            return true
        }
        image.accessibilityDescription = name
        return image
    }
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
    private let lineNumbers: LineNumberRuler
    private let defaultCaret: NSColor
    var id = UUID()
    var name: String?
    var sync: SyncInfo?
    var file: URL?
    var onChange: (() -> Void)?
    var undo = UndoManager()

    init(text: String) {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        view = scroll
        self.textView = textView
        defaultCaret = textView.insertionPointColor
        lineNumbers = LineNumberRuler(textView: textView, scrollView: scroll)
        super.init()

        scroll.verticalRulerView = lineNumbers
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

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

    var note: Note { Note(id: id, kind: .text, text: textView.string, name: name, file: file) }

    /// The same as its note's title (`Note.title`), found without copying the whole note out of the text view: the
    /// name you gave it, else its first line with something on it
    var title: String {
        if let name = Note.name(name) { return name }
        guard let text = textView.textStorage?.mutableString else { return note.title }
        var first: String?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, _, _, stop in
            let line = (line ?? "").trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                first = line
                stop.pointee = true
            }
        }
        return first.map { String($0.prefix(40)) } ?? "New Note"
    }

    func focus() {
        view.window?.makeFirstResponder(textView)
    }

    func apply(_ look: Look) {
        textView.font = look.font
        textView.textColor = look.textColor
        textView.backgroundColor = look.background
        (view as? NSScrollView)?.backgroundColor = look.background
        textView.insertionPointColor = look.sticky ? .black : defaultCaret
        lineNumbers.apply(look)
    }

    func textDidChange(_ notification: Notification) {
        onChange?()
    }

    /// Typing is undone by the tab's own Undo, not the window's
    func undoManager(for view: NSTextView) -> UndoManager? {
        undo
    }
}
