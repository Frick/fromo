import Foundation
import FromoCore
import Testing

private let utc = Calendar(identifier: .gregorian)

private func env(_ time: Int, _ config: Config = .init()) -> Environment {
    var calendar = utc
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return Environment(now: time, calendar: calendar, config: config)
}

@Test func workExpiresAtDeadlineAfterSleepAndWaitsForBreak() throws {
    var engine = Engine(now: 1_000, config: .init(), calendar: env(1_000).calendar)
    _ = try engine.handle(.start, env: env(1_000))
    #expect(engine.state.phase == .work)
    let effects = engine.tick(env: env(5_000))
    #expect(engine.state.phase == .workDone)
    #expect(engine.state.endedAt == 2_500)
    #expect(engine.state.completedToday == 1)
    #expect(effects.contains { if case .appendLog(let row) = $0 { return row.end == 2_500 }; return false })
    #expect(effects.contains(.playSound("Glass")))
    #expect(engine.tick(env: env(5_001)).isEmpty)
    #expect(throws: EngineError.self) { try engine.handle(.start, env: env(5_001)) }
}

@Test func fourthCompletedWorkGetsLongBreakAndResetsOnlyAfterAnswer() throws {
    var config = Config()
    config.timer.workMinutes = 1
    config.timer.shortBreakMinutes = 1
    config.timer.longBreakMinutes = 2
    var engine = Engine(now: 1_000, config: config, calendar: env(1_000).calendar)
    for index in 1...4 {
        let now = 1_000 + (index - 1) * 200
        if index == 1 { _ = try engine.handle(.start, env: env(now, config)) }
        _ = engine.tick(env: env(now + 60, config))
        _ = try engine.handle(.startBreak, env: env(now + 61, config))
        #expect(engine.state.breakKind == (index == 4 ? .long : .short))
        _ = try engine.handle(.endBreak, env: env(now + 62, config))
        _ = try engine.handle(.answer(.didSuggested, startNext: index < 4), env: env(now + 63, config))
        if index == 3 { #expect(engine.state.nextTask == "Go for Walk") }
    }
    #expect(engine.state.phase == .ready)
    #expect(engine.state.cycleCount == 0)
    #expect(engine.state.completedToday == 4)
}

@Test func otherAnswerRepeatsAndSuggestionWrapsIndependently() throws {
    var config = Config()
    config.timer.workMinutes = 1
    config.breaks.short = ["A", "B"]
    config.breaks.long = ["L", "M"]
    var engine = Engine(now: 1_000, config: config, calendar: env(1_000).calendar)
    for (index, answer) in [Answer.other("Other"), .didSuggested, .didSuggested].enumerated() {
        let now = 1_000 + index * 100
        _ = try engine.handle(.start, env: env(now, config))
        _ = engine.tick(env: env(now + 60, config))
        _ = try engine.handle(.startBreak, env: env(now + 61, config))
        #expect(engine.state.task == (index == 2 ? "B" : "A"))
        _ = try engine.handle(.endBreak, env: env(now + 62, config))
        _ = try engine.handle(.answer(answer, startNext: false), env: env(now + 63, config))
    }
    #expect(engine.state.rotation.short.name == "A")
    #expect(engine.state.rotation.long.name == "L")
}

@Test func rotationSurvivesRenameMoveRemovalAndEmptyLists() throws {
    var config = Config()
    config.breaks.short = ["A", "B", "C"]
    config.breaks.long = []
    config.breaks.other = []
    var engine = Engine(now: 1_000, config: config, calendar: env(1_000).calendar)
    #expect(engine.state.rotation.long.name == nil)
    _ = try engine.handle(.start, env: env(1_000, config))
    _ = engine.tick(env: env(2_500, config))
    _ = try engine.handle(.startBreak, env: env(2_501, config))
    _ = try engine.handle(.endBreak, env: env(2_502, config))
    _ = try engine.handle(.answer(.didSuggested, startNext: false), env: env(2_503, config))
    #expect(engine.state.rotation.short.name == "B")
    config.breaks.short = ["C", "B", "A"]
    _ = try engine.handle(.reloadConfig, env: env(2_504, config))
    #expect(engine.state.rotation.short.index == 1)
    config.breaks.short = ["D", "C"]
    _ = try engine.handle(.reloadConfig, env: env(2_505, config))
    #expect(engine.state.rotation.short.name == "C")
    config.breaks.short = []
    _ = try engine.handle(.reloadConfig, env: env(2_506, config))
    #expect(engine.state.nextTask == nil)
    _ = try engine.handle(.start, env: env(2_507, config))
    _ = engine.tick(env: env(4_007, config))
    _ = try engine.handle(.startBreak, env: env(4_008, config))
    #expect(engine.state.task == nil)
    _ = try engine.handle(.endBreak, env: env(4_009, config))
    #expect(throws: EngineError.self) { try engine.handle(.answer(.didSuggested, startNext: false), env: env(4_010, config)) }
    _ = try engine.handle(.answer(.other("other"), startNext: false), env: env(4_010, config))
    #expect(engine.state.rotation.short.name == nil)
}

@Test func abandonedWorkDoesNotCountAndPauseResetLogsAbandonment() throws {
    var engine = Engine(now: 1_000, config: .init(), calendar: env(1_000).calendar)
    _ = try engine.handle(.start, env: env(1_000))
    _ = try engine.handle(.extend(3), env: env(1_100))
    #expect(engine.state.plannedSeconds == 1_680)
    _ = try engine.handle(.pause, env: env(1_200))
    let effects = try engine.handle(.reset, env: env(1_201))
    #expect(engine.state.phase == .ready)
    #expect(engine.state.cycleCount == 0)
    #expect(effects.contains { if case .appendLog(let row) = $0 { return row.outcome == "abandoned" && row.plannedSeconds == 1_680 }; return false })
    #expect(throws: EngineError.self) { try engine.handle(.extend(0), env: env(1_202)) }
}

@Test func lunchFromEveryPhaseRestoresThePriorPhase() throws {
    let phases: [Phase] = [.ready, .work, .workDone, .break, .breakDone, .paused]
    for phase in phases {
        var engine = Engine(now: 1_000, config: .init(), calendar: env(1_000).calendar)
        if phase != .ready {
            _ = try engine.handle(.start, env: env(1_000))
            if phase == .paused { _ = try engine.handle(.pause, env: env(1_020)) }
            if [.workDone, .break, .breakDone].contains(phase) {
                _ = engine.tick(env: env(2_500))
                if [.break, .breakDone].contains(phase) { _ = try engine.handle(.startBreak, env: env(2_501)) }
                if phase == .breakDone { _ = try engine.handle(.endBreak, env: env(2_502)) }
            }
        }
        let now = phase == .ready || phase == .work || phase == .paused ? 1_030 : 2_510
        _ = try engine.handle(.lunch(2), env: env(now))
        #expect(engine.state.phase == .lunch)
        let effects = engine.tick(env: env(now + 200))
        let expected: Phase = [.work, .break, .paused].contains(phase) ? .paused : phase
        #expect(engine.state.phase == expected)
        #expect(effects.contains { if case .appendLog(let row) = $0 { return row.kind == "lunch" && row.end == now + 120 }; return false })
    }
}

@Test func midnightResetsCountsAndNotTodayUsingInjectedCalendar() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let midnight = 86_400
    var engine = Engine(now: midnight - 2_000, config: .init(), calendar: calendar)
    _ = try engine.handle(.notToday(true), env: env(midnight - 2_000))
    #expect(engine.state.nagsOffUntil == midnight)
    _ = try engine.handle(.start, env: env(midnight - 1_700))
    _ = engine.tick(env: env(midnight - 199))
    #expect(engine.state.completedToday == 1)
    _ = engine.tick(env: env(midnight))
    #expect(engine.state.completedToday == 0)
    #expect(engine.state.cycleCount == 0)
    #expect(engine.state.nagsOffUntil == nil)
    #expect(engine.state.rotation.short.name == "Pushups")
}

