import Foundation

/// Where each line of a note starts, kept up to date as the note is edited, so that finding which line a character is
/// on is a quick look-up and not a count from the top of the note. The line numbers ask on every keystroke, cursor
/// move and scroll. Lines are told apart the way NSString tells them (a line ends at \n, \r, \r\n and the rarer line
/// and paragraph separators), and places are counted the way it counts them, in UTF-16.
struct LineIndex {
    /// Where each line starts, in order. The first is 0. A text that ends with a line break has a last, empty line,
    /// which starts at its end.
    private(set) var starts: [Int] = [0]
    /// How long the text was when this was last brought up to date
    private(set) var length = 0

    init() {}

    init(_ text: NSString) {
        rebuild(text)
    }

    /// How many lines there are, counting the empty one after a final line break
    var count: Int { starts.count }

    /// Which line, counting from 1, the character at `location` is on. Past a final line break is the line after it.
    func lineNumber(at location: Int) -> Int {
        last(atOrBefore: location) + 1
    }

    /// Which of `starts` is the last one at or before `location`
    private func last(atOrBefore location: Int) -> Int {
        var low = 0
        var high = starts.count
        while high - low > 1 {
            let middle = (low + high) / 2
            if starts[middle] <= location {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }

    /// Works it all out again from the text
    mutating func rebuild(_ text: NSString) {
        starts = [0] + Self.starts(after: 0, in: text, through: nil)
        length = text.length
    }

    /// Brings it up to date after an edit, looking only at the lines the edit touched. `edited` is the part of the
    /// text, as it is now, that the edit put in or changed, and `delta` is how much longer the text got, which is how
    /// a text view's storage describes an edit. If they don't fit the text this was last brought up to date with, it
    /// works everything out again.
    mutating func edit(_ edited: NSRange, changeInLength delta: Int, in text: NSString) {
        let end = edited.location + edited.length
        guard edited.location >= 0, edited.length >= 0, edited.length - delta >= 0, length + delta == text.length,
              end <= text.length else { return rebuild(text) }

        // The last line start the edit can't have moved. It's at least a character before the edit, so that a \r
        // just before a \n the edit put in, which now end one line between them, is looked at again.
        let kept = last(atOrBefore: max(edited.location - 1, 0))
        // The line starts from there, up to the first that's past the edit by a character or more. That one was a
        // line start before the edit too, whatever the edit put before it, and so were the ones after it.
        let found = Self.starts(after: starts[kept], in: text, through: end + 1)
        var after: [Int] = []
        if let last = found.last, last >= end + 1 {
            let was = last - delta
            var index = kept + 1
            while index < starts.count, starts[index] <= was {
                index += 1
            }
            after = starts[index...].map { $0 + delta }
        }
        starts = Array(starts[...kept]) + found + after
        length = text.length
    }

    /// The line starts after `start`, which is one itself: all of them, or up to and including the first one at or
    /// past `limit`
    private static func starts(after start: Int, in text: NSString, through limit: Int?) -> [Int] {
        var found: [Int] = []
        var index = start
        let length = text.length
        while index < length {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
            // The last line, with no line break after it
            guard contentsEnd < end else { break }
            found.append(end)
            if let limit, end >= limit { break }
            index = end
        }
        return found
    }
}
