import AppKit
import CryptoKit
import Security

/// Updates from the zipped app in the repo's downloads folder, replacing this copy in place
@MainActor
final class Updater {
    private(set) var isBusy = false

    static let homepage = URL(string: "https://github.com/jfreema/Yet-Another-Notes-App")!

    /// What build.sh --release publishes next to the zipped app
    struct Release: Decodable, Equatable, Sendable {
        let version: String
        let url: URL
        let sha256: String
        /// The Apple Developer team that signed it, if any
        let team: String?
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static var feed: URL {
        // Overridable for testing
        if let custom = UserDefaults.standard.string(forKey: "updateFeed"), let url = URL(string: custom) { return url }
        return URL(string: "https://raw.githubusercontent.com/jfreema/Yet-Another-Notes-App/main/downloads/latest.json")!
    }

    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        version.compare(current, options: .numeric) == .orderedDescending
    }

    func checkForUpdates() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await check()
            isBusy = false
        }
    }

    private func check() async {
        let current = Bundle.main.shortVersion
        let release: Release
        do {
            release = try await Self.latestRelease(from: Self.feed)
        } catch {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            Alert.show("Couldn't check for updates", error.localizedDescription)
            return
        }
        guard Self.isNewer(release.version, than: current) else {
            Alert.show("YANA is up to date", "Version \(current) is the newest.")
            return
        }
        guard Alert.confirm("YANA \(release.version) is available",
                            "You have \(current). YANA restarts on the new version when it's done, and your note stays "
                            + "as it is.", button: "Update") else { return }
        let app = Bundle.main.bundleURL
        do {
            // Translocated copies run from a read-only folder
            guard !app.path.contains("/AppTranslocation/") else {
                throw Failure("Move YANA to your Applications folder, open it from there, then try again.")
            }
            guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
                throw Failure("YANA can't replace itself in \(app.deletingLastPathComponent().path). "
                              + "Download the new version from GitHub instead.")
            }
            try await Self.replace(app, with: release, bundleID: Bundle.main.bundleIdentifier,
                                   team: Self.team(of: app))
        } catch {
            logger.error("Update failed: \(error.localizedDescription, privacy: .public)")
            Alert.show("Couldn't update YANA", error.localizedDescription)
            return
        }
        logger.notice("Updated to \(release.version, privacy: .public), restarting")
        Self.relaunch()
    }

    nonisolated static func decode(_ data: Data) throws -> Release {
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw Failure("The update information didn't make sense.")
        }
        return release
    }

    nonisolated private static func latestRelease(from feed: URL) async throws -> Release {
        let request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response)
        return try decode(data)
    }

    /// Download, verify, swap in place
    nonisolated static func replace(_ app: URL, with release: Release, bundleID: String?, team: String?) async throws {
        let files = FileManager.default
        // Same volume as the app, so the swap is atomic
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? files.removeItem(at: work) }

        let request = URLRequest(url: release.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let (download, response) = try await URLSession.shared.download(for: request)
        let zip = work.appendingPathComponent("YANA.zip")
        try files.moveItem(at: download, to: zip)
        try checkStatus(response)
        let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        // Caches can serve the new version file before the new zip
        guard digest == release.sha256.lowercased() else {
            throw Failure("The download didn't match the published version. Try again in a few minutes.")
        }

        let expanded = work.appendingPathComponent("expanded")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, expanded.path]) == 0 else {
            throw Failure("Couldn't unzip the download.")
        }
        let unpacked = expanded.appendingPathComponent(app.lastPathComponent)
        let fallback = expanded.appendingPathComponent("YANA.app")
        let found = files.fileExists(atPath: unpacked.path) ? unpacked : fallback
        let staged = work.appendingPathComponent(app.lastPathComponent)
        try files.moveItem(at: found, to: staged)

        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID,
              info?["CFBundleShortVersionString"] as? String == release.version,
              run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]) == 0 else {
            throw Failure("The downloaded app didn't check out.")
        }
        // Once signed by a Developer ID, only take updates signed by the same team
        if let team, Self.team(of: staged) != team {
            throw Failure("The download isn't signed by the same developer as this copy of YANA.")
        }
        _ = try files.replaceItemAt(app, withItemAt: staged)
    }

    /// The signing team, or nil for an ad hoc signature
    nonisolated static func team(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    nonisolated private static func checkStatus(_ response: URLResponse) throws {
        // file: URLs have no status
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure("GitHub answered with error \(http.statusCode).")
        }
    }

    /// Reopens once this process exits
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                             Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