@Test func daylightSavingTransitionPreservesElapsedSeconds() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let before = ISO8601DateFormatter().date(from: "2026-03-08T01:50:00-05:00")!
    let start = Int(before.timeIntervalSince1970)
    var engine = Engine(now: start, config: .init(), calendar: calendar)
    _ = try engine.handle(.start, env: Environment(now: start, calendar: calendar, config: .init()))
    let effects = engine.tick(env: Environment(now: start + 1_501, calendar: calendar, config: .init()))
    #expect(engine.state.endedAt == start + 1_500)
    #expect(engine.state.date == "2026-03-08")
    #expect(effects.contains { if case .appendLog(let row) = $0 { return row.end - row.start == 1_500 }; return false })
}

@Test func meetingProbeSuppressesPanelAndSoundUntilThirtyQuietSeconds() throws {
    var engine = Engine(now: 1_000, config: .init(), calendar: env(1_000).calendar)
    _ = try engine.handle(.start, env: env(1_000))
    _ = engine.tick(env: Environment(now: 2_500, calendar: env(2_500).calendar, config: .init()))
    _ = try engine.handle(.startBreak, env: env(2_501))
    let busy = Environment(now: 2_502, calendar: env(2_502).calendar, config: .init(), cameraInUse: true)
    _ = engine.tick(env: busy)
    #expect(engine.state.inMeeting)
    let effects = try engine.handle(.endBreak, env: busy)
    #expect(effects.contains(.notify("break_end")))
    #expect(!effects.contains(.playSound("break_end")))
    #expect(!effects.contains(.showAnswerPanel))
    _ = engine.tick(env: env(2_503))
    #expect(engine.state.inMeeting)
    _ = engine.tick(env: env(2_532))
    #expect(engine.state.inMeeting)
    #expect(engine.tick(env: env(2_533)).contains(.showAnswerPanel))
    #expect(!engine.state.inMeeting)
}

