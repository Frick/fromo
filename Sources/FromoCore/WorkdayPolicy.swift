import Foundation

public enum WorkdayCloseReason: String, Codable, Sendable { case afterHoursIdle, nextWorkday }
public struct WorkdayClose: Equatable, Sendable {
    public var reason: WorkdayCloseReason
    public var at: Int
    public var workday: String
}

public enum WorkdayPolicy {
    public static func trackedDay(state: State, calendar: Calendar) -> String {
        state.workdayDate ?? State.localDate(state.startedAt ?? state.phaseEnteredAt, calendar: calendar)
    }

    public static func window(day: String, env: Environment) -> (start: Int, end: Int)? {
        guard let date = try? StatsPeriod.date(day, calendar: env.calendar) else { return nil }
        let weekday = env.calendar.component(.weekday, from: date)
        guard (1...7).contains(weekday) else { return nil }
        let key = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"][weekday - 1]
        guard let values = env.config.workHours[key], values.count == 2 else { return nil }
        func timestamp(_ text: String) -> Int? {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2,
                  let value = env.calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date) else { return nil }
            return Int(value.timeIntervalSince1970)
        }
        guard let start = timestamp(values[0]), let end = timestamp(values[1]), start < end else { return nil }
        return (start, end)
    }

    public static func evaluate(state: State, env: Environment) -> WorkdayClose? {
        guard state.phase != .stopped else { return nil }
        let tracked = trackedDay(state: state, calendar: env.calendar)
        let today = State.localDate(env.now, calendar: env.calendar)
        if tracked < today, let next = window(day: today, env: env), env.now >= next.start {
            return WorkdayClose(reason: .nextWorkday, at: next.start, workday: today)
        }
        guard state.dayClosedAt == nil, !state.inMeeting,
              let window = window(day: tracked, env: env) else { return nil }
        let baseline = max(window.end, env.now - max(0, env.idleSeconds), state.dayOpenedAt ?? Int.min)
        let (deadline, overflow) = baseline.addingReportingOverflow(env.config.general.dayEndIdleMinutes * 60)
        guard !overflow, env.now >= deadline else { return nil }
        return WorkdayClose(reason: .afterHoursIdle, at: deadline, workday: tracked)
    }
}
