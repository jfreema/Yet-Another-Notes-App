import CoreServices
import Foundation

/// Says when something changes in any of some folders, or in a folder inside one, so the sync folders are read when
/// there's something new in them and not every few seconds. It uses the file system's own events (FSEvents), which
/// also tell of the changes iCloud Drive makes when it brings a file in from another device. Changes are gathered for
/// `latency` seconds, so a burst of them is told of once.
@MainActor
final class FolderWatcher {
    /// The folders being watched, by path
    private(set) var paths: [String] = []
    /// Only touched on the main thread, and by `deinit`, when nothing else can
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private let latency: TimeInterval
    private let changed: @MainActor () -> Void

    init(latency: TimeInterval = 1, changed: @escaping @MainActor () -> Void) {
        self.latency = latency
        self.changed = changed
    }

    deinit {
        if let stream { endWatching(stream) }
    }

    /// Watches these folders from now on, in place of the ones it watched. One that isn't there yet is watched from
    /// when it appears.
    func watch(_ paths: [String]) {
        guard paths != self.paths else { return }
        stop()
        guard !paths.isEmpty else { return }
        let link = WatcherLink()
        link.watcher = self
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(link).toOpaque(),
                                           retain: retainLink, release: releaseLink, copyDescription: nil)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, foldersChanged, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else {
            logger.error("Couldn't watch the sync folders")
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            logger.error("Couldn't start watching the sync folders")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
        self.paths = paths
    }

    func stop() {
        if let stream { endWatching(stream) }
        stream = nil
        paths = []
    }

    fileprivate func tell() {
        changed()
    }
}

/// What an event stream holds on to. The stream keeps it alive for as long as it may still call back, so a change
/// told of after its watcher has gone finds no watcher, not freed memory.
private final class WatcherLink {
    weak var watcher: FolderWatcher?
}

private func retainLink(_ info: UnsafeRawPointer?) -> UnsafeRawPointer? {
    guard let info else { return nil }
    _ = Unmanaged<WatcherLink>.fromOpaque(info).retain()
    return info
}

private func releaseLink(_ info: UnsafeRawPointer?) {
    guard let info else { return }
    Unmanaged<WatcherLink>.fromOpaque(info).release()
}

/// Called by the event stream on the main queue, which `watch` gives it
private func foldersChanged(_ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
                            _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
                            _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    let link = Unmanaged<WatcherLink>.fromOpaque(info).takeUnretainedValue()
    MainActor.assumeIsolated {
        link.watcher?.tell()
    }
}

private func endWatching(_ stream: FSEventStreamRef) {
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
}
