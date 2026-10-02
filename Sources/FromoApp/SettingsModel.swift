import AppKit
import FromoCore
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var draft: SettingsDraft
    @Published private(set) var fileError: String?
    @Published private(set) var saveError: String?
    @Published var loginStatus: LoginItemStatus
    let soundNames: [String]
    let openLoginItems: () -> Void
    let chooseSoundFile: (WritableKeyPath<Config, String>) -> Void
    let preview: (String) -> Void
    private let save: (Config) throws -> HostSnapshot
    private let trigger: () -> Void
    private var pendingSave: DispatchWorkItem?

    var config: Config { draft.config }
    var error: String? { draft.validationError ?? saveError ?? fileError }
    private var milliseconds: Int { Int(ProcessInfo.processInfo.systemUptime * 1_000) }

    init(snapshot: HostSnapshot, loginStatus: LoginItemStatus, soundNames: [String],
         save: @escaping (Config) throws -> HostSnapshot,
         openLoginItems: @escaping () -> Void,
         chooseSoundFile: @escaping (WritableKeyPath<Config, String>) -> Void,
         preview: @escaping (String) -> Void, trigger: @escaping () -> Void) {
        draft = SettingsDraft(config: snapshot.config)
        fileError = snapshot.configError
        self.loginStatus = loginStatus
        self.soundNames = soundNames
        self.save = save; self.openLoginItems = openLoginItems
        self.chooseSoundFile = chooseSoundFile; self.preview = preview; self.trigger = trigger
    }

    func binding<Value>(_ path: WritableKeyPath<Config, Value>) -> Binding<Value> {
        Binding(get: { self.config[keyPath: path] }, set: { value in self.edit { $0[keyPath: path] = value } })
    }

    func edit(_ change: (inout Config) -> Void) {
        pendingSave?.cancel()
        var candidate = config
        change(&candidate)
        draft.edit(candidate, nowMilliseconds: milliseconds)
        saveError = nil
        guard draft.validationError == nil else { return }
        let work = DispatchWorkItem(qos: .unspecified, flags: []) { [weak self] in
            MainActor.assumeIsolated { _ = self?.persist(force: false) }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
    }

    func receive(_ snapshot: HostSnapshot) {
        fileError = snapshot.configError
        if draft.receive(snapshot.config) {
            pendingSave?.cancel()
            saveError = nil
        }
    }

    @discardableResult
    func persist(force: Bool) -> Bool {
        if force { pendingSave?.cancel() }
        guard let candidate = draft.takeWrite(nowMilliseconds: milliseconds, force: force) else { return draft.validationError == nil }
        do {
            let snapshot = try save(candidate)
            draft.didSave(candidate)
            fileError = snapshot.configError
            saveError = nil
            return true
        } catch {
            saveError = String(describing: error)
            return false
        }
    }

    func sendTestTrigger() { if persist(force: true) { trigger() } }
}
