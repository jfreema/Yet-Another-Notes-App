import AppKit
import Carbon.HIToolbox
import Testing
@testable import YANA

/// The shortcut that shows the note from any app. Each test takes keys of its own, not Control-Option-N, so two tests
/// running at once don't want the same ones, and so the keys stay with a YANA that's open on this Mac.
@MainActor
struct HotKeyTests {
    private let suite = "YANA.HotKeyTests.\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    private static let everyModifier = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    private func makeHotKey(_ key: Int) -> HotKey {
        HotKey(defaults: defaults, keyCode: UInt32(key), modifiers: Self.everyModifier)
    }

    @Test func isControlOptionN() {
        #expect(HotKey.title == "⌃⌥N")
        // The N key, and Carbon's Control (0x1000) with Option (0x0800)
        #expect(HotKey.keyCode == 45)
        #expect(HotKey.modifiers == 0x1800)
    }

    @Test func isOnUntilItsTurnedOff() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let hotKey = makeHotKey(kVK_F16)
        defer { hotKey.stop() }
        #expect(hotKey.isOn)
        #expect(!hotKey.isRegistered)
        hotKey.start()
        #expect(hotKey.isRegistered)

        hotKey.isOn = false
        #expect(!hotKey.isRegistered)

        // Off stays off the next time YANA opens
        let next = makeHotKey(kVK_F16)
        defer { next.stop() }
        next.start()
        #expect(!next.isOn)
        #expect(!next.isRegistered)
        next.isOn = true
        #expect(next.isRegistered)
    }

    /// Asking twice for the same keys gets the answer macOS gives when it has them itself
    @Test func saysWhenTheKeysAreTaken() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = makeHotKey(kVK_F17)
        let second = makeHotKey(kVK_F17)
        defer {
            first.stop()
            second.stop()
        }
        first.start()
        second.start()
        #expect(first.isRegistered)
        #expect(!second.isRegistered)
        // Still wanted, so it's asked for again
        #expect(second.isOn)

        first.stop()
        second.isOn = true
        #expect(second.isRegistered)
    }

    @Test func runsItsActionForItsOwnKeysOnly() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let hotKey = makeHotKey(kVK_F18)
        let other = makeHotKey(kVK_F19)
        var presses = 0
        hotKey.action = { presses += 1 }

        #expect(!hotKey.pressed(other.id))
        #expect(presses == 0)
        #expect(hotKey.pressed(hotKey.id))
        #expect(presses == 1)
    }

    /// Presses Control-Option-N the way a person would, to see macOS hand it over. Only when asked for, with
    /// YANA_PRESS_KEYS=1, since it types on the Mac that runs it, and that Mac has to let System Events type.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YANA_PRESS_KEYS"] == "1"))
    func hearsTheRealKeys() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let hotKey = HotKey(defaults: defaults)
        defer { hotKey.stop() }
        var presses = 0
        hotKey.action = { presses += 1 }
        hotKey.start()
        try #require(hotKey.isRegistered)

        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        script.arguments = ["-e", "tell application \"System Events\" to key code 45 using {control down, option down}"]
        try script.run()
        script.waitUntilExit()
        try #require(script.terminationStatus == 0)

        // The press comes in through the app's events
        let app = NSApplication.shared
        let deadline = Date().addingTimeInterval(5)
        while presses == 0 && Date() < deadline {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default,
                                         dequeue: true) {
                app.sendEvent(event)
            }
        }
        #expect(presses == 1)
    }
}
