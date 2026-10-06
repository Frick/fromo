import Foundation

public enum Phase: String, Codable, Sendable {
    case ready, work, workDone = "work_done", `break`, breakDone = "break_done"
    case paused, lunch, stopped
}

public enum BreakKind: String, Codable, Sendable { case short, long }

public struct RotationPosition: Codable, Equatable, Sendable {
    public var index: Int
    public var name: String?
    public init(index: Int = 0, name: String? = nil) {
        self.index = index
        self.name = name
    }
    enum CodingKeys: String, CodingKey { case index, name }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        if let name { try container.encode(name, forKey: .name) }
        else { try container.encodeNil(forKey: .name) }
    }
    public mutating func reconcile(_ list: [String]) {
        guard !list.isEmpty else { index = 0; name = nil; return }
        if let name, let found = list.firstIndex(of: name) { index = found }
        else { index = min(max(index, 0), list.count - 1) }
        name = list[index]
    }
    public mutating func advance(_ list: [String]) {
        guard !list.isEmpty else { return }
        index = (index + 1) % list.count
        name = list[index]
    }
}

public struct Rotation: Codable, Equatable, Sendable {
    public var short: RotationPosition
    public var long: RotationPosition
    public init(config: Config) {
        short = RotationPosition(); short.reconcile(config.breaks.short)
        long = RotationPosition(); long.reconcile(config.breaks.long)
    }
}

public struct LunchState: Codable, Equatable, Sendable {
    public var endsAt: Int
    public var returnPhase: Phase
    public var returnRemaining: Int?
    public var returnPhaseEnteredAt: Int

    public init(endsAt: Int, returnPhase: Phase, returnRemaining: Int?, returnPhaseEnteredAt: Int) {
        self.endsAt = endsAt
        self.returnPhase = returnPhase
        self.returnRemaining = returnRemaining
        self.returnPhaseEnteredAt = returnPhaseEnteredAt
    }

    enum CodingKeys: String, CodingKey { case endsAt, returnPhase, returnRemaining, returnPhaseEnteredAt }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endsAt, forKey: .endsAt)
        try container.encode(returnPhase, forKey: .returnPhase)
        if let returnRemaining { try container.encode(returnRemaining, forKey: .returnRemaining) }
        else { try container.encodeNil(forKey: .returnRemaining) }
        try container.encode(returnPhaseEnteredAt, forKey: .returnPhaseEnteredAt)
    }
}

public struct NagCursor: Codable, Equatable, Sendable {
    public var unused = 0
    public var waiting = 0
    public init() {}
}

public struct State: Codable, Equatable, Sendable {
    public var version = 1
    public var pid: Int
    public var updatedAt: Int
    public var date: String
    public var phase: Phase = .ready
    public var breakKind: BreakKind?
    public var startedAt: Int?
    public var endsAt: Int?
    public var endedAt: Int?
    public var pausedPhase: Phase?
    public var remaining: Int?
    public var task: String?
    public var nextTask: String? = nil
    public var lunch: LunchState?
    public var completedToday = 0
    public var dailyGoal: Int
    public var cycleCount = 0
    public var rotation: Rotation
    public var inMeeting = false
    public var nagsOffUntil: Int?
    public var phaseEnteredAt: Int
    public var lastNagAt: Int?
    public var nagCursor = NagCursor()
    // A resumed or extended session needs its final planned length for CSV logging.
    public var plannedSeconds: Int?
    public var stoppedPhase: Phase?
    public var workdayDate: String?
    public var dayOpenedAt: Int?
    public var dayClosedAt: Int?

    enum CodingKeys: String, CodingKey {
        case version, pid, updatedAt, date, phase, breakKind, startedAt, endsAt, endedAt
        case pausedPhase, remaining, task, nextTask, lunch, completedToday, dailyGoal
        case cycleCount, rotation, inMeeting, nagsOffUntil, phaseEnteredAt, lastNagAt
        case nagCursor, plannedSeconds, stoppedPhase, workdayDate, dayOpenedAt, dayClosedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(pid, forKey: .pid)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(date, forKey: .date)
        try container.encode(phase, forKey: .phase)
        try container.encode(completedToday, forKey: .completedToday)
        try container.encode(dailyGoal, forKey: .dailyGoal)
        try container.encode(cycleCount, forKey: .cycleCount)
        try container.encode(rotation, forKey: .rotation)
        try container.encode(inMeeting, forKey: .inMeeting)
        try container.encode(phaseEnteredAt, forKey: .phaseEnteredAt)
        try container.encode(nagCursor, forKey: .nagCursor)

