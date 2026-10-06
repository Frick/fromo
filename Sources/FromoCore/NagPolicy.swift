import Foundation

public struct ProbeSnapshot: Equatable, Sendable {
    public var idleSeconds: Int
    public var cameraInUse: Bool
    public var microphoneInUse: Bool
    public init(idleSeconds: Int = 0, cameraInUse: Bool = false, microphoneInUse: Bool = false) {
        self.idleSeconds = max(0, idleSeconds)
        self.cameraInUse = cameraInUse
        self.microphoneInUse = microphoneInUse
    }
}

public struct ProbeSchedule: Sendable {
    private var lastRefresh: Int?
    public init() {}
    public mutating func shouldRefresh(at now: Int) -> Bool {
        if let lastRefresh, now >= lastRefresh && now - lastRefresh < 5 { return false }
        lastRefresh = now
        return true
    }
}

public struct NagEvaluation: Sendable {
    public var eligible: Bool
    public var due: Bool
    public var message: String?
    public var nextNagAt: Int?
    public var cooldownSuppressed: Bool
    public var reasons: [String]
}

public enum NagPolicy {
    public static func inWorkHours(env: Environment) -> Bool {
        let components = env.calendar.dateComponents([.weekday, .hour, .minute, .second],
                                                      from: Date(timeIntervalSince1970: TimeInterval(env.now)))
        guard let weekday = components.weekday, (1...7).contains(weekday) else { return false }
        let day = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"][weekday - 1]
        guard let window = env.config.workHours[day], window.count == 2 else { return false }
        func seconds(_ text: String) -> Int? {
            let values = text.split(separator: ":").compactMap { Int($0) }
            guard values.count == 2 else { return nil }
            return values[0] * 3_600 + values[1] * 60
        }
        guard let start = seconds(window[0]), let end = seconds(window[1]) else { return false }
        let now = (components.hour ?? 0) * 3_600 + (components.minute ?? 0) * 60 + (components.second ?? 0)
        return start <= now && now < end
    }

    public static func evaluate(state: State, env: Environment, lastSuppressedAt: Int?) -> NagEvaluation {
        var reasons: [String] = []
        if !env.config.nags.enabled { reasons.append("nags disabled") }
        if state.dayClosedAt != nil { reasons.append("day is closed") }
        if let until = state.nagsOffUntil, until > env.now { reasons.append("Not Today") }
        if !inWorkHours(env: env) { reasons.append("outside work hours") }
        if Double(env.idleSeconds) >= Double(env.config.nags.idleThresholdMinutes) * 60 { reasons.append("idle") }
        if state.inMeeting { reasons.append("in a meeting") }
        let cooldownSuppressed = !reasons.isEmpty
        let waiting = [Phase.workDone, .breakDone, .paused].contains(state.phase)
        if state.phase != .ready && !waiting { reasons.append("phase is not unused or waiting") }
        let messages = state.phase == .ready ? env.config.nags.unused : env.config.nags.waiting
        if messages.isEmpty { reasons.append("message list is empty") }
        let eligible = reasons.isEmpty
        let baseline = max(state.phaseEnteredAt, state.lastNagAt ?? state.phaseEnteredAt,
                           lastSuppressedAt ?? state.phaseEnteredAt)
        let (deadline, overflow) = baseline.addingReportingOverflow(env.config.nags.intervalMinutes * 60)
        let next = overflow ? Int.max : deadline
        let due = eligible && env.now >= next
        let cursor = state.phase == .ready ? state.nagCursor.unused : state.nagCursor.waiting
        let index = messages.isEmpty ? 0 : max(0, cursor) % messages.count
        return NagEvaluation(eligible: eligible, due: due, message: due ? messages[index] : nil,
                             nextNagAt: eligible ? next : nil, cooldownSuppressed: cooldownSuppressed, reasons: reasons)
    }
}

public struct EngineDebug: Codable, Sendable {
    public var phase: Phase
    public var idleSeconds: Int
    public var cameraInUse: Bool
    public var microphoneInUse: Bool
    public var inMeeting: Bool
    public var inWorkHours: Bool
    public var nagEligible: Bool
    public var nagDue: Bool
    public var nextNagAt: Int?
    public var lastSuppressedAt: Int?
    public var reasons: [String]
    public var workdayDate: String?
    public var dayClosedAt: Int?
    public var dayEndIdleMinutes: Int?

    public var summary: String {
        """
        Phase: \(phase.rawValue)
        Idle seconds: \(idleSeconds)
        Camera in use: \(cameraInUse)
        Microphone in use: \(microphoneInUse)
        In meeting: \(inMeeting)
        In work hours: \(inWorkHours)
        Nag eligible: \(nagEligible)
        Nag due: \(nagDue)
        Next nag (epoch): \(nextNagAt.map(String.init) ?? "none")
        Suppression: \(reasons.isEmpty ? "none" : reasons.joined(separator: ", "))
        Workday: \(workdayDate ?? "unknown")
        Day closed: \(dayClosedAt != nil)
        End-day idle minutes: \(dayEndIdleMinutes.map(String.init) ?? "unknown")
        """
    }
}
