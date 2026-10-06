import Foundation
import FromoCore
import Testing

private func dayTime(_ text: String) -> Int { Int(ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970) }
private var dayCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
private func dayEnv(_ text: String, idle: Int = 0, camera: Bool = false, config: Config = Config()) -> Environment {
    Environment(now: dayTime(text), calendar: dayCalendar, config: config, idleSeconds: idle, cameraInUse: camera)
}

@Test func workdayCloseNeedsAnHourPastEndAndAnHourIdleWithoutMeeting() {
    let start = dayTime("2026-10-05T09:00:00Z")
    let state = State(now: start, config: Config(), calendar: dayCalendar)
    #expect(WorkdayPolicy.evaluate(state: state, env: dayEnv("2026-10-05T18:59:59Z", idle: 7_200)) == nil)
    #expect(WorkdayPolicy.evaluate(state: state, env: dayEnv("2026-10-05T19:00:00Z", idle: 3_599)) == nil)
    #expect(WorkdayPolicy.evaluate(state: state, env: dayEnv("2026-10-05T19:00:00Z", idle: 3_600))?.reason == .afterHoursIdle)
    var meeting = state; meeting.inMeeting = true
    #expect(WorkdayPolicy.evaluate(state: meeting, env: dayEnv("2026-10-05T19:00:00Z", idle: 3_600)) == nil)
}

@Test func endDayClearsTimerPreservesTodayHistoryAndRotationAndReopensExplicitly() throws {
    var engine = Engine(now: dayTime("2026-10-05T09:00:00Z"), config: Config(), calendar: dayCalendar)
    _ = try engine.handle(.start, env: dayEnv("2026-10-05T09:00:00Z"))
    _ = engine.tick(env: dayEnv("2026-10-05T09:25:00Z"))
    let rotation = engine.state.rotation
    _ = try engine.handle(.endDay, env: dayEnv("2026-10-05T18:30:00Z"))
    #expect(engine.state.phase == .ready)
    #expect(engine.state.endsAt == nil && engine.state.endedAt == nil && engine.state.startedAt == nil)
    #expect(engine.state.completedToday == 1)
    #expect(engine.state.cycleCount == 0)
    #expect(engine.state.rotation == rotation)
    #expect(engine.state.dayClosedAt != nil)
    #expect(engine.tick(env: dayEnv("2026-10-05T18:31:00Z", idle: 10_000)).isEmpty)
    _ = try engine.handle(.start, env: dayEnv("2026-10-05T18:32:00Z", idle: 10_000))
    #expect(engine.state.dayClosedAt == nil)
    #expect(engine.tick(env: dayEnv("2026-10-05T18:32:01Z", idle: 10_000)).isEmpty)
    #expect(engine.state.phase == .work)
}

@Test func unfinishedWorkIsAbandonedAndExpiredWorkIsCompletedBeforeSilentClose() throws {
    var config = Config(); config.timer.workMinutes = 120
    var engine = Engine(now: dayTime("2026-10-05T17:30:00Z"), config: config, calendar: dayCalendar)
    _ = try engine.handle(.start, env: dayEnv("2026-10-05T17:30:00Z", config: config))
    let effects = engine.tick(env: dayEnv("2026-10-05T19:00:00Z", idle: 3_600, config: config))
    #expect(effects.contains { if case .appendLog(let row) = $0 { return row.kind == "work" && row.outcome == "abandoned" }; return false })
    #expect(engine.state.completedToday == 0)
    #expect(engine.state.phase == .ready)
    var expired = Engine(now: dayTime("2026-10-05T17:30:00Z"), config: Config(), calendar: dayCalendar)
    _ = try expired.handle(.start, env: dayEnv("2026-10-05T17:30:00Z"))
    let completed = expired.tick(env: dayEnv("2026-10-05T19:00:00Z", idle: 3_600))
    #expect(completed.contains { if case .appendLog(let row) = $0 { return row.outcome == "completed" && row.end == dayTime("2026-10-05T17:55:00Z") }; return false })
    #expect(!completed.contains(.notify("work_end")))
    #expect(expired.state.completedToday == 1)
}

