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
}

extension Bundle {
    /// "1.0 (12)"
    var versionDescription: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
