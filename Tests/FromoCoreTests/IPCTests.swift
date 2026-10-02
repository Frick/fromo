import Foundation
import FromoCore
import Testing

@Test func protocolMapsEveryControlVerbAndRejectsMalformedArguments() throws {
    let commands: [(String, Command)] = [
        ("start", .start), ("start_break", .startBreak), ("pause", .pause), ("resume", .resume),
        ("toggle", .toggle), ("next", .next), ("restart", .restart), ("reset", .reset),
        ("end_break", .endBreak), ("extend", .extend(nil)), ("lunch", .lunch(nil)),
        ("end_lunch", .endLunch), ("settings", .settings),
    ]
    for (verb, command) in commands {
        #expect(try IPCRequest(cmd: verb).command() == command)
    }
    #expect(try IPCRequest(cmd: "extend", args: .init(minutes: 5)).command() == .extend(5))
    #expect(try IPCRequest(cmd: "answer", args: .init(did: true, startNext: false)).command() == .answer(.didSuggested, startNext: false))
    #expect(try IPCRequest(cmd: "answer", args: .init(other: "Other")).command() == .answer(.other("Other"), startNext: true))
    #expect(throws: IPCError.self) { try IPCRequest(v: 2, cmd: "start").command() }
    #expect(throws: IPCError.self) { try IPCRequest(cmd: "unknown").command() }
    #expect(throws: IPCError.self) { try IPCRequest(cmd: "answer").command() }
    #expect(throws: IPCError.self) { try IPCRequest(cmd: "extend", args: .init(minutes: Int.max)).command() }
}

@Test func socketRoundTripSingleInstanceAndStaleRecovery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("fromo.sock").path
    let server = try IPCServer(path: path)
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    #expect(throws: IPCError.self) { try IPCServer(path: path) }
    let completion = DispatchSemaphore(value: 0)
    DispatchQueue(label: "ipc-test").async {
        defer { completion.signal() }
        while (try? server.serveOne(timeoutMilliseconds: 2_000, handler: { request in
            IPCResponse(ok: request.cmd == "ping")
        })) == false {
        }
    }
    let response = try IPCClient.request(IPCRequest(cmd: "ping"), path: path)
    #expect(response.ok)
    completion.wait()
    server.close(removeSocket: false)
    let recovered = try IPCServer(path: path)
    recovered.close()
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func engineHostUsesInjectedClockForSocketCommands() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(environment: ["XDG_CONFIG_HOME": root.appendingPathComponent("c").path,
                                   "XDG_STATE_HOME": root.appendingPathComponent("s").path], home: root.path)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let host = try EngineHost(paths: paths, calendar: calendar, pid: 99, now: 1_000, emit: { _ in })
    #expect(host.handle(IPCRequest(cmd: "start"), now: 1_000).ok)
    #expect(host.handle(IPCRequest(cmd: "start"), now: 1_001).code == "rejected")
    host.tick(now: 2_500)
    #expect(host.handle(IPCRequest(cmd: "start_break"), now: 2_501).state?.task == "Pushups")
    #expect(host.handle(IPCRequest(cmd: "end_break"), now: 2_502).ok)
    #expect(host.handle(IPCRequest(cmd: "answer", args: .init(did: true, startNext: false)), now: 2_503).state?.phase == .ready)
    #expect(try StateStore(url: paths.stateFile).read().rotation.short.name == "Squats")
    #expect(host.handle(IPCRequest(cmd: "settings"), now: 2_504).code == "rejected")
}