@Test func unansweredBreaksCloseFromRunningPausedAndWaitingWithoutInventingAnAnswer() throws {
    for phase in [Phase.break, .paused, .breakDone] {
        var engine = Engine(now: dayTime("2026-10-05T09:00:00Z"), config: Config(), calendar: dayCalendar)
        _ = try engine.handle(.start, env: dayEnv("2026-10-05T09:00:00Z"))
        _ = engine.tick(env: dayEnv("2026-10-05T09:25:00Z"))
        _ = try engine.handle(.startBreak, env: dayEnv("2026-10-05T09:26:00Z"))
        if phase == .paused { _ = try engine.handle(.pause, env: dayEnv("2026-10-05T09:27:00Z")) }
        if phase == .breakDone { _ = try engine.handle(.endBreak, env: dayEnv("2026-10-05T09:28:00Z")) }
        let effects = try engine.handle(.endDay, env: dayEnv("2026-10-05T18:00:00Z"))
        #expect(effects.contains { if case .appendLog(let row) = $0 { return row.outcome == "unanswered" && row.actual == nil && row.suggested == "Pushups" }; return false })
        #expect(effects.contains(.hideAnswerPanel))
        #expect(engine.state.rotation.short.name == "Pushups")
        #expect(engine.state.phase == .ready)
    }
}

@Test func morningBackstopRunsBeforeStaleExpiryAcrossWeekendAndRestart() throws {
    var engine = Engine(now: dayTime("2026-10-02T17:30:00Z"), config: Config(), calendar: dayCalendar)
    _ = try engine.handle(.start, env: dayEnv("2026-10-02T17:30:00Z"))
    let persisted = try IPCCodec.encode(engine.state)
    var restored = Engine(state: try IPCCodec.decode(State.self, from: persisted))
    let effects = restored.restore(env: dayEnv("2026-10-05T09:00:00Z"), pid: 123)
    #expect(restored.state.phase == .ready)
    #expect(restored.state.completedToday == 0)
    #expect(restored.state.workdayDate == "2026-10-05")
    #expect(restored.state.dayClosedAt == nil)
    #expect(!effects.contains(.notify("work_end")))
    #expect(effects.contains { if case .appendLog(let row) = $0 { return row.outcome == "completed" && row.end == dayTime("2026-10-02T17:55:00Z") }; return false })
    #expect(restored.tick(env: dayEnv("2026-10-05T09:00:01Z")).isEmpty)
}

@Test func lunchAndItsPausedSessionAreClosedTogether() throws {
    var engine = Engine(now: dayTime("2026-10-05T17:30:00Z"), config: Config(), calendar: dayCalendar)
    _ = try engine.handle(.start, env: dayEnv("2026-10-05T17:30:00Z"))
    _ = try engine.handle(.lunch(120), env: dayEnv("2026-10-05T17:35:00Z"))
    let effects = try engine.handle(.endDay, env: dayEnv("2026-10-05T18:00:00Z"))
    #expect(effects.contains { if case .appendLog(let row) = $0 { return row.kind == "lunch" && row.outcome == "ended_early" }; return false })
    #expect(effects.contains { if case .appendLog(let row) = $0 { return row.kind == "work" && row.outcome == "abandoned" }; return false })
    #expect(engine.state.lunch == nil && engine.state.remaining == nil && engine.state.pausedPhase == nil)
}

@Test func closedDaySuppressesNagsAndUnansweredDoesNotDiluteCompliance() throws {
    var engine = Engine(now: dayTime("2026-10-05T09:00:00Z"), config: Config(), calendar: dayCalendar)
    _ = try engine.handle(.endDay, env: dayEnv("2026-10-05T10:00:00Z"))
    #expect(!engine.debug(env: dayEnv("2026-10-05T12:00:00Z")).nagEligible)
    let period = try StatsPeriod.custom(from: "2026-10-05", to: "2026-10-05", calendar: dayCalendar)
    let rows = [["2026-10-05T09:30:00Z", "2026-10-05T09:35:00Z", "short_break", "300", "did_suggested", "A", "A"],
                ["2026-10-05T10:00:00Z", "2026-10-05T10:05:00Z", "short_break", "300", "unanswered", "B", ""]]
    let report = try Stats.aggregate(period: period, dailyGoal: 8, calendar: dayCalendar, rowsByDay: ["2026-10-05": rows])
    #expect(report.shortBreaks == 2 && report.unansweredBreaks == 1 && report.answeredBreaks == 1)
    #expect(report.compliancePercent == 100)
    #expect(report.skippedRows == 0)
}

