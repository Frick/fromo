import Foundation
import FromoCore
import Testing

private let monday = 1_791_190_800 // Synthetic 2026-10-05T09:00:00Z.
private var nagCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
private func nagEnv(_ now: Int, config: Config = Config(), idle: Int = 0, camera: Bool = false, mic: Bool = false) -> Environment {
    Environment(now: now, calendar: nagCalendar, config: config, idleSeconds: idle, cameraInUse: camera, micInUse: mic)
}

@Test func nagEligibilityMatrixAndFixedInterval() {
    let state = State(now: monday, config: Config(), calendar: nagCalendar)
    #expect(NagPolicy.evaluate(state: state, env: nagEnv(monday + 599), lastSuppressedAt: monday).message == nil)
    #expect(NagPolicy.evaluate(state: state, env: nagEnv(monday + 600), lastSuppressedAt: monday).message == Config().nags.unused[0])
    var disabled = Config(); disabled.nags.enabled = false
    #expect(!NagPolicy.evaluate(state: state, env: nagEnv(monday + 600, config: disabled), lastSuppressedAt: monday).eligible)
    var off = state; off.nagsOffUntil = monday + 86_400
    #expect(!NagPolicy.evaluate(state: off, env: nagEnv(monday + 600), lastSuppressedAt: monday).eligible)
    #expect(!NagPolicy.evaluate(state: state, env: nagEnv(monday - 1), lastSuppressedAt: monday).eligible)
    #expect(!NagPolicy.evaluate(state: state, env: nagEnv(monday + 600, idle: 300), lastSuppressedAt: monday).eligible)
    var meeting = state; meeting.inMeeting = true
    #expect(!NagPolicy.evaluate(state: meeting, env: nagEnv(monday + 600), lastSuppressedAt: monday).eligible)
    for phase in [Phase.work, .break, .lunch, .stopped] {
        var active = state; active.phase = phase
        #expect(!NagPolicy.evaluate(state: active, env: nagEnv(monday + 600), lastSuppressedAt: monday).eligible)
    }
    for phase in [Phase.workDone, .breakDone, .paused] {
        var waiting = state; waiting.phase = phase
        #expect(NagPolicy.evaluate(state: waiting, env: nagEnv(monday + 600), lastSuppressedAt: monday).message == Config().nags.waiting[0])
    }
    var empty = Config(); empty.nags.unused = []
    #expect(!NagPolicy.evaluate(state: state, env: nagEnv(monday + 600, config: empty), lastSuppressedAt: monday).eligible)
    empty.nags.waiting = []
    var paused = state; paused.phase = .paused
    #expect(!NagPolicy.evaluate(state: paused, env: nagEnv(monday + 600, config: empty), lastSuppressedAt: monday).eligible)
}

@Test func workHoursUseLocalCalendarAndHalfOpenBoundaries() {
    #expect(NagPolicy.inWorkHours(env: nagEnv(monday)))
    #expect(!NagPolicy.inWorkHours(env: nagEnv(monday - 1)))
    #expect(!NagPolicy.inWorkHours(env: nagEnv(monday + 9 * 3_600)))
    #expect(!NagPolicy.inWorkHours(env: nagEnv(monday + 5 * 86_400)))
    var calendar = nagCalendar
    calendar.timeZone = TimeZone(secondsFromGMT: 3_600)!
    #expect(NagPolicy.inWorkHours(env: Environment(now: monday - 3_600, calendar: calendar, config: Config())))
}

@Test func suppressionGrantsAFullIntervalAfterReturning() {
    var engine = Engine(now: monday, config: Config(), calendar: nagCalendar)
    _ = engine.tick(env: nagEnv(monday + 600, idle: 300))
    #expect(engine.tick(env: nagEnv(monday + 1_199)).isEmpty)
    let due = engine.tick(env: nagEnv(monday + 1_200))
    #expect(due.contains(.nag(Config().nags.unused[0])))
    #expect(due.contains(.playSound("Funk")))
    #expect(engine.state.lastNagAt == monday + 1_200)
    #expect(engine.tick(env: nagEnv(monday + 1_799)).isEmpty)
    #expect(engine.tick(env: nagEnv(monday + 1_800)).contains(.nag(Config().nags.unused[1])))
}

@Test func waitingCursorAdvancesAndCooldownUsesLatestTimestamp() {
    var config = Config(); config.nags.intervalMinutes = 1; config.nags.waiting = ["W", "X"]
    var state = State(now: monday, config: config, calendar: nagCalendar)
    state.phase = .paused
    state.nagCursor.unused = 1
    var engine = Engine(state: state)
    _ = engine.restore(env: nagEnv(monday, config: config))
    #expect(engine.tick(env: nagEnv(monday + 60, config: config)).contains(.nag("W")))
    #expect(engine.tick(env: nagEnv(monday + 120, config: config)).contains(.nag("X")))
    #expect(engine.state.nagCursor.waiting == 0)
    #expect(engine.state.nagCursor.unused == 1)
    state.lastNagAt = monday + 200
    #expect(NagPolicy.evaluate(state: state, env: nagEnv(monday + 250, config: config), lastSuppressedAt: monday + 220).nextNagAt == monday + 280)
}

