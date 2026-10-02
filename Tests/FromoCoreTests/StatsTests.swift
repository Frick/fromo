import Foundation
import FromoCore
import Testing

private var statsCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
private func statsTime(_ value: String) -> Int {
    Int(ISO8601DateFormatter().date(from: value)!.timeIntervalSince1970)
}

@Test func statsRangesDefaultToMondayAndUseStrictDates() throws {
    let now = statsTime("2026-10-02T12:00:00Z")
    let week = try StatsPeriod.resolve(kind: .week, now: now, calendar: statsCalendar)
    #expect(week.from == "2026-09-28")
    #expect(week.to == "2026-10-02")
    #expect(try week.dates(calendar: statsCalendar).count == 5)
    #expect(try StatsPeriod.resolve(kind: .month, now: now, calendar: statsCalendar).from == "2026-10-01")
    #expect(try StatsPeriod.resolve(kind: .today, now: now, calendar: statsCalendar).from == "2026-10-02")
    #expect(throws: StatsError.self) { try StatsPeriod.custom(from: "2026-02-30", to: "2026-03-01", calendar: statsCalendar) }
    #expect(throws: StatsError.self) { try StatsPeriod.custom(from: "2026-10-02", to: "2026-10-01", calendar: statsCalendar) }
    #expect(throws: StatsError.self) { try StatsPeriod.custom(from: "../state", to: "2026-10-01", calendar: statsCalendar) }
    #expect(throws: StatsError.self) { try StatsPeriod.custom(from: "2026-1-01", to: "2026-10-01", calendar: statsCalendar) }
}

@Test func statsEnumerateCivilDaysAcrossDSTAndHonorLocalToday() throws {
    var calendar = statsCalendar
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let period = try StatsPeriod.custom(from: "2026-03-07", to: "2026-03-09", calendar: calendar)
    #expect(try period.dates(calendar: calendar) == ["2026-03-07", "2026-03-08", "2026-03-09"])
    let now = statsTime("2026-10-02T02:00:00Z")
    #expect(try StatsPeriod.resolve(kind: .today, now: now, calendar: calendar).to == "2026-10-01")
}

@Test func statsAggregateFocusComplianceTasksOtherAndMissingDays() throws {
    let period = try StatsPeriod.custom(from: "2026-09-28", to: "2026-09-30", calendar: statsCalendar)
    let rows: [String: [[String]]] = [
        "2026-09-28": [
            ["2026-09-28T09:00:00+01:00", "2026-09-28T09:30:00+01:00", "work", "1800", "completed", "", ""],
            ["2026-09-28T10:00:00+01:00", "2026-09-28T10:25:00+01:00", "work", "1500", "completed", "", ""],
            ["2026-09-28T11:00:00+01:00", "2026-09-28T11:05:00+01:00", "work", "1500", "abandoned", "", ""],
            ["2026-09-28T09:30:00+01:00", "2026-09-28T09:35:00+01:00", "short_break", "300", "did_suggested", "Pushups", "Pushups"],
            ["2026-09-28T10:25:00+01:00", "2026-09-28T10:30:00+01:00", "short_break", "300", "did_other", "Squats", "Errand"],
        ],
        "2026-09-30": [
            ["2026-09-30T09:00:00Z", "2026-09-30T09:15:00Z", "long_break", "900", "did_other", "Walk", "Other"],
            ["2026-09-30T12:00:00Z", "2026-09-30T13:00:00Z", "lunch", "3600", "completed", "", ""],
        ],
    ]
    let report = try Stats.aggregate(period: period, dailyGoal: 2, calendar: statsCalendar, rowsByDay: rows)
    #expect(report.completed == 2)
    #expect(report.abandoned == 1)
    #expect(report.focusSeconds == 3300)
    #expect(report.goalMetDays == 1)
    #expect(report.days.map(\.completed) == [2, 0, 0])
    #expect(report.shortBreaks == 2 && report.longBreaks == 1)
    #expect(abs(report.compliancePercent - 100.0 / 3) < 0.001)
    #expect(report.tasks.first(where: { $0.name == "Pushups" })?.done == 1)
    #expect(report.tasks.first(where: { $0.name == "Squats" })?.suggested == 1)
    #expect(report.other.first(where: { $0.name == "Errand" })?.count == 1)
    #expect(report.skippedRows == 0)
    #expect(report.text.contains("0h55m focus"))
    #expect(report.text.contains("compliance 33%"))
    let json = try IPCCodec.encode(report)
    let roundTrip = try IPCCodec.decode(StatsReport.self, from: json)
    #expect(roundTrip.focusSeconds == report.focusSeconds)
}

