import Foundation

public struct Paths: Sendable {
    public let configDirectory: URL
    public let stateDirectory: URL

    public init(environment: [String: String], home: String) {
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        let state = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/state"
        configDirectory = URL(fileURLWithPath: config, isDirectory: true).appendingPathComponent("fromo", isDirectory: true)
        stateDirectory = URL(fileURLWithPath: state, isDirectory: true).appendingPathComponent("fromo", isDirectory: true)
    }

    public var configFile: URL { configDirectory.appendingPathComponent("config.toml") }
    public var stateFile: URL { stateDirectory.appendingPathComponent("state.json") }
    public var logDirectory: URL { stateDirectory.appendingPathComponent("log", isDirectory: true) }
    public var diagnosticFile: URL { stateDirectory.appendingPathComponent("fromo.log") }
    public var socketFile: URL { stateDirectory.appendingPathComponent("fromo.sock") }

    public func checkedSocketPath() throws -> String {
        let path = socketFile.path
        guard path.utf8.count < 104 else { throw ConfigError("Socket path exceeds 103 UTF-8 bytes: \(path)") }
        return path
    }
}

public struct StateStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func write(_ state: State) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(state)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    public func read() throws -> State {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(State.self, from: Data(contentsOf: url))
    }

    public func load(now: Int, config: Config, calendar: Calendar) throws -> (state: State, recovered: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (State(now: now, config: config, calendar: calendar), false)
        }
        do {
            let state = try read()
            try state.validateForEngine()
            return (state, false)
        } catch {
            let backup = url.deletingLastPathComponent().appendingPathComponent("state.json.corrupt-\(now)")
            try FileManager.default.moveItem(at: url, to: backup)
            return (State(now: now, config: config, calendar: calendar), true)
        }
    }
}

public struct ConfigStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func read() throws -> (config: Config, warnings: [String]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (Config(), []) }
        return try Config.parse(String(contentsOf: url, encoding: .utf8))
    }

    public func write(_ config: Config) throws {
        try config.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (config.toml() + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

public struct LogRow: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var kind: String
    public var plannedSeconds: Int
    public var outcome: String
    public var suggested: String?
    public var actual: String?

    public init(start: Int, end: Int, kind: String, plannedSeconds: Int, outcome: String,
                suggested: String? = nil, actual: String? = nil) {
        self.start = start
        self.end = end
        self.kind = kind
        self.plannedSeconds = plannedSeconds
        self.outcome = outcome
        self.suggested = suggested
        self.actual = actual
    }
}

public struct LogStore {
    public let directory: URL
    public let calendar: Calendar
    public init(directory: URL, calendar: Calendar) {
        self.directory = directory
        self.calendar = calendar
    }

    public func append(_ row: LogRow) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let day = State.localDate(row.start, calendar: calendar)
        let url = directory.appendingPathComponent("\(day).csv")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        let fields = [
            formatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.start))),
            formatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.end))),
            row.kind, String(row.plannedSeconds), row.outcome, row.suggested ?? "", row.actual ?? "",
        ]
        func quoted(_ value: String) -> String {
            guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try "start,end,kind,planned_seconds,outcome,suggested,actual\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((fields.map(quoted).joined(separator: ",") + "\n").utf8))
    }

    public func read(day: String) throws -> [[String]] {
        let url = directory.appendingPathComponent("\(day).csv")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    field.append("\""); index += 1
                } else { quoted.toggle() }
            } else if character == "," && !quoted {
                fields.append(field); field = ""
            } else if character == "\n" && !quoted {
                fields.append(field.trimmingCharacters(in: .newlines)); field = ""
                records.append(fields); fields = []
            } else { field.append(character) }
            index += 1
        }
        if !field.isEmpty || !fields.isEmpty { fields.append(field); records.append(fields) }
        return Array(records.dropFirst())
    }
}