@Test func microphoneProbeIsOffByDefaultAndCanBeEnabled() throws {
    var engine = Engine(now: 1_000, config: .init(), calendar: env(1_000).calendar)
    let mic = Environment(now: 1_001, calendar: env(1_001).calendar, config: .init(), micInUse: true)
    #expect(engine.tick(env: mic).isEmpty)
    var config = Config()
    config.meetings.microphone = true
    let enabled = Environment(now: 1_002, calendar: env(1_002).calendar, config: config, micInUse: true)
    #expect(engine.tick(env: enabled).contains { if case .writeState(let state) = $0 { return state.inMeeting }; return false })
}

@Test func pauseAndLunchFreezeTimeAcrossRestart() throws {
    var engine = Engine(now: 1_000, config: .init(), calendar: env(1_000).calendar)
    _ = try engine.handle(.start, env: env(1_000))
    _ = try engine.handle(.lunch(10), env: env(1_030))
    let data = try JSONEncoder().encode(engine.state)
    let restored = try JSONDecoder().decode(State.self, from: data)
    engine = Engine(state: restored)
    _ = engine.tick(env: env(2_000))
    #expect(engine.state.phase == .paused)
    #expect(engine.state.pausedPhase == .work)
    #expect(engine.state.remaining == 1_470)
    _ = try engine.handle(.resume, env: env(2_100))
    #expect(engine.state.endsAt == 3_570)
}

