import Foundation
import FromoCore
import Testing

private func temporaryPaths() throws -> Paths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return Paths(environment: ["XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                               "XDG_STATE_HOME": root.appendingPathComponent("state").path], home: root.path)
}

@Test func stateRoundTripAndCorruptRecovery() throws {
    let paths = try temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.configDirectory.deletingLastPathComponent()) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let store = StateStore(url: paths.stateFile)
    var state = State(now: 1_000, config: Config(), calendar: calendar, pid: 99)
    state.phase = .breakDone
    state.task = "Synthetic task"
    try store.write(state)
    #expect(try store.read() == state)
    let json = try String(contentsOf: paths.stateFile, encoding: .utf8)
    #expect(json.contains("\"break_kind\""))
    try Data("{invalid".utf8).write(to: paths.stateFile)
    let recovered = try store.load(now: 2_000, config: Config(), calendar: calendar)
    #expect(recovered.recovered)
    #expect(recovered.state.phase == .ready)
    #expect(FileManager.default.fileExists(atPath: paths.stateDirectory.appendingPathComponent("state.json.corrupt-2000").path))
}

@Test func csvQuotesAndUsesStartDate() throws {
    let paths = try temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.configDirectory.deletingLastPathComponent()) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let store = LogStore(directory: paths.logDirectory, calendar: calendar)
    // Crosses midnight; the entry belongs to its start date.
    try store.append(LogRow(start: 1_799, end: 86_500, kind: "short_break", plannedSeconds: 300,
                            outcome: "did_other", suggested: "Pushups, \"fast\"", actual: "A\nB"))
    let day = State.localDate(1_799, calendar: calendar)
    let rows = try store.read(day: day)
    #expect(rows.count == 1)
    #expect(rows[0][5] == "Pushups, \"fast\"")
    #expect(rows[0][6] == "A\nB")
    #expect(try store.read(day: State.localDate(86_500, calendar: calendar)).isEmpty)
}

@Test func xdgResolutionAndSocketPathLimit() throws {
    let paths = try temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.configDirectory.deletingLastPathComponent()) }
    #expect(paths.configFile.path.contains("/config/fromo/config.toml"))
    #expect(paths.stateFile.path.contains("/state/fromo/state.json"))
    let tooLong = Paths(environment: ["XDG_STATE_HOME": "/tmp/" + String(repeating: "x", count: 100)], home: "/tmp")
    #expect(throws: ConfigError.self) { try tooLong.checkedSocketPath() }
}

@Test func configStoreHandlesMissingAndPartialConfig() throws {
    let paths = try temporaryPaths()
    defer { try? FileManager.default.removeItem(at: paths.configDirectory.deletingLastPathComponent()) }
    let store = ConfigStore(url: paths.configFile)
    #expect(try store.read().config.timer.workMinutes == 25)
    try store.write(Config())
    #expect(try store.read().config.breaks.long == ["Go for Walk", "Yoga"])
    try "[timer]\nwork_minutes = 35\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
    #expect(try store.read().config.timer.workMinutes == 35)
    #expect(try store.read().config.timer.longBreakMinutes == 15)
}
