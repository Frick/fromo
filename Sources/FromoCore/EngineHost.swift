import Foundation

public struct HostSnapshot: Sendable {
    public var state: State
    public var config: Config
    public var configError: String?
    public var settingsAvailable: Bool
}

// All engine and file-store access is confined to this queue. The socket shell passes requests only.
public final class EngineHost: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fromo.engine")
    private var engine: Engine
    private var config: Config
    private let paths: Paths
    private let calendar: Calendar
    private let emit: @Sendable (Effect) -> Void
    private let eventSink: (@Sendable (Effect, HostSnapshot) -> Void)?
    private var reloadPolicy = ConfigReloadPolicy()
    private let settingsAvailable: Bool
    private var probes: ProbeSnapshot

    public init(paths: Paths, calendar: Calendar, pid: Int, now: Int,
                settingsAvailable: Bool = false, recoverInvalidConfigAtLaunch: Bool = false,
                probes: ProbeSnapshot = ProbeSnapshot(),
                eventSink: (@Sendable (Effect, HostSnapshot) -> Void)? = nil,
                emit: @escaping @Sendable (Effect) -> Void) throws {
        self.paths = paths; self.calendar = calendar; self.emit = emit
        self.eventSink = eventSink
        self.settingsAvailable = settingsAvailable
        self.probes = probes
        var startupWarnings: [String] = []
        do {
            let document = try ConfigStore(url: paths.configFile).read()
            config = document.config
            startupWarnings = document.warnings
            _ = reloadPolicy.accept(config)
        } catch {
            if !recoverInvalidConfigAtLaunch { throw error }
            config = Config()
            _ = reloadPolicy.reject(String(describing: error))
        }
        let loaded = try StateStore(url: paths.stateFile).load(now: now, config: config, calendar: calendar)
        engine = Engine(state: loaded.state)
        try execute(engine.restore(env: environment(now), pid: pid, recovered: loaded.recovered))
        if !FileManager.default.fileExists(atPath: paths.stateFile.path) {
            try StateStore(url: paths.stateFile).write(engine.state)
        }
        for warning in startupWarnings { try execute([.logDiagnostic(warning)]) }
        if let error = reloadPolicy.error { try execute([.logDiagnostic(error), .configError(error), .configReloaded]) }
    }

    private func environment(_ now: Int) -> Environment {
        Environment(now: now, calendar: calendar, config: config, idleSeconds: probes.idleSeconds,
                    cameraInUse: probes.cameraInUse, micInUse: probes.microphoneInUse)
    }

    public func handle(_ request: IPCRequest, now: Int) -> IPCResponse {
        queue.sync {
            do {
                guard request.v == 1 else { throw IPCError("Unsupported protocol version.") }
                if request.cmd == "debug" {
                    return IPCResponse(ok: true, state: engine.state, debug: engine.debug(env: environment(now)))
                }
                try execute(engine.tick(env: environment(now)))
                if request.cmd == "ping" { return IPCResponse(ok: true, state: engine.state) }
                let command = try request.command()
                if command == .settings && !settingsAvailable { throw EngineError("Settings require the macOS app.") }
                try execute(engine.handle(command, env: environment(now)))
                return IPCResponse(ok: true, state: engine.state)
            } catch let error as EngineError {
                return IPCResponse(ok: false, code: "rejected", error: error.description)
            } catch let error as IPCError {
                return IPCResponse(ok: false, code: "usage", error: error.description)
            } catch {
                return IPCResponse(ok: false, code: "io", error: String(describing: error))
            }
        }
    }

    public func perform(_ command: Command, now: Int) -> IPCResponse {
        queue.sync {
            do {
                try execute(engine.tick(env: environment(now)))
                if command == .settings && !settingsAvailable { throw EngineError("Settings require the macOS app.") }
                try execute(engine.handle(command, env: environment(now)))
                return IPCResponse(ok: true, state: engine.state)
            } catch {
                return IPCResponse(ok: false, code: "rejected", error: String(describing: error))
            }
        }
    }

    public func snapshot() -> HostSnapshot {
        queue.sync { currentSnapshot() }
    }

    private func currentSnapshot() -> HostSnapshot {
        HostSnapshot(state: engine.state, config: config, configError: reloadPolicy.error, settingsAvailable: settingsAvailable)
    }

    public func saveConfig(_ candidate: Config, now: Int) throws -> HostSnapshot {
        try queue.sync {
            try candidate.validate()
            try ConfigStore(url: paths.configFile).write(candidate)
            try acceptConfig(candidate, warnings: [], now: now)
            return currentSnapshot()
        }
    }

    public func reloadConfig(now: Int) -> HostSnapshot {
        queue.sync {
            do {
                let document = try ConfigStore(url: paths.configFile).read()
                try acceptConfig(document.config, warnings: document.warnings, now: now)
            } catch {
                let message = String(describing: error)
                let result = reloadPolicy.reject(message)
                try? execute([.logDiagnostic(message)])
                if result.shouldNotify { try? execute([.configError(message)]) }
                try? execute([.configReloaded])
            }
            return currentSnapshot()
        }
    }

    private func acceptConfig(_ candidate: Config, warnings: [String], now: Int) throws {
        let hadError = reloadPolicy.error != nil
        let result = reloadPolicy.accept(candidate)
        config = candidate
        if result.changed { try execute(engine.handle(.reloadConfig, env: environment(now))) }
        for warning in warnings { try execute([.logDiagnostic(warning)]) }
        if hadError { try execute([.clearConfigError]) }
        if result.changed || hadError { try execute([.configReloaded]) }
    }

    public func tick(now: Int) {
        queue.sync {
            do { try execute(engine.tick(env: environment(now))) }
            catch { emit(.notify("io_error: \(error)")) }
        }
    }

    public func updateProbes(_ snapshot: ProbeSnapshot, now: Int) {
        queue.sync {
            probes = snapshot
            do { try execute(engine.tick(env: environment(now))) }
            catch { try? execute([.logDiagnostic("Probe update: \(error)")]) }
        }
    }

    public func stop(now: Int) throws {
        try queue.sync { try execute(engine.handle(.stop, env: environment(now))) }
    }

    private func execute(_ effects: [Effect]) throws {
        for effect in effects {
            switch effect {
            case .writeState(let state): try StateStore(url: paths.stateFile).write(state)
            case .appendLog(let row): try LogStore(directory: paths.logDirectory, calendar: calendar).append(row)
            default: emit(effect)
            }
            eventSink?(effect, currentSnapshot())
        }
    }
}
