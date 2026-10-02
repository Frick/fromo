import Foundation

public struct StatsError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum StatsKind: String, Codable, Sendable { case today, week, month, custom }

public struct StatsPeriod: Codable, Sendable {
    public let kind: StatsKind
    public let from: String
    public let to: String

    public static func resolve(kind: StatsKind, now: Int, calendar: Calendar) throws -> StatsPeriod {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now)))
        let start: Date
        switch kind {
        case .today: start = today
        case .week:
            let offset = (calendar.component(.weekday, from: today) + 5) % 7
            start = calendar.date(byAdding: .day, value: -offset, to: today)!
        case .month:
            var components = calendar.dateComponents([.year, .month], from: today)
            components.day = 1
            start = calendar.date(from: components)!
        case .custom: throw StatsError("A custom period requires --from and --to.")
        }
        return StatsPeriod(kind: kind, from: State.localDate(Int(start.timeIntervalSince1970), calendar: calendar),
                           to: State.localDate(Int(today.timeIntervalSince1970), calendar: calendar))
    }

    public static func custom(from: String, to: String, calendar: Calendar) throws -> StatsPeriod {
        let start = try date(from, calendar: calendar)
        let end = try date(to, calendar: calendar)
        guard start <= end else { throw StatsError("--from must not be after --to.") }
        return StatsPeriod(kind: .custom, from: from, to: to)
    }

    public static func date(_ text: String, calendar: Calendar) throws -> Date {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }) else {
            throw StatsError("Invalid date '\(text)'; use YYYY-MM-DD.")
        }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 0,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              State.localDate(Int(date.timeIntervalSince1970), calendar: calendar) == text else {
            throw StatsError("Invalid calendar date '\(text)'.")
        }
        return date
    }

    public func dates(calendar: Calendar) throws -> [String] {
        var current = try Self.date(from, calendar: calendar)
        let end = try Self.date(to, calendar: calendar)
        var values: [String] = []
        while current <= end {
            values.append(State.localDate(Int(current.timeIntervalSince1970), calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current), next > current else {
                throw StatsError("Could not advance the report date.")
            }
            current = next
        }
        return values
    }
}

public struct TaskStats: Codable, Sendable {
    public var name: String
    public var suggested: Int
    public var done: Int
}
public struct OtherStats: Codable, Sendable { public var name: String; public var count: Int }
public struct DayStats: Codable, Sendable { public var date: String; public var completed: Int; public var goal: Int }

public struct StatsReport: Codable, Sendable {
    public var period: StatsPeriod
    public var completed = 0
    public var abandoned = 0
    public var focusSeconds = 0
    public var dailyGoal: Int
    public var goalMetDays = 0
    public var shortBreaks = 0
    public var longBreaks = 0
    public var answeredBreaks = 0
    public var didSuggested = 0
    public var compliancePercent = 0.0
    public var tasks: [TaskStats] = []
    public var other: [OtherStats] = []
    public var days: [DayStats] = []
    public var skippedRows = 0

    public var text: String {
        let title: String
        switch period.kind {
        case .today: title = "Today · \(period.to)"
        case .week: title = "Week of \(period.from) (through \(period.to))"
        case .month: title = "Month of \(period.from.prefix(7)) (through \(period.to))"
        case .custom: title = "\(period.from)–\(period.to)"
        }
        func name(_ text: String) -> String { text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }
        var lines = [title,
                     "Pomodoros   \(completed) completed, \(abandoned) abandoned   \(focusSeconds / 3_600)h\((focusSeconds % 3_600) / 60)m focus   goal met \(goalMetDays)/\(days.count) days",
                     "Breaks      \(shortBreaks) short, \(longBreaks) long   compliance \(Int(compliancePercent.rounded()))%",
                     "Tasks       " + (tasks.isEmpty ? "none" : tasks.map { "\(name($0.name)) \($0.done)/\($0.suggested)" }.joined(separator: "   ")),
                     "Other       " + (other.isEmpty ? "none" : other.map { "\(name($0.name)) \($0.count)" }.joined(separator: "   "))]
        if period.kind == .week || period.kind == .month {
            lines += days.map { "\($0.date)  \($0.completed)/\($0.goal)" }
        }
        return lines.joined(separator: "\n")
    }
}

public enum Stats {
    public static func read(period: StatsPeriod, dailyGoal: Int, store: LogStore) throws -> StatsReport {
        var rows: [String: [[String]]] = [:]
        for day in try period.dates(calendar: store.calendar) { rows[day] = try store.read(day: day) }
        return try aggregate(period: period, dailyGoal: dailyGoal, calendar: store.calendar, rowsByDay: rows)
    }

    public static func aggregate(period: StatsPeriod, dailyGoal: Int, calendar: Calendar,
                                 rowsByDay: [String: [[String]]]) throws -> StatsReport {
        guard dailyGoal >= 0 else { throw StatsError("Daily goal must not be negative.") }
        var report = StatsReport(period: period, dailyGoal: dailyGoal)
        var tasks: [String: TaskStats] = [:]
        var other: [String: Int] = [:]
        let timestamps = ISO8601DateFormatter()
        for day in try period.dates(calendar: calendar) {
            var completed = 0
            for fields in rowsByDay[day] ?? [] {
                guard fields.count == 7,
                      let start = timestamps.date(from: fields[0]), let end = timestamps.date(from: fields[1]), end >= start,
                      String(fields[0].prefix(10)) == day,
                      let seconds = Int(fields[3]), seconds >= 0 else { report.skippedRows += 1; continue }
                switch (fields[2], fields[4]) {
                case ("work", "completed"):
                    let (focus, overflow) = report.focusSeconds.addingReportingOverflow(seconds)
                    guard !overflow else { report.skippedRows += 1; continue }
                    report.focusSeconds = focus
                    report.completed += 1; completed += 1
                case ("work", "abandoned"): report.abandoned += 1
                case ("short_break", "did_suggested"), ("short_break", "did_other"),
                     ("long_break", "did_suggested"), ("long_break", "did_other"):
                    report.answeredBreaks += 1
                    if fields[2] == "short_break" { report.shortBreaks += 1 } else { report.longBreaks += 1 }
                    if fields[4] == "did_suggested" { report.didSuggested += 1 }
                    if !fields[5].isEmpty {
                        var value = tasks[fields[5]] ?? TaskStats(name: fields[5], suggested: 0, done: 0)
                        value.suggested += 1
                        if fields[4] == "did_suggested" { value.done += 1 }
                        tasks[fields[5]] = value
                    }
                    if fields[4] == "did_other" { other[fields[6], default: 0] += 1 }
                case ("lunch", "completed"), ("lunch", "ended_early"): break
                default: report.skippedRows += 1
                }
            }
            report.days.append(DayStats(date: day, completed: completed, goal: dailyGoal))
            if completed >= dailyGoal { report.goalMetDays += 1 }
        }
        report.tasks = tasks.keys.sorted().compactMap { tasks[$0] }
        report.other = other.keys.sorted().map { OtherStats(name: $0, count: other[$0]!) }
        report.compliancePercent = report.answeredBreaks == 0 ? 0 : 100 * Double(report.didSuggested) / Double(report.answeredBreaks)
        return report
    }
}
