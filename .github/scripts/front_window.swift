// Temporary, for the hot key check: prints the apps that own the windows on screen, front to back
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
let owners = windows.compactMap { window -> String? in
    guard (window[kCGWindowLayer as String] as? Int) == 0,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
          width > 100, height > 100 else { return nil }
    return window[kCGWindowOwnerName as String] as? String
}
print(owners.isEmpty ? "none" : owners.joined(separator: ","))