@Test func notTodayExpiresAtMidnightAndNagCursorsCarryOver() throws {
    var config = Config()
    config.workHours = Dictionary(uniqueKeysWithValues: WorkHoursEditor.days.map { ($0, ["00:00", "23:59"]) })
    let midnight = monday + 15 * 3_600
    var state = State(now: midnight - 120, config: config, calendar: nagCalendar)
    state.nagCursor.unused = 1
    var engine = Engine(state: state)
    _ = engine.restore(env: nagEnv(midnight - 120, config: config))
    _ = try engine.handle(.notToday(true), env: nagEnv(midnight - 120, config: config))
    _ = engine.tick(env: nagEnv(midnight - 1, config: config))
    #expect(engine.tick(env: nagEnv(midnight, config: config)).contains(.nag(config.nags.unused[1])) == false)
    #expect(engine.state.nagsOffUntil == nil)
    #expect(engine.state.nagCursor.unused == 1)
    #expect(engine.tick(env: nagEnv(midnight + 600, config: config)).contains(.nag(config.nags.unused[1])))
}

@Test func hostDebugUsesCachedProbesAndDoesNotWriteOrFireNags() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(environment: ["XDG_CONFIG_HOME": root.appendingPathComponent("c").path,
                                   "XDG_STATE_HOME": root.appendingPathComponent("s").path], home: root.path)
    let host = try EngineHost(paths: paths, calendar: nagCalendar, pid: 123, now: monday,
                              probes: ProbeSnapshot(idleSeconds: 10, microphoneInUse: true), emit: { _ in })
    let before = try Data(contentsOf: paths.stateFile)
    let debug = host.handle(IPCRequest(cmd: "debug"), now: monday + 600).debug
    #expect(debug?.microphoneInUse == true)
    #expect(debug?.inMeeting == false)
    #expect(debug?.nagDue == true)
    #expect(try Data(contentsOf: paths.stateFile) == before)
    host.updateProbes(ProbeSnapshot(cameraInUse: true), now: monday + 601)
    #expect(host.handle(IPCRequest(cmd: "debug"), now: monday + 601).debug?.inMeeting == true)
}

@Test func messageCursorsWrapPersistAndStayIndependent() throws {
    var config = Config()
    config.nags.intervalMinutes = 1
    config.nags.unused = ["A", "B"]
    config.nags.waiting = ["W", "X"]
    var engine = Engine(now: monday, config: config, calendar: nagCalendar)
    #expect(engine.tick(env: nagEnv(monday + 60, config: config)).contains(.nag("A")))
    #expect(engine.tick(env: nagEnv(monday + 120, config: config)).contains(.nag("B")))
    #expect(engine.state.nagCursor.unused == 0)
    let data = try IPCCodec.encode(engine.state)
    var restored = Engine(state: try IPCCodec.decode(State.self, from: data))
    _ = restored.restore(env: nagEnv(monday + 150, config: config), pid: 123)
    #expect(!restored.tick(env: nagEnv(monday + 209, config: config)).contains(.nag("A")))
    #expect(restored.tick(env: nagEnv(monday + 210, config: config)).contains(.nag("A")))
    #expect(restored.state.nagCursor.waiting == 0)
}

@Test func meetingGraceSuppressesNagsAndPanelThenGrantsCooldown() {
    var config = Config(); config.nags.intervalMinutes = 1
    var state = State(now: monday, config: config, calendar: nagCalendar)
    state.phase = .breakDone
    state.task = "Synthetic task"
    var engine = Engine(state: state)
    _ = engine.restore(env: nagEnv(monday, config: config, camera: true))
    #expect(engine.tick(env: nagEnv(monday + 60, config: config, camera: true)).contains(.nag(config.nags.waiting[0])) == false)
    _ = engine.tick(env: nagEnv(monday + 61, config: config))
    let returned = engine.tick(env: nagEnv(monday + 91, config: config))
    #expect(returned.contains(.showAnswerPanel))
    #expect(!returned.contains(.nag(config.nags.waiting[0])))
    #expect(engine.tick(env: nagEnv(monday + 150, config: config)).contains(.nag(config.nags.waiting[0])) == false)
    #expect(engine.tick(env: nagEnv(monday + 151, config: config)).contains(.nag(config.nags.waiting[0])))
}

@Test func debugReportsRawProbesAndEligibilityWithoutNags() {
    let engine = Engine(now: monday, config: Config(), calendar: nagCalendar)
    let report = engine.debug(env: nagEnv(monday + 60, mic: true))
    #expect(report.microphoneInUse)
    #expect(!report.inMeeting)
    #expect(report.inWorkHours)
    #expect(report.nagEligible)
    #expect(!report.nagDue)
    #expect(report.nextNagAt == monday + 600)
    #expect(engine.state.lastNagAt == nil)
}

@Test func probeScheduleUsesTimestampsAndRefreshesAfterClockJump() {
    var schedule = ProbeSchedule()
    let results = [schedule.shouldRefresh(at: 1_000), schedule.shouldRefresh(at: 1_004),
                   schedule.shouldRefresh(at: 1_005), schedule.shouldRefresh(at: 2_000), schedule.shouldRefresh(at: 900)]
    #expect(results == [true, false, true, true, true])
}