@Test func invalidCommandsAreRejectedAcrossPhases() throws {
    var engine = Engine(now: 1_000, config: .init(), calendar: env(1_000).calendar)
    for command in [Command.pause, .resume, .startBreak, .endBreak, .answer(.didSuggested, startNext: true)] {
        #expect(throws: EngineError.self) { try engine.handle(command, env: env(1_000)) }
    }
    _ = try engine.handle(.start, env: env(1_000))
    for command in [Command.start, .startBreak, .resume, .answer(.didSuggested, startNext: true)] {
        #expect(throws: EngineError.self) { try engine.handle(command, env: env(1_001)) }
    }
}

@Test func rejectionMatrixCoversEveryPhase() throws {
    let invalid: [(Phase, Phase?, [Command])] = [
        (.ready, nil, [.pause, .resume, .restart, .startBreak, .endBreak, .reset, .extend(nil), .endLunch, .answer(.didSuggested, startNext: false)]),
        (.work, nil, [.start, .resume, .startBreak, .endBreak, .endLunch, .answer(.didSuggested, startNext: false), .next]),
        (.workDone, nil, [.start, .pause, .resume, .restart, .endBreak, .reset, .extend(nil), .endLunch, .answer(.didSuggested, startNext: false)]),
        (.break, nil, [.start, .startBreak, .resume, .reset, .endLunch, .answer(.didSuggested, startNext: false), .next]),
        (.breakDone, nil, [.start, .startBreak, .pause, .resume, .restart, .reset, .extend(nil), .endBreak, .endLunch]),
        (.paused, .work, [.start, .pause, .startBreak, .extend(nil), .endBreak, .endLunch, .answer(.didSuggested, startNext: false)]),
        (.paused, .break, [.start, .pause, .startBreak, .extend(nil), .reset, .endLunch, .answer(.didSuggested, startNext: false)]),
        (.lunch, nil, [.start, .startBreak, .pause, .resume, .restart, .reset, .extend(nil), .endBreak, .lunch(nil), .answer(.didSuggested, startNext: false)]),
    ]
    for (phase, pausedFrom, commands) in invalid {
        var state = State(now: 1_000, config: .init(), calendar: env(1_000).calendar)
        state.phase = phase
        state.pausedPhase = pausedFrom
        var engine = Engine(state: state)
        for command in commands {
            #expect(throws: EngineError.self) { try engine.handle(command, env: env(1_001)) }
            #expect(engine.state.phase == phase)
        }
    }
}

@Test func persistedStateRestoresEveryPhaseAndShowsPendingAnswer() throws {
    for phase in [Phase.ready, .work, .workDone, .break, .breakDone, .paused, .lunch] {
        var state = State(now: 1_000, config: .init(), calendar: env(1_000).calendar)
        state.phase = phase
        if phase == .work || phase == .break { state.endsAt = 3_000 }
        if phase == .lunch { state.lunch = LunchState(endsAt: 3_000, returnPhase: .ready, returnRemaining: nil, returnPhaseEnteredAt: 1_000) }
        let data = try JSONEncoder().encode(state)
        var engine = Engine(state: try JSONDecoder().decode(State.self, from: data))
        let effects = engine.restore(env: env(1_100))
        #expect(engine.state.phase == phase)
        #expect(effects.contains(.showAnswerPanel) == (phase == .breakDone))
    }
}

@Test func restoreUpdatesPidAndReportsCorruptionOnce() {
    var engine = Engine(now: 1_000, config: .init(), calendar: env(1_000).calendar)
    let effects = engine.restore(env: env(1_001), pid: 123, recovered: true)
    #expect(engine.state.pid == 123)
    #expect(effects.contains(.notify("state_corrupt")))
    #expect(effects.contains { if case .writeState(let state) = $0 { return state.pid == 123 }; return false })
    #expect(engine.restore(env: env(1_002), pid: 123).isEmpty)
}

