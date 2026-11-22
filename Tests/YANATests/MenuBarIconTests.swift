import AppKit
import Testing
@testable import YANA

/// The menu bar icon is drawn in code, so nothing but these says whether anything is drawn at all.
@MainActor
struct MenuBarIconTests {
    /// The icon drawn as the menu bar draws it, at so many pixels to a point
    static func bitmap(scale: Int) -> NSBitmapImageRep {
        let image = MenuBarIcon.image()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * scale,
                                   pixelsHigh: Int(image.size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                   bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// How opaque the icon is at a point, counted from the top left
    private func opacity(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat, scale: Int) -> CGFloat {
        rep.colorAt(x: Int(x * CGFloat(scale)), y: Int(y * CGFloat(scale)))?.alphaComponent ?? -1
    }

    @Test func isATemplateTheSizeTheMenuBarWants() {
        let image = MenuBarIcon.image()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.accessibilityDescription == "YANA")
    }

    @Test func drawsTheNotesAndLeavesTheRestClear() {
        let scale = 4
        let rep = Self.bitmap(scale: scale)
        // The corners are clear, so the menu bar shows around the notes
        for (x, y) in [(0.2, 0.2), (17.8, 17.8), (0.2, 17.8)] {
            #expect(opacity(rep, x: x, y: y, scale: scale) == 0)
        }
        // The front note is glass: partly see-through, here below its tick
        let glass = opacity(rep, x: 7, y: 13.8, scale: scale)
        #expect(abs(glass - MenuBarIcon.glass) < 0.05)
        // The middle of the tick's long stroke is solid
        #expect(opacity(rep, x: 9.2, y: 10.6, scale: scale) > 0.9)
        // The back note's top edge is solid too, and inside it is clear, since it's only an outline
        var solid = 0
        for y in stride(from: 0.5, to: 4.5, by: 0.25) where opacity(rep, x: 11.5, y: y, scale: scale) > 0.9 { solid += 1 }
        #expect(solid > 0)
        #expect(opacity(rep, x: 13.6, y: 5.5, scale: scale) == 0)
    }
}