        func nullable<T: Encodable>(_ value: T?, _ key: CodingKeys) throws {
            if let value { try container.encode(value, forKey: key) }
            else { try container.encodeNil(forKey: key) }
        }
        try nullable(breakKind, .breakKind)
        try nullable(startedAt, .startedAt)
        try nullable(endsAt, .endsAt)
        try nullable(endedAt, .endedAt)
        try nullable(pausedPhase, .pausedPhase)
        try nullable(remaining, .remaining)
        try nullable(task, .task)
        try nullable(nextTask, .nextTask)
        try nullable(lunch, .lunch)
        try nullable(nagsOffUntil, .nagsOffUntil)
        try nullable(lastNagAt, .lastNagAt)
        try nullable(plannedSeconds, .plannedSeconds)
        try nullable(stoppedPhase, .stoppedPhase)
        try nullable(workdayDate, .workdayDate)
        try nullable(dayOpenedAt, .dayOpenedAt)
        try nullable(dayClosedAt, .dayClosedAt)
    }

    public init(now: Int, config: Config, calendar: Calendar, pid: Int = 0) {
        self.pid = pid
        self.updatedAt = now
        self.date = Self.localDate(now, calendar: calendar)
        self.workdayDate = self.date
        self.dayOpenedAt = now
        self.dailyGoal = config.timer.dailyGoal
        self.rotation = Rotation(config: config)
        self.phaseEnteredAt = now
        self.updateNextTask(config: config)
    }

    public static func localDate(_ timestamp: Int, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public mutating func updateNextTask(config: Config) {
        let waitingForBreak = phase == .workDone || (phase == .lunch && lunch?.returnPhase == .workDone)
        let count: Int
        if waitingForBreak { count = cycleCount }
        else if breakKind == .long && [.break, .breakDone, .paused, .lunch].contains(phase) { count = 1 }
        else { count = cycleCount + 1 }
        nextTask = (count >= config.timer.longBreakEvery ? rotation.long : rotation.short).name
    }

    public func validateForEngine() throws {
        func require(_ valid: Bool) throws {
            if !valid { throw EngineError("Invalid persisted timer state.") }
        }
        try require(version == 1 && completedToday >= 0 && completedToday < Int.max && cycleCount >= 0 && cycleCount < Int.max)
        let active = phase == .stopped ? (stoppedPhase ?? .ready) : phase
        try require(active != .stopped)
        switch active {
        case .work, .break:
            try require(startedAt != nil && endsAt != nil && plannedSeconds != nil)
        case .workDone, .breakDone:
            try require(startedAt != nil && endedAt != nil && plannedSeconds != nil)
        case .paused:
            try require(pausedPhase == .work || pausedPhase == .break)
            try require(startedAt != nil && remaining != nil && plannedSeconds != nil)
        case .lunch:
            try require(lunch != nil)
            if let lunch {
                try require(lunch.returnPhase != .lunch && lunch.returnPhase != .stopped)
                if [.work, .break, .paused].contains(lunch.returnPhase) {
                    try require(lunch.returnRemaining != nil && startedAt != nil && plannedSeconds != nil)
                }
                if lunch.returnPhase == .paused { try require(pausedPhase == .work || pausedPhase == .break) }
                if [.workDone, .breakDone].contains(lunch.returnPhase) {
                    try require(startedAt != nil && endedAt != nil && plannedSeconds != nil)
                }
            }
        default: break
        }
        try require((remaining ?? 0) >= 0 && (plannedSeconds ?? 0) >= 0)
        if active == .break || active == .breakDone || (active == .paused && pausedPhase == .break) {
            try require(breakKind != nil)
        }
    }
}
