import Foundation
import FromoCore
import Testing

@Test func invalidReloadKeepsLastGoodAndNotifiesOncePerDistinctError() throws {
    var policy = ConfigReloadPolicy()
    var config = Config()
    config.timer.workMinutes = 30
    #expect(policy.accept(config).changed)
    #expect(policy.reject("synthetic first error").shouldNotify)
    #expect(!policy.reject("synthetic first error").shouldNotify)
    #expect(policy.config.timer.workMinutes == 30)
    #expect(policy.reject("synthetic second error").shouldNotify)
    _ = policy.accept(config)
    #expect(policy.error == nil)
    #expect(!policy.reject("synthetic first error").shouldNotify)
}

@Test func draftDebouncesEditsAndRejectsInvalidValuesWithoutLosingThem() {
    var draft = SettingsDraft(config: Config())
    var edited = draft.config
    edited.timer.workMinutes = 30
    draft.edit(edited, nowMilliseconds: 1_000)
    #expect(draft.takeWrite(nowMilliseconds: 1_499) == nil)
    edited.timer.workMinutes = 35
    draft.edit(edited, nowMilliseconds: 1_400)
    #expect(draft.takeWrite(nowMilliseconds: 1_500) == nil)
    #expect(draft.takeWrite(nowMilliseconds: 1_900)?.timer.workMinutes == 35)
    #expect(draft.takeWrite(nowMilliseconds: 2_000) == nil)
    edited.timer.workMinutes = -1
    draft.edit(edited, nowMilliseconds: 2_000)
    #expect(draft.validationError != nil)
    #expect(draft.takeWrite(nowMilliseconds: 3_000) == nil)
    #expect(draft.config.timer.workMinutes == -1)
}

@Test func ownWriteEchoKeepsNewerDraftAndExternalChangeCancelsPendingSave() {
    var draft = SettingsDraft(config: Config())
    var saved = Config()
    saved.timer.workMinutes = 30
    draft.edit(saved, nowMilliseconds: 1_000)
    _ = draft.takeWrite(nowMilliseconds: 1_500)
    draft.didSave(saved)
    var newer = saved
    newer.timer.workMinutes = 35
    draft.edit(newer, nowMilliseconds: 1_600)
    let ownEchoChanged = draft.receive(saved)
    #expect(!ownEchoChanged)
    #expect(draft.config.timer.workMinutes == 35)
    var external = saved
    external.timer.workMinutes = 40
    let externalChanged = draft.receive(external)
    #expect(externalChanged)
    #expect(draft.config.timer.workMinutes == 40)
    #expect(draft.takeWrite(nowMilliseconds: 2_200) == nil)
}

@Test func orderedListsAndWorkHoursEditWithoutSwiftUI() {
    var values = ["A", "B", "C", "D"]
    SettingsLists.move(&values, from: IndexSet([0, 2]), to: 4)
    #expect(values == ["B", "D", "A", "C"])
    SettingsLists.remove(&values, at: IndexSet([1, 3]))
    #expect(values == ["B", "A"])
    var config = Config()
    WorkHoursEditor.setEnabled(false, day: "mon", in: &config)
    #expect(config.workHours["mon"] == [])
    WorkHoursEditor.setEnabled(true, day: "mon", in: &config)
    #expect(config.workHours["mon"] == ["09:00", "18:00"])
    WorkHoursEditor.setTime(hour: 10, minute: 5, index: 0, day: "mon", in: &config)
    #expect(config.workHours["mon"] == ["10:05", "18:00"])
}

@Test func hostReloadAndSettingsWritePreserveCountdownAndSupportWindowIPC() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(environment: ["XDG_CONFIG_HOME": root.appendingPathComponent("c").path,
                                   "XDG_STATE_HOME": root.appendingPathComponent("s").path], home: root.path)
    let calendar = Calendar(identifier: .gregorian)
    let host = try EngineHost(paths: paths, calendar: calendar, pid: 123, now: 1_000,
                              settingsAvailable: true, emit: { _ in })
    #expect(host.handle(IPCRequest(cmd: "settings"), now: 1_000).ok)
    #expect(host.handle(IPCRequest(cmd: "start"), now: 1_000).ok)
    var config = Config()
    config.timer.workMinutes = 30
    config.timer.dailyGoal = 10
    _ = try host.saveConfig(config, now: 1_100)
    #expect(host.snapshot().state.endsAt == 2_500)
    #expect(host.snapshot().state.dailyGoal == 10)
    #expect(try ConfigStore(url: paths.configFile).read().config.timer.workMinutes == 30)
    // Atomic replace, as performed by an editor. The host reads the replacement path.
    let replacement = paths.configDirectory.appendingPathComponent("replacement.toml")
    try "[timer]\nwork_minutes = 35\n".write(to: replacement, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: paths.configFile)
    try FileManager.default.moveItem(at: replacement, to: paths.configFile)
    let reload = host.reloadConfig(now: 1_200)
    #expect(reload.config.timer.workMinutes == 35)
    #expect(reload.state.endsAt == 2_500)
    try "[timer]\nwork_minutes = -1\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
    #expect(host.reloadConfig(now: 1_300).configError != nil)
    #expect(host.snapshot().config.timer.workMinutes == 35)
    #expect(host.snapshot().state.endsAt == 2_500)
}

@Test func invalidStartupDefaultsAreOptInAndLeaveTheFileIntact() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(environment: ["XDG_CONFIG_HOME": root.appendingPathComponent("c").path,
                                   "XDG_STATE_HOME": root.appendingPathComponent("s").path], home: root.path)
    try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
    let invalid = "[timer]\nwork_minutes = -1\n"
    try invalid.write(to: paths.configFile, atomically: true, encoding: .utf8)
    let calendar = Calendar(identifier: .gregorian)
    #expect(throws: ConfigError.self) {
        try EngineHost(paths: paths, calendar: calendar, pid: 123, now: 1_000, emit: { _ in })
    }
    let host = try EngineHost(paths: paths, calendar: calendar, pid: 123, now: 1_000,
                              settingsAvailable: true, recoverInvalidConfigAtLaunch: true, emit: { _ in })
    #expect(host.snapshot().config.timer.workMinutes == 25)
    #expect(host.snapshot().configError != nil)
    #expect(try String(contentsOf: paths.configFile, encoding: .utf8) == invalid)
}

@Test func configErrorNotificationUsesFirstLineAndOpensConfigWithoutLosingPhaseAlerts() {
    let state = State(now: 1_000, config: Config(), calendar: Calendar(identifier: .gregorian))
    let model = NotificationModel(kind: "config_error", state: state, config: Config(), detail: "First line\nSecond line")
    #expect(model.title == "Config error")
    #expect(model.body == "First line")
    #expect(model.actions.map(\.command) == [.openConfig])
    #expect(NotificationModel.command(for: "open_config") == .openConfig)
    #expect(!NotificationModel.phaseIdentifiers.contains("config_error"))
}
