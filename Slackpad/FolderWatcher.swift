import Foundation

/// Watches a directory tree with FSEvents and fires `onChange` (debounced by
/// the stream latency) when anything under it is added, removed, renamed or
/// modified. Used to reflect external changes made in Finder or other editors.
///
/// `@unchecked Sendable`: `onChange` is only ever set and invoked on the main
/// thread, and the FSEvents stream is dispatched to the main queue.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    var onChange: (@MainActor () -> Void)?

    func start(url: URL) {
        stop()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // The stream is dispatched to the main queue below, so the callback
        // already runs on the main thread.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange?() }
        }
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
