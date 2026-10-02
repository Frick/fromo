import Foundation
import FromoCore
import Testing

private func appState(_ phase: Phase) -> State {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var state = State(now: 1_000, config: .init(), calendar: calendar)
    state.phase = phase
    state.startedAt = 1_000; state.endsAt = 2_500; state.endedAt = 2_500
    state.plannedSeconds = 1_500
    state.task = "Pushups"; state.breakKind = .short
    state.pausedPhase = .work; state.remaining = 1_500
    state.lunch = LunchState(endsAt: 4_600, returnPhase: .ready, returnRemaining: nil, returnPhaseEnteredAt: 1_000)
    return state
}

@Test func menuUsesEngineValidityAndPhaseSpecificPrimaryAction() {
    for (phase, title, command) in [(Phase.ready, "Start Work", Command.start),
                                   (.workDone, "Start Break", .startBreak),
                                   (.breakDone, "Answer Break…", .next), (.paused, "Resume", .resume),
                                   (.lunch, "End Lunch", .endLunch)] {
        let menu = MenuModel(state: appState(phase), config: .init(), now: 1_000)
        #expect(menu.primary.title == title)
        #expect(menu.primary.command == command)
        #expect(menu.primary.enabled)
    }
    let menu = MenuModel(state: appState(.breakDone), config: .init(), now: 1_000)
    #expect(!menu.controls.first(where: { $0.command == .reset })!.enabled)
    #expect(!menu.controls.first(where: { $0.command == .extend(nil) })!.enabled)
    #expect(!menu.settings.enabled)
}

@Test func notificationCatalogHonorsForwardOnlyWorkCompletion() {
    let notification = NotificationModel(kind: "work_end", state: appState(.workDone), config: .init())
    #expect(notification.title == "Work session done")
    #expect(notification.body == "Break next: Pushups")
    #expect(notification.actions.map(\.command) == [.startBreak])
    #expect(NotificationModel.command(for: "not_today") == .notToday(true))
    #expect(NotificationModel.command(for: "continue") == .next)
    #expect(NotificationModel.command(for: "body", category: "break_end") == .next)
}

@Test func panelMapsShiftAndDefaultStartWithoutShellDecisions() {
    let model = AnswerPanelModel(state: appState(.breakDone), config: .init())
    #expect(model.suggestion == "Pushups")
    #expect(model.other == ["Other"])
    #expect(model.command(answer: .didSuggested, startNext: true, shift: true) == .answer(.didSuggested, startNext: false))
    #expect(model.command(answer: .other("Other"), startNext: false, shift: true) == .answer(.other("Other"), startNext: true))
}

@Test func sketchybarResolutionWorksWithoutPathLookup() {
    var config = SketchyBarConfig()
    #expect(SketchyBarInvocation(config: config, existing: ["/usr/local/bin/sketchybar"])?.executable == "/usr/local/bin/sketchybar")
    config.path = "/synthetic/sketchybar"
    #expect(SketchyBarInvocation(config: config, existing: [])?.executable == config.path)
    config.enabled = false
    #expect(SketchyBarInvocation(config: config, existing: [config.path]) == nil)
}

@Test func diagnosticLogIsBoundedWithoutReadingRealState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DiagnosticsStore(url: root.appendingPathComponent("fromo.log"))
    try store.append(String(repeating: "x", count: DiagnosticsStore.maximumBytes - 2))
    try store.append("synthetic error")
    #expect(try String(contentsOf: store.url, encoding: .utf8) == "synthetic error\n")
}

@Test func launchReconcilesEditedTaskListsWithoutChangingRunningDeadline() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var engine = Engine(now: 1_000, config: .init(), calendar: calendar)
    _ = try engine.handle(.start, env: Environment(now: 1_000, calendar: calendar, config: .init()))
    var config = Config()
    config.breaks.short = ["Synthetic task"]
    config.timer.workMinutes = 1
    _ = engine.restore(env: Environment(now: 1_100, calendar: calendar, config: config), pid: 123)
    #expect(engine.state.rotation.short.name == "Synthetic task")
    #expect(engine.state.endsAt == 2_500)
}

@Test func loginPreferenceIsAnEngineEffectOnLaunchAndConfigChange() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var engine = Engine(now: 1_000, config: .init(), calendar: calendar)
    #expect(engine.restore(env: Environment(now: 1_000, calendar: calendar, config: .init())).contains(.setLaunchAtLogin(true)))
    var config = Config()
    config.general.launchAtLogin = false
    #expect(try engine.handle(.reloadConfig, env: Environment(now: 1_001, calendar: calendar, config: config)).contains(.setLaunchAtLogin(false)))
}
