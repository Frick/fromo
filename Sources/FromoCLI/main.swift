import ArgumentParser
import Foundation
import FromoCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct CLIFailure: Error {
    let message: String
    let code: Int32
}

func terminate(_ code: Int32) -> Never { exit(code) }

func paths() -> Paths {
    Paths(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
}

func control(_ verb: String, args: IPCArguments? = nil) throws {
    let response: IPCResponse
    do { response = try IPCClient.request(IPCRequest(cmd: verb, args: args), path: paths().checkedSocketPath()) }
    catch { throw CLIFailure(message: String(describing: error), code: 2) }
    if !response.ok {
        throw CLIFailure(message: response.error ?? "Command failed.", code: response.code == "usage" ? 64 : 1)
    }
}

@main
struct Fromo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fromo", abstract: "Control the Fromo Pomodoro timer.", version: FromoVersion.current,
        subcommands: [Start.self, StartBreak.self, Pause.self, Resume.self, Toggle.self, Next.self,
                      Restart.self, Extend.self, EndBreak.self, Reset.self, Lunch.self, NotToday.self,
                      AnswerCommand.self, Status.self, StatsCommand.self, ConfigCommand.self,
                      Settings.self, Headless.self]
    )

    static func main() {
        do {
            var command = try parseAsRoot()
            try command.run()
        } catch let error as CLIFailure {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            terminate(error.code)
        } catch let error as ConfigError {
            FileHandle.standardError.write(Data((error.description + "\n").utf8))
            terminate(3)
        } catch { Fromo.exit(withError: error) }
    }

    mutating func run() throws { throw CleanExit.helpRequest(self) }
}

protocol SimpleControl: ParsableCommand { static var verb: String { get } }
extension SimpleControl { mutating func run() throws { try control(Self.verb) } }
struct Start: SimpleControl { static let verb = "start" }
struct StartBreak: SimpleControl {
    static let configuration = CommandConfiguration(commandName: "break")
    static let verb = "start_break"
}
struct Pause: SimpleControl { static let verb = "pause" }
struct Resume: SimpleControl { static let verb = "resume" }
struct Toggle: SimpleControl { static let verb = "toggle" }
struct Next: SimpleControl { static let verb = "next" }
struct Restart: SimpleControl { static let verb = "restart" }
struct EndBreak: SimpleControl { static let verb = "end_break" }
struct Reset: SimpleControl { static let verb = "reset" }
struct Settings: SimpleControl { static let verb = "settings" }

struct Extend: ParsableCommand {
    @Argument(help: "Minutes to add; defaults to timer.extend_minutes.") var minutes: Int?
    mutating func validate() throws { try validMinutes(minutes) }
    mutating func run() throws { try control("extend", args: IPCArguments(minutes: minutes)) }
}

func validMinutes(_ minutes: Int?) throws {
    if let minutes, minutes <= 0 || minutes > Int.max / 60 { throw ValidationError("Minutes must be positive and fit in seconds.") }
}

struct Lunch: ParsableCommand {
    @Argument(help: "Lunch duration in minutes.") var minutes: Int?
    @Flag(help: "End lunch and restore the previous phase.") var end = false
    mutating func validate() throws {
        try validMinutes(minutes)
        if end && minutes != nil { throw ValidationError("--end cannot be combined with minutes.") }
    }
    mutating func run() throws { try control(end ? "end_lunch" : "lunch", args: IPCArguments(minutes: minutes)) }
}

struct NotToday: ParsableCommand {
    @Flag(help: "Enable nags again.") var off = false
    mutating func run() throws { try control("not_today", args: IPCArguments(on: !off)) }
}

struct AnswerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "answer")
    @Argument(help: "Item from breaks.other.") var other: String?
    @Flag(help: "The suggested task was done.") var did = false
    @Flag(help: "Start the next work session (default).") var start = false
    @Flag(help: "Return to ready instead of starting work.") var noStart = false
    mutating func validate() throws {
        if did == (other != nil) { throw ValidationError("Choose --did or one other item.") }
        if start && noStart { throw ValidationError("Choose either --start or --no-start.") }
    }
    mutating func run() throws { try control("answer", args: IPCArguments(did: did, other: other, startNext: !noStart)) }
}

struct Status: ParsableCommand {
    @Flag(help: "Print raw state JSON.") var json = false
    @Flag(help: "Ask the engine for probe and nag details.") var debug = false
    mutating func run() throws {
        if debug { try control("debug"); return }
        let store = StateStore(url: paths().stateFile)
        guard let state = try? store.read(), state.phase != .stopped, processIsRunning(state.pid) else {
            print(json ? "{\"running\":false}" : "not running")
            return
        }
        if json { print(try String(contentsOf: store.url, encoding: .utf8), terminator: "") }
        else { print(StatePresentation.summary(state, now: Int(Date().timeIntervalSince1970))) }
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", subcommands: [ConfigPath.self, ConfigValidate.self])
}
struct ConfigPath: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "path")
    mutating func run() throws { print(paths().configFile.path) }
}
struct ConfigValidate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate")
    mutating func run() throws {
        let result = try ConfigStore(url: paths().configFile).read()
        for warning in result.warnings { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
        print("Config valid.")
    }
}

struct StatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stats", abstract: "Statistics (available in M6).")
    @Flag var today = false
    @Flag var week = false
    @Flag var month = false
    @Option var from: String?
    @Option var to: String?
    @Flag var json = false
    mutating func run() throws { throw CLIFailure(message: "Stats are available in milestone M6.", code: 1) }
}

struct Headless: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "engine", shouldDisplay: false)
    @Flag(help: "Run the engine without macOS UI; requires temporary XDG directories.") var headless = false
    @Option(help: .hidden) var now: Int?
    mutating func validate() throws {
        if !headless { throw ValidationError("Use engine --headless.") }
    }
    mutating func run() throws {
        let variables = ProcessInfo.processInfo.environment
        for key in ["XDG_CONFIG_HOME", "XDG_STATE_HOME"] {
            guard let path = variables[key],
                  URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/") else {
                throw CLIFailure(message: "Headless mode requires \(key) inside the temporary directory.", code: 64)
            }
        }
        let fixed = now
        let clock: () -> Int = { fixed ?? Int(Date().timeIntervalSince1970) }
        let server: IPCServer
        do { server = try IPCServer(path: paths().checkedSocketPath()) }
        catch { throw CLIFailure(message: String(describing: error), code: 2) }
        defer { server.close() }
        let host = try EngineHost(paths: paths(), calendar: .current, pid: Int(getpid()), now: clock()) { effect in
            let event: [String: String]
            switch effect {
            case .notify(let kind): event = ["effect": "notify", "kind": kind]
            case .playSound(let name): event = ["effect": "play_sound", "name": name]
            case .showAnswerPanel: event = ["effect": "show_answer_panel"]
            case .hideAnswerPanel: event = ["effect": "hide_answer_panel"]
            case .triggerSketchyBar: event = ["effect": "trigger_sketchybar"]
            case .showSettingsWindow: event = ["effect": "show_settings_window"]
            default: return
            }
            if let data = try? IPCCodec.encode(event) { FileHandle.standardOutput.write(data) }
        }
        let stop = StopFlag()
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { stop.set() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        FileHandle.standardOutput.write(Data("{\"effect\":\"listening\"}\n".utf8))
        while !stop.value {
            host.tick(now: clock())
            do { try server.serveOne { host.handle($0, now: clock()) } }
            catch { FileHandle.standardError.write(Data(("\(error)\n").utf8)) }
        }
        try host.stop(now: clock())
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func set() { lock.lock(); stopped = true; lock.unlock() }
}
