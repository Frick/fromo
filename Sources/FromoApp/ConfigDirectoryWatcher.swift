import Foundation
import Darwin

final class ConfigDirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fromo.config-directory")
    private var source: DispatchSourceFileSystemObject?
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
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { report("Watch config directory: \(String(cString: strerror(errno)))"); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: queue)
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem(qos: .unspecified, flags: []) { [weak self] in self?.changed() }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            pending?.cancel()
            source?.cancel()
            source = nil
        }
    }
}
