import AppKit

/// YANA's menu bar icon: two notes, one over the other, the front one glass with a tick on it, after the app icon.
/// It's drawn here rather than kept as a picture, so it's sharp at any scale. It's a template image: the menu bar
/// gives it its color, and only how opaque each part is comes from here.
enum MenuBarIcon {
    /// What the menu bar gives a status item's picture, in points
    static let size = NSSize(width: 18, height: 18)

    static func image() -> NSImage {
        // Flipped, so the numbers in `draw` go down from the top, as they do in the drawing they come from
        let image = NSImage(size: size, flipped: true) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "YANA"
        return image
    }

    private static func draw() {
        let ink = NSColor.black
        let front = turn(-7, about: NSPoint(x: 8.1, y: 10.5))

        // The note at the back, turned the other way. It stops a hair short of the front note, so the two read as
        // two at this size.
        NSGraphicsContext.saveGraphicsState()
        let clearOfTheFront = NSBezierPath(rect: NSRect(origin: .zero, size: size))
        clearOfTheFront.append(note(NSRect(x: 2.4, y: 4.8, width: 11.4, height: 11.4), radius: 2.9, front))
        clearOfTheFront.windingRule = .evenOdd
        clearOfTheFront.addClip()
        let back = note(NSRect(x: 6, y: 1.7, width: 9.6, height: 9.6), radius: 2.2,
                        turn(9, about: NSPoint(x: 10.8, y: 6.5)))
        back.lineWidth = 1.3
        ink.setStroke()
        back.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // The note in front: glass, so partly see-through, with a solid edge
        let pane = note(NSRect(x: 3.3, y: 5.7, width: 9.6, height: 9.6), radius: 2.2, front)
        ink.withAlphaComponent(glass).setFill()
        pane.fill()
        pane.lineWidth = 1.4
        ink.setStroke()
        pane.stroke()

        // And its tick
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: 5.9, y: 10.6))
        tick.line(to: NSPoint(x: 7.5, y: 12.2))
        tick.line(to: NSPoint(x: 10.5, y: 8.7))
        tick.transform(using: front)
        tick.lineWidth = 1.6
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        tick.stroke()
    }

    /// How opaque the front note's glass is
    static let glass: CGFloat = 0.26

    private static func note(_ rect: NSRect, radius: CGFloat, _ turned: AffineTransform) -> NSBezierPath {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.transform(using: turned)
        return path
    }

    /// A turn about a point, clockwise for a positive angle since the drawing is flipped
    private static func turn(_ degrees: CGFloat, about center: NSPoint) -> AffineTransform {
        var transform = AffineTransform(translationByX: center.x, byY: center.y)
        transform.rotate(byDegrees: degrees)
        transform.translate(x: -center.x, y: -center.y)
        return transform
    }
}
