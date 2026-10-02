import Foundation

public struct DiagnosticsStore {
    public let url: URL
    public static let maximumBytes = 1_048_576
    public init(url: URL) { self.url = url }

    public func append(_ message: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = Data((message + "\n").utf8).suffix(Self.maximumBytes)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + entry.count > Self.maximumBytes || !FileManager.default.fileExists(atPath: url.path) {
            try Data(entry).write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: entry)
    }
}
