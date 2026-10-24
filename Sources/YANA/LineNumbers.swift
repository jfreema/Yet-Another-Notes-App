import AppKit

/// The line numbers down a text tab's left side, dim except for the line the cursor is on. A line that wraps keeps
/// one number, on its first row.
@MainActor
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var look = Look(textSize: 14, sticky: false)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        // Since macOS 14 views don't clip by default, and the text view's background would cover the numbers
        clipsToBounds = true
        scrollView.contentView.clipsToBounds = true

        let center = NotificationCenter.default
        for name in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification,
                     NSView.frameDidChangeNotification] {
            center.addObserver(self, selector: #selector(refresh), name: name, object: textView)
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                           object: scrollView.contentView)
        updateThickness()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ look: Look) {
        self.look = look
        updateThickness()
        needsDisplay = true
    }

    @objc private func refresh() {
        updateThickness()
        needsDisplay = true
    }

    @objc private func scrolled() {
        needsDisplay = true
    }

    /// Room for at least two digits, and more as the note grows
    private func updateThickness() {
        let lines = Self.lineNumber(at: (textView?.string as NSString?)?.length ?? 0, in: textView?.string ?? "")
        let digits = max(2, String(lines).count)
        let width = ("8" as NSString).size(withAttributes: [.font: numberFont]).width
        let thickness = (CGFloat(digits) * width + 14).rounded()
        if ruleThickness != thickness { ruleThickness = thickness }
    }

    private var numberFont: NSFont {
        .monospacedDigitSystemFont(ofSize: (look.textSize * 0.85).rounded(), weight: .regular)
    }

    private var currentFont: NSFont {
        .monospacedDigitSystemFont(ofSize: (look.textSize * 0.85).rounded(), weight: .semibold)
    }

    override func draw(_ dirtyRect: NSRect) {
        look.background.setFill()
        dirtyRect.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let string = textView.string as NSString
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let current = Self.lineNumber(at: textView.selectedRange().location, in: textView.string)
        // Where the text view's top is, in the ruler
        let top = convert(NSPoint(x: 0, y: textView.textContainerOrigin.y), from: textView).y

        var index = string.lineRange(for: NSRange(location: characters.location, length: 0)).location
        var number = Self.lineNumber(at: index, in: textView.string)
        while index < string.length, index <= NSMaxRange(characters) {
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = layoutManager.location(forGlyphAt: glyph).y
            drawNumber(number, current: number == current, baseline: top + fragment.minY + baseline)
            number += 1
            index = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0)))
        }
        // The empty line after a final Return, or in an empty note
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty {
            let baseline = layoutManager.defaultBaselineOffset(for: textView.font ?? numberFont)
            drawNumber(number, current: number == current, baseline: top + extra.minY + baseline)
        }
    }

    private func drawNumber(_ number: Int, current: Bool, baseline: CGFloat) {
        let font = current ? currentFont : numberFont
        let color = current ? look.currentLineNumberColor : look.lineNumberColor
        let label = String(number) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = label.size(withAttributes: attributes).width
        // Flipped, so a string's top goes at the point
        label.draw(at: NSPoint(x: ruleThickness - width - 8, y: baseline - font.ascender), withAttributes: attributes)
    }

    /// Which line, counting from 1, the character at `location` is on. Past a final line break is the line after it.
    nonisolated static func lineNumber(at location: Int, in text: String) -> Int {
        let string = text as NSString
        var number = 1
        var index = 0
        while index < min(location, string.length) {
            var end = 0
            var contentsEnd = 0
            string.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
            // The last line, with no line break after it
            guard contentsEnd < end, end <= location else { break }
            number += 1
            index = end
        }
        return number
    }
}