@Test func longRotationIsIndependentOfShortRotation() throws {
    var config = Config()
    config.timer.workMinutes = 1
    config.timer.longBreakEvery = 1
    config.breaks.short = ["S1", "S2"]
    config.breaks.long = ["L1", "L2"]
    var engine = Engine(now: 1_000, config: config, calendar: env(1_000, config).calendar)
    #expect(engine.state.nextTask == "L1")
    _ = try engine.handle(.start, env: env(1_000, config))
    _ = engine.tick(env: env(1_060, config))
    _ = try engine.handle(.startBreak, env: env(1_061, config))
    #expect(engine.state.task == "L1")
    _ = try engine.handle(.endBreak, env: env(1_062, config))
    _ = try engine.handle(.answer(.didSuggested, startNext: false), env: env(1_063, config))
    #expect(engine.state.rotation.short.name == "S1")
    #expect(engine.state.rotation.long.name == "L2")
    #expect(engine.state.cycleCount == 0)
}

@Test func restartAndEndBreakEarlyPreserveLoggingRules() throws {
    var config = Config()
    config.timer.workMinutes = 1
    var engine = Engine(now: 1_000, config: config, calendar: env(1_000, config).calendar)
    _ = try engine.handle(.start, env: env(1_000, config))
    _ = try engine.handle(.pause, env: env(1_010, config))
    _ = try engine.handle(.restart, env: env(1_100, config))
    #expect(engine.state.endsAt == 1_160)
    #expect(engine.state.startedAt == 1_100)
    _ = engine.tick(env: env(1_160, config))
    _ = try engine.handle(.startBreak, env: env(1_161, config))
    _ = try engine.handle(.pause, env: env(1_170, config))
    _ = try engine.handle(.endBreak, env: env(1_171, config))
    let effects = try engine.handle(.answer(.other("OTHER"), startNext: true), env: env(1_172, config))
    #expect(engine.state.phase == .work)
    #expect(engine.state.startedAt == 1_172)
    #expect(effects.contains { if case .appendLog(let row) = $0 {
        return row.end == 1_171 && row.start == 1_161 && row.actual == "Other"
    }; return false })
}

@Test func configDefaultsPartialAndInvalidValues() throws {
    #expect(try Config.parse("").config.timer.workMinutes == 25)
    #expect(try Config.parse("[timer]\nwork_minutes = 30").config.timer.shortBreakMinutes == 5)
    #expect(try Config.parse("[timer]\nwork_minutes = 30").config.timer.workMinutes == 30)
    #expect(try Config.parse("[unknown]\nx = 1").warnings == ["Unknown key: unknown"])
    #expect(throws: ConfigError.self) { try Config.parse("[timer]\nwork_minutes = -1") }
    #expect(throws: ConfigError.self) { try Config.parse("[work_hours]\nmon = [\"25:00\", \"18:00\"]") }
    #expect(throws: ConfigError.self) { try Config.parse("[work_hours]\nfunday = []") }
    #expect(try Config.parse(Config().toml()).config.breaks.short == Config().breaks.short)
    for field in ["short_break_minutes", "long_break_minutes", "long_break_every", "extend_minutes", "lunch_minutes"] {
        #expect(throws: ConfigError.self) { try Config.parse("[timer]\n\(field) = -1") }
    }
    #expect(throws: ConfigError.self) { try Config.parse("[timer]\ndaily_goal = -1") }
    #expect(throws: ConfigError.self) { try Config.parse("[nags]\ninterval_minutes = 0") }
    #expect(throws: ConfigError.self) { try Config.parse("[nags]\nidle_threshold_minutes = -1") }
    #expect(throws: ConfigError.self) { try Config.parse("[work_hours]\nmon = [\"10:00\"]") }
    #expect(throws: ConfigError.self) { try Config.parse("[work_hours]\nmon = [\"18:00\", \"09:00\"]") }
    #expect(throws: ConfigError.self) { try Config.parse("[timer]\nwork_minutes = \"long\"") }
    #expect(throws: ConfigError.self) { try Config.parse("[timer]\nwork_minutes = ") }
    #expect(try Config.parse("[timer]\nfuture = true").warnings == ["Unknown key: timer.future"])
}
