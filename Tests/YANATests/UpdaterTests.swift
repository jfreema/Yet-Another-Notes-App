import Foundation
import Testing
@testable import YANA

struct UpdaterTests {
    @Test func comparesVersionsAsNumbers() {
        #expect(Updater.isNewer("1.0.10", than: "1.0.9"))
        #expect(Updater.isNewer("1.1.0", than: "1.0.3"))
        #expect(!Updater.isNewer("1.0.0", than: "1.0.0"))
        #expect(!Updater.isNewer("0.9.9", than: "1.0.0"))
    }

    @Test func readsTheFeed() throws {
        let json = """
        {"version": "1.2.0", "url": "https://example.com/YANA.zip", "sha256": "abc", "team": "ABCDE12345"}
        """
        let release = try Updater.decode(Data(json.utf8))
        #expect(release.version == "1.2.0")
        #expect(release.team == "ABCDE12345")
    }

    @Test func readsAnUnsignedFeed() throws {
        let json = #"{"version": "1.0.0", "url": "https://example.com/YANA.zip", "sha256": "abc"}"#
        #expect(try Updater.decode(Data(json.utf8)).team == nil)
    }

    @Test func rejectsNonsense() {
        #expect(throws: Updater.Failure.self) { try Updater.decode(Data("nope".utf8)) }
    }
}

struct NoteStoreTests {
    @Test func savesAndLoads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(file: folder.appendingPathComponent("Note.txt"))
        #expect(store.load() == "")
        store.save("Buy milk\nCall Sam")
        #expect(store.load() == "Buy milk\nCall Sam")
    }
}
