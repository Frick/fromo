import AppKit
import FromoCore
import ServiceManagement
import UserNotifications
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate, NSSoundDelegate {
    private var statusItem: NSStatusItem?
    private var host: EngineHost?
    private var runner: SocketRunner?
    private var timer: Timer?
    private var panel: AnswerPanel?
    private let notifications = UNUserNotificationCenter.current()
    private let paths = Paths(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
    private var terminating = false
    private var sketchybarFailed = false
    private var playingSounds: [NSSound] = []
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var configWatcher: ConfigDirectoryWatcher?
    private var loginStatus: LoginItemStatus = .notRegistered
    private var notificationsReady = false
    private var pendingNotifications: [NotificationModel] = []

    private var now: Int { Int(Date().timeIntervalSince1970) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let server = try IPCServer(path: paths.checkedSocketPath())
            do {
                let configStore = ConfigStore(url: paths.configFile)
                if !FileManager.default.fileExists(atPath: paths.configFile.path) { try configStore.write(Config()) }
                notifications.delegate = self
                host = try EngineHost(paths: paths, calendar: .current, pid: Int(ProcessInfo.processInfo.processIdentifier), now: now,
                                      settingsAvailable: true, recoverInvalidConfigAtLaunch: true,
                                      eventSink: { [weak self] effect, snapshot in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.execute(effect, snapshot: snapshot) }
                    }
                }, emit: { _ in })
            } catch { server.close(); throw error }
            guard let host else { return }
            runner = SocketRunner(server: server, host: host) { [weak self] error in
                Task { @MainActor in self?.log(error) }
            }
            runner?.start()
            configWatcher = ConfigDirectoryWatcher(path: paths.configDirectory.path, changed: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, !self.terminating else { return }
                        _ = self.host?.reloadConfig(now: self.now)
                    }
                }
            }, report: { [weak self] message in Task { @MainActor in self?.log(message) } })
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Fromo")
            item.button?.image?.isTemplate = true
            item.button?.imagePosition = .imageLeading
            item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            item.menu = menu
            statusItem = item
            let mainMenu = NSMenu()
            let appMenu = NSMenu()
            let applicationItem = NSMenuItem()
            applicationItem.submenu = appMenu
            mainMenu.addItem(applicationItem)
            let quit = NSMenuItem(title: "Quit Fromo", action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self
            appMenu.addItem(quit)
            let settings = NSMenuItem(title: "Settings…", action: #selector(menuCommand(_:)), keyEquivalent: ",")
            settings.target = self
            settings.representedObject = CommandBox(.settings)
            appMenu.insertItem(settings, at: 0)
            let edit = NSMenu(title: "Edit")
            for (title, selector, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "z"),
                                           ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                           ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
                let item = NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key)
                if title == "Redo" { item.keyEquivalentModifierMask = [.command, .shift] }
                edit.addItem(item)
            }
            let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            editItem.submenu = edit
            mainMenu.addItem(editItem)
            NSApp.mainMenu = mainMenu
            refresh()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.host?.tick(now: self.now)
                    self.refresh()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            installNotificationCategories(host.snapshot())
            notifications.requestAuthorization(options: [.alert]) { [weak self] _, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.notificationsReady = true
                    let queued = self.pendingNotifications
                    self.pendingNotifications.removeAll()
                    queued.forEach { self.post($0) }
                }
                if let error {
                    let message = "Notification authorization: \(error)"
                    Task { @MainActor in self?.log(message) }
                }
            }
        } catch let error as IPCError where error.description == "An engine is already running." {
            log(error.description)
            NSApp.terminate(nil)
        } catch {
            log("Startup: \(error)")
            let alert = NSAlert()
            alert.messageText = "Fromo could not start"
            alert.informativeText = String(describing: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func refresh() {
        guard let snapshot = host?.snapshot() else { return }
        let model = MenuModel(state: snapshot.state, config: snapshot.config, now: now, settingsAvailable: snapshot.settingsAvailable)
        statusItem?.button?.title = model.countdown.isEmpty ? "" : " " + model.countdown
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let snapshot = host?.snapshot() else { return }
        let model = MenuModel(state: snapshot.state, config: snapshot.config, now: now, settingsAvailable: snapshot.settingsAvailable)
        menu.removeAllItems()
        for text in [model.status, model.today] {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(model.primary, to: menu)
        for action in model.controls { add(action, to: menu) }
        menu.addItem(.separator())
        add(model.lunch, to: menu)
        add(model.notToday, to: menu)
        menu.addItem(.separator())
        add(model.settings, to: menu, key: ",")
        let logs = NSMenuItem(title: "Open Log Folder", action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        let quit = NSMenuItem(title: "Quit Fromo", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func add(_ model: MenuAction, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: model.title, action: #selector(menuCommand(_:)), keyEquivalent: key)
        item.target = self
        item.isEnabled = model.enabled
        item.state = model.checked ? .on : .off
        item.representedObject = CommandBox(model.command)
        menu.addItem(item)
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox else { return }
        perform(box.command)
    }

    private func perform(_ command: Command) {
        guard let response = host?.perform(command, now: now) else { return }
        if !response.ok {
            let alert = NSAlert()
            alert.messageText = "Command unavailable"
            alert.informativeText = response.error ?? "Command rejected."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refresh()
    }

    private func execute(_ effect: Effect, snapshot: HostSnapshot) {
        switch effect {
        case .notify(let kind):
            let model = NotificationModel(kind: kind, state: snapshot.state, config: snapshot.config)
            enqueue(model)
        case .configError(let message):
            enqueue(NotificationModel(kind: "config_error", state: snapshot.state, config: snapshot.config, detail: message))
        case .clearConfigError:
            pendingNotifications.removeAll { $0.kind == "config_error" }
            notifications.removeDeliveredNotifications(withIdentifiers: ["config_error"])
            notifications.removePendingNotificationRequests(withIdentifiers: ["config_error"])
        case .configReloaded:
            settingsModel?.receive(snapshot)
            if snapshot.state.phase == .breakDone, let panel {
                panel.update(model: AnswerPanelModel(state: snapshot.state, config: snapshot.config))
            }
            refresh()
        case .logDiagnostic(let message):
            log(message)
        case .openConfig:
            NSWorkspace.shared.open(paths.configFile)
        case .showSettingsWindow:
            showSettings()
        case .playSound(let name):
            let sound = name.hasPrefix("/") ? NSSound(contentsOfFile: name, byReference: true) : NSSound(named: NSSound.Name(name))
            if let sound {
                sound.delegate = self
                playingSounds.append(sound)
                if !sound.play() { playingSounds.removeAll { $0 === sound } }
            }
        case .showAnswerPanel:
            let model = AnswerPanelModel(state: snapshot.state, config: snapshot.config)
            if panel == nil { panel = AnswerPanel(model: model) { [weak self] command in self?.perform(command) } }
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        case .hideAnswerPanel:
            panel?.dismiss()
            panel = nil
        case .clearNotifications:
            let phaseIDs = NotificationModel.phaseIdentifiers
            pendingNotifications.removeAll { phaseIDs.contains($0.kind) }
            notifications.removeDeliveredNotifications(withIdentifiers: phaseIDs)
            notifications.removePendingNotificationRequests(withIdentifiers: phaseIDs)
        case .triggerSketchyBar:
            let existing = SketchyBarInvocation.knownLocations.filter { FileManager.default.isExecutableFile(atPath: $0) }
            guard let invocation = SketchyBarInvocation(config: snapshot.config.sketchybar, existing: existing) else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: invocation.executable)
            process.arguments = invocation.arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                if status != 0 { Task { @MainActor in self?.logSketchybar("SketchyBar exited with \(status).") } }
            }
            do { try process.run() }
            catch { logSketchybar("SketchyBar trigger: \(error)") }
        case .writeState:
            refresh()
        case .setLaunchAtLogin(let enabled):
            applyLoginItem(enabled)
        default: break
        }
    }

    private func enqueue(_ model: NotificationModel) {
        if notificationsReady { post(model) }
        else { pendingNotifications.append(model) }
    }

    private func post(_ model: NotificationModel) {
        let content = UNMutableNotificationContent()
        content.title = model.title
        content.body = model.body
        content.categoryIdentifier = model.kind
        notifications.add(UNNotificationRequest(identifier: model.kind, content: content, trigger: nil)) { [weak self] error in
            if let error {
                let message = "Notification delivery: \(error)"
                Task { @MainActor in self?.log(message) }
            }
        }
    }

    private func showSettings() {
        guard let host else { return }
        loginStatus = loginItemStatus(SMAppService.mainApp.status)
        if settingsWindow == nil {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
                .filter { ["aiff", "aif", "wav", "caf"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
                .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }.sorted()
            let model = SettingsModel(snapshot: host.snapshot(), loginStatus: loginStatus, soundNames: names,
                                      save: { [weak self] candidate in
                guard let self else { throw ConfigError("Engine not running.") }
                return try host.saveConfig(candidate, now: self.now)
            }, openLoginItems: { SMAppService.openSystemSettingsLoginItems() },
                                      chooseSoundFile: { [weak self] path in self?.chooseSoundFile(path) },
                                      preview: { [weak self] name in self?.perform(.previewSound(name)) },
                                      trigger: { [weak self] in self?.perform(.testSketchyBar) })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Fromo Settings"
            window.contentMinSize = NSSize(width: 740, height: 580)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.center()
            settingsModel = model
            settingsWindow = window
        }
        settingsModel?.receive(host.snapshot())
        settingsModel?.loginStatus = loginStatus
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        loginStatus = loginItemStatus(SMAppService.mainApp.status)
        settingsModel?.loginStatus = loginStatus
    }

    private func chooseSoundFile(_ path: WritableKeyPath<Config, String>) {
        guard let window = settingsWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.settingsModel?.edit { $0[keyPath: path] = url.path }
        }
    }

    private func installNotificationCategories(_ snapshot: HostSnapshot) {
        let categories = ["work_end", "break_end", "lunch_end", "state_corrupt", "config_error"].map { kind in
            let model = NotificationModel(kind: kind, state: snapshot.state, config: snapshot.config)
            let actions = model.actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: []) }
            return UNNotificationCategory(identifier: kind, actions: actions, intentIdentifiers: [], options: [])
        }
        notifications.setNotificationCategories(Set(categories))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? "body" : response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        if let command = NotificationModel.command(for: action, category: category) {
            await MainActor.run { self.perform(command) }
        }
    }

    private func applyLoginItem(_ enabled: Bool) {
        let service = SMAppService.mainApp
        let before = loginItemStatus(service.status)
        let action = LoginItemPolicy.action(enabled: enabled, status: before)
        log("Launch at login: requested=\(enabled), before=\(before.rawValue), action=\(action.rawValue).")
        do {
            switch action {
            case .register: try service.register()
            case .unregister: try service.unregister()
            case .none: break
            }
        } catch {
            let error = error as NSError
            log("Launch at login: domain=\(error.domain), code=\(error.code), \(error.localizedDescription)")
        }
        let after = loginItemStatus(service.status)
        loginStatus = after
        settingsModel?.loginStatus = after
        log("Launch at login: after=\(after.rawValue).")
        if after == .requiresApproval { log("Launch at login requires approval in System Settings → Login Items.") }
    }

    private func loginItemStatus(_ status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        let identifier = ObjectIdentifier(sound)
        Task { @MainActor in self.playingSounds.removeAll { ObjectIdentifier($0) == identifier } }
    }

    @objc private func openLogs() {
        do {
            try FileManager.default.createDirectory(at: paths.logDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(paths.logDirectory)
        } catch { log("Open Log Folder: \(error)") }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runner, let host else { return .terminateNow }
        if terminating { return .terminateLater }
        terminating = true
        timer?.invalidate()
        configWatcher?.stop()
        _ = settingsModel?.persist(force: true)
        do { try host.stop(now: now) } catch { log("Quit: \(error)") }
        runner.stop {
            Task { @MainActor in NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    private func log(_ message: String) { try? DiagnosticsStore(url: paths.diagnosticFile).append(message) }
    private func logSketchybar(_ message: String) {
        if !sketchybarFailed { sketchybarFailed = true; log(message) }
    }
}

final class CommandBox: NSObject {
    let command: Command
    init(_ command: Command) { self.command = command }
}

final class SocketRunner: @unchecked Sendable {
    private let server: IPCServer
    private let host: EngineHost
    private let report: @Sendable (String) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var completion: (@Sendable () -> Void)?
    init(server: IPCServer, host: EngineHost, report: @escaping @Sendable (String) -> Void) {
        self.server = server; self.host = host; self.report = report
    }
    func start() {
        DispatchQueue(label: "fromo.socket").async { [self] in
            while !isStopped {
                do { try server.serveOne(timeoutMilliseconds: 100) { host.handle($0, now: Int(Date().timeIntervalSince1970)) } }
                catch { report(String(describing: error)) }
            }
            server.close()
            lock.lock(); let callback = completion; lock.unlock()
            callback?()
        }
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop(completion: @escaping @Sendable () -> Void) {
        lock.lock(); self.completion = completion; stopped = true; lock.unlock()
    }
}

@main
@MainActor
struct FromoApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
