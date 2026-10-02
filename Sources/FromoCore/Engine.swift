import Foundation

public struct Environment: Sendable {
    public var now: Int
    public var calendar: Calendar
    public var idleSeconds: Int
    public var cameraInUse: Bool
    public var micInUse: Bool
    public var config: Config

    public init(now: Int, calendar: Calendar, config: Config, idleSeconds: Int = 0,
                cameraInUse: Bool = false, micInUse: Bool = false) {
        self.now = now
        self.calendar = calendar
        self.config = config
        self.idleSeconds = idleSeconds
        self.cameraInUse = cameraInUse
        self.micInUse = micInUse
    }
}

public enum Answer: Equatable, Sendable {
    case didSuggested, other(String)
}

public enum Command: Equatable, Sendable {
    case start, startBreak, pause, resume, toggle, next, restart, reset, endBreak
    case extend(Int?), lunch(Int?), endLunch, notToday(Bool)
    case answer(Answer, startNext: Bool)
    case reloadConfig, settings, stop
}

public struct EngineError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum Effect: Equatable, Sendable {
    case writeState(State)
    case appendLog(LogRow)
    case notify(String)
    case playSound(String)
    case showAnswerPanel, hideAnswerPanel, showSettingsWindow, triggerSketchyBar
}

public struct Engine: Sendable {
    public private(set) var state: State
    private var meetingQuietSince: Int? = nil

    public init(now: Int, config: Config, calendar: Calendar, pid: Int = 0) {
        state = State(now: now, config: config, calendar: calendar, pid: pid)
    }

    public init(state: State) { self.state = state }

    public mutating func restore(env: Environment, pid: Int? = nil, recovered: Bool = false) -> [Effect] {
        var effects: [Effect] = []
        if state.phase == .stopped {
            state.phase = state.stoppedPhase ?? .ready
            state.stoppedPhase = nil
            effects += changed(at: env.now)
        }
        if let pid, pid != state.pid {
            state.pid = pid
            effects += changed(at: env.now)
        }
        if recovered {
            effects.append(.notify("state_corrupt"))
            if pid == nil { effects += changed(at: env.now) }
        }
        effects += tick(env: env)
        if state.phase == .breakDone && !state.inMeeting && !effects.contains(.showAnswerPanel) {
            effects.append(.showAnswerPanel)
        }
        return effects
    }

    public mutating func tick(env: Environment) -> [Effect] {
        var effects: [Effect] = []
        let detected = (env.config.meetings.camera && env.cameraInUse)
            || (env.config.meetings.microphone && env.micInUse)
        if detected {
            meetingQuietSince = nil
            if !state.inMeeting {
                state.inMeeting = true
                if state.phase == .breakDone { effects.append(.hideAnswerPanel) }
                effects += changed(at: env.now)
            }
        } else if state.inMeeting {
            if let quietSince = meetingQuietSince {
                if env.now - quietSince >= 30 {
                    state.inMeeting = false
                    meetingQuietSince = nil
                    if state.phase == .breakDone { effects.append(.showAnswerPanel) }
                    effects += changed(at: env.now)
                }
            } else { meetingQuietSince = env.now }
        }
        let date = State.localDate(env.now, calendar: env.calendar)
        if date != state.date {
            state.date = date
            state.completedToday = 0
            state.cycleCount = 0
            state.nagsOffUntil = nil
            state.updateNextTask(config: env.config)
            effects += changed(at: env.now)
        }
        switch state.phase {
        case .work where (state.endsAt ?? Int.max) <= env.now:
            let deadline = state.endsAt!
            effects.append(.appendLog(row(kind: "work", outcome: "completed", end: deadline)))
            state.phase = .workDone
            state.completedToday += 1
            state.cycleCount += 1
            state.endsAt = nil
            state.endedAt = deadline
            state.phaseEnteredAt = deadline
            state.updateNextTask(config: env.config)
            effects += [.notify("work_end")]
            effects += sound("work_end", config: env.config)
            effects += changed(at: env.now)
        case .break where (state.endsAt ?? Int.max) <= env.now:
            effects += endBreak(at: state.endsAt!, env: env)
        case .lunch where (state.lunch?.endsAt ?? Int.max) <= env.now:
            effects += finishLunch(at: state.lunch!.endsAt, env: env, early: false)
        default: break
        }
        return effects
    }

