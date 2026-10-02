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
    for (index, answer) in [Answer.other("Other"), .didSuggested, .didSuggested] .enumerated() {
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

@Test func configDefaultsPartialAndInvalidValues() throws {
    #expect(try Config.parse("").config.timer.workMinutes == 25)
    #expect(try Config.parse("[timer]\nwork_minutes = 30").config.timer.shortBreakMinutes == 5)
    #expect(try Config.parse("[timer]\nwork_minutes = 30").config.timer.workMinutes == 30)
    #expect(try Config.parse("[unknown]\nx = 1").warnings == ["Unknown key: unknown"])
    #expect(throws: ConfigError.self) { try Config.parse("[timer]\nwork_minutes = -1") }
    #expect(throws: ConfigError.self) { try Config.parse("[work_hours]\nmon = [\"25:00\", \"18:00\"]") }
    #expect(throws: ConfigError.self) { try Config.parse("[work_hours]\nfunday = []") }
    #expect(try Config.parse(Config().toml()).config.breaks.short == Config().breaks.short)
}
