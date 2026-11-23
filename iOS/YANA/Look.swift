import SwiftUI

/// How a list looks: as usual, or as a sticky note, post-it yellow in Chalkboard SE like sticky note mode on the Mac
struct Look {
    var sticky: Bool

    /// Chalkboard SE runs small, so it's a little bigger
    var font: Font {
        sticky ? .custom("ChalkboardSE-Regular", size: 20, relativeTo: .body) : .body
    }

    var numberFont: Font { .footnote.monospacedDigit() }
    var textColor: Color { sticky ? .black : .primary }
    var doneColor: Color { sticky ? .black.opacity(0.45) : .secondary }
    var numberColor: Color { sticky ? .black.opacity(0.35) : Color(uiColor: .tertiaryLabel) }
    var checkColor: Color { sticky ? .black.opacity(0.6) : .accentColor }
    /// Nil for the usual background
    var background: Color? { sticky ? Color(red: 0.97, green: 0.93, blue: 0.64) : nil }

    /// How wide the numbers' column is, so the circles line up
    static let numberWidth: CGFloat = 24

    /// A highlighted task's line: see-through over the usual background, in light or dark mode as the list is, and
    /// solid on a sticky note. The same colors as on the Mac.
    func color(of highlight: Highlight) -> Color {
        if sticky { return Color(highlight.sticky) }
        return Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? highlight.dark : highlight.light)
        })
    }

    /// A task's row: its highlight, or the list's background. Nil for the usual background.
    func rowBackground(_ highlight: Highlight?) -> Color? {
        highlight.map(color(of:)) ?? background
    }

    /// The highlighter's own ink, solid, for the dots that pick a color
    static func ink(_ highlight: Highlight) -> Color {
        var ink = highlight.light
        ink.alpha = 1
        return Color(ink)
    }
}

extension UIColor {
    convenience init(_ shade: Highlight.Shade) {
        self.init(red: shade.red, green: shade.green, blue: shade.blue, alpha: shade.alpha)
    }
}

extension Color {
    init(_ shade: Highlight.Shade) {
        self.init(.sRGB, red: shade.red, green: shade.green, blue: shade.blue, opacity: shade.alpha)
    }
}

extension Bundle {
    /// "1.0 (12)"
    var versionDescription: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