    public mutating func handle(_ cmd: Command, env: Environment) throws -> [Effect] {
        let now = env.now
        let config = env.config
        var effects: [Effect] = []
        switch cmd {
        case .start where state.phase == .ready:
            begin(.work, duration: config.timer.workMinutes * 60, now: now)
        case .startBreak where state.phase == .workDone:
            let kind: BreakKind = state.cycleCount >= config.timer.longBreakEvery ? .long : .short
            state.breakKind = kind
            state.task = kind == .long ? state.rotation.long.name : state.rotation.short.name
            begin(.break, duration: (kind == .long ? config.timer.longBreakMinutes : config.timer.shortBreakMinutes) * 60, now: now)
        case .pause where state.phase == .work || state.phase == .break:
            state.pausedPhase = state.phase
            state.remaining = max(0, state.endsAt! - now)
            state.endsAt = nil
            state.phase = .paused
            state.phaseEnteredAt = now
        case .resume where state.phase == .paused:
            state.phase = state.pausedPhase!
            state.endsAt = now + state.remaining!
            state.remaining = nil
            state.pausedPhase = nil
            state.phaseEnteredAt = now
        case .toggle:
            if state.phase == .paused { return try handle(.resume, env: env) }
            if state.phase == .work || state.phase == .break { return try handle(.pause, env: env) }
            throw EngineError("No countdown to pause or resume.")
        case .next:
            switch state.phase {
            case .ready: return try handle(.start, env: env)
            case .workDone: return try handle(.startBreak, env: env)
            case .paused: return try handle(.resume, env: env)
            case .lunch: return try handle(.endLunch, env: env)
            case .breakDone: return state.inMeeting ? [] : [.showAnswerPanel]
            default: throw EngineError("No next action while the countdown is running.")
            }
        case .restart where state.phase == .work || state.phase == .break || state.phase == .paused:
            let running = state.phase == .paused ? state.pausedPhase! : state.phase
            let minutes: Int
            if running == .work { minutes = config.timer.workMinutes }
            else { minutes = state.breakKind == .long ? config.timer.longBreakMinutes : config.timer.shortBreakMinutes }
            begin(running, duration: minutes * 60, now: now)
        case .extend(let requested) where state.phase == .work || state.phase == .break:
            let minutes = requested ?? config.timer.extendMinutes
            guard minutes > 0 else { throw EngineError("Extension must be positive.") }
            state.endsAt! += minutes * 60
            state.plannedSeconds! += minutes * 60
        case .reset where state.phase == .work || (state.phase == .paused && state.pausedPhase == .work):
            effects.append(.appendLog(row(kind: "work", outcome: "abandoned", end: now)))
            clearCountdown()
            state.phase = .ready
            state.phaseEnteredAt = now
        case .endBreak where state.phase == .break || (state.phase == .paused && state.pausedPhase == .break):
            return endBreak(at: now, env: env)
        case .answer(let answer, let startNext) where state.phase == .breakDone:
            let actual: String
            let outcome: String
            switch answer {
            case .didSuggested:
                guard let task = state.task else { throw EngineError("This break has no suggested task.") }
                actual = task
                outcome = "did_suggested"
                if state.breakKind == .long { state.rotation.long.advance(config.breaks.long) }
                else { state.rotation.short.advance(config.breaks.short) }
            case .other(let choice):
                let options = config.breaks.other.isEmpty ? ["Other"] : config.breaks.other
                guard let selected = options.first(where: { $0.caseInsensitiveCompare(choice) == .orderedSame }) else {
                    throw EngineError("Choose one of: \(options.joined(separator: ", ")).")
                }
                actual = selected
                outcome = "did_other"
            }
            effects.append(.appendLog(row(kind: state.breakKind == .long ? "long_break" : "short_break", outcome: outcome,
                                          end: state.endedAt!, suggested: state.task, actual: actual)))
            if state.breakKind == .long { state.cycleCount = 0 }
            clearCountdown()
            state.phase = .ready
            state.phaseEnteredAt = now
            state.updateNextTask(config: config)
            effects.append(.hideAnswerPanel)
            if startNext { begin(.work, duration: config.timer.workMinutes * 60, now: now) }
        case .lunch(let requested) where state.phase != .lunch && state.phase != .stopped:
            let minutes = requested ?? config.timer.lunchMinutes
            guard minutes > 0 else { throw EngineError("Lunch duration must be positive.") }
            let prior = state.phase
            let remaining = (prior == .work || prior == .break) ? max(0, state.endsAt! - now) : state.remaining
            state.lunch = LunchState(endsAt: now + minutes * 60, returnPhase: prior,
                                     returnRemaining: remaining, returnPhaseEnteredAt: state.phaseEnteredAt)
            state.phase = .lunch
            state.endsAt = nil
            state.remaining = nil
            state.phaseEnteredAt = now
            if prior == .breakDone { effects.append(.hideAnswerPanel) }
        case .endLunch where state.phase == .lunch:
            return finishLunch(at: now, env: env, early: true)
        case .notToday(let on):
            if on {
                let nextDay = env.calendar.date(byAdding: .day, value: 1, to: env.calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now))))!
                state.nagsOffUntil = Int(nextDay.timeIntervalSince1970)
            } else { state.nagsOffUntil = nil }
        case .reloadConfig:
            state.rotation.short.reconcile(config.breaks.short)
            state.rotation.long.reconcile(config.breaks.long)
            state.dailyGoal = config.timer.dailyGoal
            state.updateNextTask(config: config)
        case .settings:
            return [.showSettingsWindow]
        case .stop:
            state.stoppedPhase = state.phase
            state.phase = .stopped
            state.pid = 0
        default:
            throw EngineError(state.phase == .breakDone ? "Answer the break prompt first." : "Command not available in \(state.phase.rawValue).")
        }
        effects += changed(at: now)
        return effects
    }

    private mutating func begin(_ phase: Phase, duration: Int, now: Int) {
        state.phase = phase
        state.startedAt = now
        state.endsAt = now + duration
        state.endedAt = nil
        state.remaining = nil
        state.pausedPhase = nil
        state.plannedSeconds = duration
        state.phaseEnteredAt = now
        if phase == .work { state.breakKind = nil; state.task = nil }
    }

    private mutating func clearCountdown() {
        state.breakKind = nil
        state.startedAt = nil
        state.endsAt = nil
        state.endedAt = nil
        state.pausedPhase = nil
        state.remaining = nil
        state.task = nil
        state.plannedSeconds = nil
    }

    private mutating func endBreak(at time: Int, env: Environment) -> [Effect] {
        state.phase = .breakDone
        state.endsAt = nil
        state.endedAt = time
        state.remaining = nil
        state.pausedPhase = nil
        state.phaseEnteredAt = time
        var effects: [Effect] = [.notify("break_end")]
        effects += sound("break_end", config: env.config)
        if !state.inMeeting { effects.append(.showAnswerPanel) }
        effects += changed(at: env.now)
        return effects
    }

    private mutating func finishLunch(at time: Int, env: Environment, early: Bool) -> [Effect] {
        let lunch = state.lunch!
        let start = state.phaseEnteredAt
        let length = lunch.endsAt - start
        var effects: [Effect] = [.appendLog(LogRow(start: start, end: time, kind: "lunch",
                                                  plannedSeconds: length, outcome: early ? "ended_early" : "completed"))]
        state.phase = lunch.returnPhase
        if state.phase == .work || state.phase == .break || state.phase == .paused {
            if state.phase != .paused { state.pausedPhase = state.phase }
            state.phase = .paused
            state.remaining = lunch.returnRemaining
            state.phaseEnteredAt = time
        } else {
            state.phaseEnteredAt = lunch.returnPhaseEnteredAt
        }
        state.lunch = nil
        effects += [.notify("lunch_end")]
        effects += sound("lunch_end", config: env.config)
        if state.phase == .breakDone && !state.inMeeting { effects.append(.showAnswerPanel) }
        effects += changed(at: env.now)
        return effects
    }

    private func row(kind: String, outcome: String, end: Int, suggested: String? = nil, actual: String? = nil) -> LogRow {
        LogRow(start: state.startedAt!, end: end, kind: kind, plannedSeconds: state.plannedSeconds!,
               outcome: outcome, suggested: suggested, actual: actual)
    }

    private mutating func changed(at now: Int) -> [Effect] {
        state.updatedAt = now
        return [.writeState(state), .triggerSketchyBar]
    }

    private func sound(_ name: String, config: Config) -> [Effect] {
        if state.inMeeting && config.sounds.muteInMeeting { return [] }
        let configured: String
        switch name {
        case "work_end": configured = config.sounds.workEnd
        case "break_end": configured = config.sounds.breakEnd
        case "lunch_end": configured = config.sounds.lunchEnd
        default: return []
        }
        return configured.isEmpty ? [] : [.playSound(configured)]
    }
}
