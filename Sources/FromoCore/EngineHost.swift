import Foundation

// All engine and file-store access is confined to this queue. The socket shell passes requests only.
public final class EngineHost: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fromo.engine")
    private var engine: Engine
    private var config: Config
    private let paths: Paths
    private let calendar: Calendar
    private let emit: @Sendable (Effect) -> Void

    public init(paths: Paths, calendar: Calendar, pid: Int, now: Int, emit: @escaping @Sendable (Effect) -> Void) throws {
        self.paths = paths; self.calendar = calendar; self.emit = emit
        config = try ConfigStore(url: paths.configFile).read().config
        let loaded = try StateStore(url: paths.stateFile).load(now: now, config: config, calendar: calendar)
        engine = Engine(state: loaded.state)
        try execute(engine.restore(env: environment(now), pid: pid, recovered: loaded.recovered))
        if !FileManager.default.fileExists(atPath: paths.stateFile.path) {
            try StateStore(url: paths.stateFile).write(engine.state)
        }
    }

    private func environment(_ now: Int) -> Environment {
        Environment(now: now, calendar: calendar, config: config)
    }

    public func handle(_ request: IPCRequest, now: Int) -> IPCResponse {
        queue.sync {
            do {
                guard request.v == 1 else { throw IPCError("Unsupported protocol version.") }
                try execute(engine.tick(env: environment(now)))
                if request.cmd == "ping" { return IPCResponse(ok: true, state: engine.state) }
                let command = try request.command()
                if command == .settings { throw EngineError("Settings require the macOS app.") }
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

    public func tick(now: Int) {
        queue.sync {
            do { try execute(engine.tick(env: environment(now))) }
            catch { emit(.notify("io_error: \(error)")) }
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
        }
    }
}
