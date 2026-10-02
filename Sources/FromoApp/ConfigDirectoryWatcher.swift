import Foundation
import CoreServices

// A directory stream observes both in-place file writes and editor temp-file renames.
final class ConfigDirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fromo.config-directory")
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var stopped = false
    private let path: String
    private let changed: @Sendable () -> Void
    private let report: @Sendable (String) -> Void

    init(path: String, changed: @escaping @Sendable () -> Void, report: @escaping @Sendable (String) -> Void) {
        self.path = path; self.changed = changed; self.report = report
        queue.async { [self] in start() }
    }

    private func start() {
        guard !stopped else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, { _, context, _, _, _, _ in
            guard let context else { return }
            Unmanaged<ConfigDirectoryWatcher>.fromOpaque(context).takeUnretainedValue().scheduleReload()
        }, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.0, flags) else {
            report("Could not create the config-directory event stream.")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            report("Could not start the config-directory event stream.")
            return
        }
        self.stream = stream
    }

    private func scheduleReload() {
        guard !stopped else { return }
        pending?.cancel()
        let work = DispatchWorkItem(qos: .unspecified, flags: []) { [weak self] in self?.changed() }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            pending?.cancel()
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }
}
