import Foundation
import Testing
@testable import YANA

/// The line numbers' index of where lines start, checked against counting the lines from the top
struct LineIndexTests {
    /// Which line the character at `location` is on, counted from the top the slow way
    private func counted(at location: Int, in text: NSString) -> Int {
        var number = 1
        var index = 0
        while index < min(location, text.length) {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
            guard contentsEnd < end, end <= location else { break }
            number += 1
            index = end
        }
        return number
    }

    private func check(_ index: LineIndex, against text: NSString, _ comment: Comment) {
        #expect(index.length == text.length, comment)
        #expect(index.starts == LineIndex(text).starts, comment)
        for location in 0...text.length where index.lineNumber(at: location) != counted(at: location, in: text) {
            Issue.record("Line \(index.lineNumber(at: location)) at \(location), not \(counted(at: location, in: text)): \(comment)")
            return
        }
    }

    @Test func countsLines() {
        #expect(LineIndex().count == 1)
        #expect(LineIndex("").count == 1)
        #expect(LineIndex("Milk").count == 1)
        #expect(LineIndex("Milk\n").count == 2)
        #expect(LineIndex("Milk\nEggs").count == 2)
        #expect(LineIndex("Milk\r\nEggs\rJam\n\nBread").starts == [0, 6, 11, 15, 16])
        #expect(LineIndex("a\u{2028}b\u{2029}c\u{85}d").count == 4)
    }

    @Test func findsTheLineOfACharacter() {
        let text = "Milk\nEggs\n\nBread\n" as NSString
        let index = LineIndex(text)
        #expect(index.lineNumber(at: 0) == 1)
        #expect(index.lineNumber(at: 4) == 1)
        #expect(index.lineNumber(at: 5) == 2)
        #expect(index.lineNumber(at: 10) == 3)
        #expect(index.lineNumber(at: 11) == 4)
        // Past the final line break is the line after it
        #expect(index.lineNumber(at: text.length) == 5)
        #expect(index.count == 5)
        check(index, against: text, "as built")
    }

    @Test func keepsUpWithTyping() {
        let text = NSMutableString(string: "Milk\nEggs")
        var index = LineIndex(text)
        func type(_ typed: String, at location: Int, replacing length: Int = 0) {
            text.replaceCharacters(in: NSRange(location: location, length: length), with: typed)
            let count = (typed as NSString).length
            index.edit(NSRange(location: location, length: count), changeInLength: count - length, in: text)
            check(index, against: text, "after \(typed.debugDescription) at \(location)")
        }
        type("!", at: 4)
        type("\n", at: 5)
        type("Jam", at: 6)
        type("\n", at: text.length)
        type("", at: 5, replacing: 1)
        type("", at: 0, replacing: text.length)
        #expect(index.count == 1)
        type("One\nTwo\nThree\n", at: 0)
        #expect(index.count == 4)
        type("2\n2½", at: 4, replacing: 3)
        #expect(index.count == 5)
        // A character that's two UTF-16 units long
        type("😀\n", at: 0)
        #expect(index.starts.prefix(2) == [0, 3])
        type("\n", at: 2)
        #expect(index.starts.prefix(3) == [0, 3, 4])
    }

    @Test func aLineBreakTypedBesideAnotherMakesOne() {
        // \r then \n are one line break, whichever is typed second, and taking either away leaves the other
        let text = NSMutableString(string: "a\rb")
        var index = LineIndex(text)
        #expect(index.starts == [0, 2])
        text.insert("\n", at: 2)
        index.edit(NSRange(location: 2, length: 1), changeInLength: 1, in: text)
        #expect(index.starts == [0, 3])
        check(index, against: text, "\\n after \\r")

        text.setString("a\nb")
        index.rebuild(text)
        text.insert("\r", at: 1)
        index.edit(NSRange(location: 1, length: 1), changeInLength: 1, in: text)
        #expect(index.starts == [0, 3])
        check(index, against: text, "\\r before \\n")

        text.deleteCharacters(in: NSRange(location: 1, length: 1))
        index.edit(NSRange(location: 1, length: 0), changeInLength: -1, in: text)
        #expect(index.starts == [0, 2])
        check(index, against: text, "\\r taken away")

        text.setString("a\r\n\r\nb")
        index.rebuild(text)
        text.deleteCharacters(in: NSRange(location: 2, length: 1))
        index.edit(NSRange(location: 2, length: 0), changeInLength: -1, in: text)
        check(index, against: text, "\\n taken out of \\r\\n\\r\\n")
        #expect(index.starts == [0, 2, 4])
    }

    @Test func startsOverWhenTheEditDoesntFit() {
        let text = NSMutableString(string: "Milk\nEggs\nJam")
        var index = LineIndex("Something else entirely" as NSString)
        index.edit(NSRange(location: 0, length: 1), changeInLength: 1, in: text)
        check(index, against: text, "an edit to another text")
        index.edit(NSRange(location: 40, length: 3), changeInLength: 0, in: text)
        check(index, against: text, "an edit past the end")
    }

    @Test func matchesCountingFromTheTopThroughRandomEdits() {
        // The same edits every run
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func random(_ below: Int) -> Int {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed % UInt64(max(below, 1)))
        }
        // Nothing that's two UTF-16 units, since a random place could then fall inside a character
        let pieces = ["a", "bc", " ", "\n", "\r", "\r\n", "\n\n", "\u{2028}", "é", "\u{85}", "x\ny", "\r\r", ""]
        for round in 0..<300 {
            let text = NSMutableString(string: "")
            for _ in 0..<random(12) { text.append(pieces[random(pieces.count)]) }
            var index = LineIndex(text)
            for step in 0..<40 {
                let location = random(text.length + 1)
                let length = random(min(4, text.length - location) + 1)
                var typed = ""
                for _ in 0..<random(4) { typed += pieces[random(pieces.count)] }
                text.replaceCharacters(in: NSRange(location: location, length: length), with: typed)
                let count = (typed as NSString).length
                index.edit(NSRange(location: location, length: count), changeInLength: count - length, in: text)
                guard index.starts == LineIndex(text).starts, index.length == text.length else {
                    Issue.record("Round \(round), step \(step): \(typed.debugDescription) at \(location) replacing \(length) gave \(index.starts), not \(LineIndex(text).starts), in \((text as String).debugDescription)")
                    return
                }
            }
            check(index, against: text, "round \(round)")
        }
    }

    @Test func aWiderEditThanWasMadeIsFine() {
        // A text view may describe an edit as covering more than changed
        let text = NSMutableString(string: "One\nTwo\r\nThree\nFour")
        var index = LineIndex(text)
        text.insert("!", at: 7)
        index.edit(NSRange(location: 2, length: 12), changeInLength: 1, in: text)
        check(index, against: text, "a wider range")
        index.edit(NSRange(location: 0, length: text.length), changeInLength: 0, in: text)
        check(index, against: text, "the whole text, unchanged")
    }
}