@Test func csvReadsRFC4180QuotesNewlinesCRLFAndFlagsMalformedRecords() throws {
    let text = "a,b,c\r\n\"A, B\",\"C\"\"D\",\"E\r\nF\"\r\nx,y,z\r\n"
    #expect(CSV.records(text) == [["a", "b", "c"], ["A, B", "C\"D", "E\r\nF"], ["x", "y", "z"]])
    #expect(CSV.records("a,b\n\"unterminated").last == [])
    #expect(CSV.records("a,b\nbad\"quote,x\nvalid,y\n") == [["a", "b"], [], ["valid", "y"]])
}

@Test func statsSkipUnknownMalformedRowsAndHandleEmptySuggestionLists() throws {
    let day = "2026-10-01"
    let period = try StatsPeriod.custom(from: day, to: day, calendar: statsCalendar)
    let valid = ["2026-10-01T09:00:00Z", "2026-10-01T09:05:00Z", "short_break", "300", "did_other", "", "Other"]
    var unknown = valid; unknown[2] = "unknown"
    var outcome = valid; outcome[4] = "unknown"
    var number = valid; number[3] = "negative"
    var timestamp = valid; timestamp[0] = "invalid"
    let report = try Stats.aggregate(period: period, dailyGoal: 8, calendar: statsCalendar,
                                     rowsByDay: [day: [valid, unknown, outcome, number, timestamp, []]])
    #expect(report.shortBreaks == 1)
    #expect(report.compliancePercent == 0)
    #expect(report.tasks.isEmpty)
    #expect(report.other.first?.name == "Other")
    #expect(report.skippedRows == 5)
}

@Test func statsReadSyntheticLogFilesWithoutAnEngine() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LogStore(directory: root, calendar: statsCalendar)
    let start = statsTime("2026-10-01T23:55:00Z")
    try store.append(LogRow(start: start, end: start + 900, kind: "long_break", plannedSeconds: 900,
                            outcome: "did_other", suggested: "Walk, \"outside\"", actual: "Other"))
    let period = try StatsPeriod.custom(from: "2026-10-01", to: "2026-10-02", calendar: statsCalendar)
    let report = try Stats.read(period: period, dailyGoal: 8, store: store)
    #expect(report.longBreaks == 1)
    #expect(report.tasks.first?.name == "Walk, \"outside\"")
    #expect(report.days.count == 2)
    #expect(report.skippedRows == 0)
}

@Test func badHeadersWarnAndOversizedFocusRowsDoNotOverflow() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let day = "2026-10-01"
    let store = LogStore(directory: root, calendar: statsCalendar)
    try "bad,header\n".write(to: root.appendingPathComponent(day + ".csv"), atomically: true, encoding: .utf8)
    let period = try StatsPeriod.custom(from: day, to: day, calendar: statsCalendar)
    #expect(try Stats.read(period: period, dailyGoal: 8, store: store).skippedRows == 1)
    let row = ["2026-10-01T09:00:00Z", "2026-10-01T09:25:00Z", "work", String(Int.max), "completed", "", ""]
    let report = try Stats.aggregate(period: period, dailyGoal: 8, calendar: statsCalendar, rowsByDay: [day: [row, row]])
    #expect(report.completed == 1)
    #expect(report.focusSeconds == Int.max)
    #expect(report.skippedRows == 1)
    #expect(CSV.records("\u{FEFF}a,b\nα,β\n") == [["a", "b"], ["α", "β"]])
}