@Test func legacyStateMigratesAndClosedStatePersistsAcrossRestart() throws {
    var engine = Engine(now: dayTime("2026-10-05T09:00:00Z"), config: Config(), calendar: dayCalendar)
    _ = try engine.handle(.start, env: dayEnv("2026-10-05T09:00:00Z"))
    var old = try JSONSerialization.jsonObject(with: IPCCodec.encode(engine.state)) as! [String: Any]
    for key in ["workday_date", "day_opened_at", "day_closed_at"] { old.removeValue(forKey: key) }
    var migrated = Engine(state: try IPCCodec.decode(State.self, from: JSONSerialization.data(withJSONObject: old)))
    _ = migrated.restore(env: dayEnv("2026-10-06T09:00:00Z"), pid: 123)
    #expect(migrated.state.phase == .ready)
    #expect(migrated.state.workdayDate == "2026-10-06")
    _ = try migrated.handle(.endDay, env: dayEnv("2026-10-06T12:00:00Z"))
    _ = try migrated.handle(.stop, env: dayEnv("2026-10-06T12:01:00Z"))
    var restarted = Engine(state: try IPCCodec.decode(State.self, from: IPCCodec.encode(migrated.state)))
    _ = restarted.restore(env: dayEnv("2026-10-06T12:02:00Z"), pid: 124)
    #expect(restarted.state.dayClosedAt != nil)
    #expect(!restarted.debug(env: dayEnv("2026-10-06T13:00:00Z")).nagEligible)
}

@Test func dayOffDoesNotCreateAMorningBoundaryAndEarlyExplicitWorkIsKept() throws {
    let state = State(now: dayTime("2026-10-02T09:00:00Z"), config: Config(), calendar: dayCalendar)
    #expect(WorkdayPolicy.evaluate(state: state, env: dayEnv("2026-10-03T09:00:00Z")) == nil)
    var engine = Engine(now: dayTime("2026-10-05T08:30:00Z"), config: Config(), calendar: dayCalendar)
    _ = try engine.handle(.start, env: dayEnv("2026-10-05T08:30:00Z"))
    #expect(WorkdayPolicy.evaluate(state: engine.state, env: dayEnv("2026-10-05T09:00:00Z")) == nil)
}

@Test func closureCrossingMidnightUsesTrackedDayAndDSTCalendarWindow() throws {
    var config = Config()
    config.workHours["fri"] = ["09:00", "23:30"]
    let state = State(now: dayTime("2026-10-02T09:00:00Z"), config: config, calendar: dayCalendar)
    #expect(WorkdayPolicy.evaluate(state: state, env: dayEnv("2026-10-03T00:29:59Z", idle: 7_200, config: config)) == nil)
    #expect(WorkdayPolicy.evaluate(state: state, env: dayEnv("2026-10-03T00:30:00Z", idle: 7_200, config: config))?.reason == .afterHoursIdle)
    var calendar = dayCalendar
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let before = dayTime("2026-10-30T09:00:00-04:00")
    let after = dayTime("2026-11-02T09:00:00-05:00")
    let dstState = State(now: before, config: Config(), calendar: calendar)
    #expect(WorkdayPolicy.evaluate(state: dstState, env: Environment(now: after, calendar: calendar, config: Config()))?.at == after)
}

@Test func dayEndConfigDefaultsValidationAndManualControlAreExposed() throws {
    #expect(try Config.parse("[general]\nlaunch_at_login = false").config.general.dayEndIdleMinutes == 60)
    #expect(throws: ConfigError.self) { try Config.parse("[general]\nday_end_idle_minutes = 0") }
    #expect(try IPCRequest(cmd: "end_day").command() == .endDay)
    let state = State(now: dayTime("2026-10-05T09:00:00Z"), config: Config(), calendar: dayCalendar)
    #expect(MenuModel(state: state, config: Config(), now: state.updatedAt).endDay.enabled)
}
