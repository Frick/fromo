import Foundation

public enum StatePresentation {
    public static func time(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    public static func summary(_ state: State, now: Int) -> String {
        let activity: String
        switch state.phase {
        case .ready: activity = state.dayClosedAt == nil ? "Ready" : "Day done"
        case .work: activity = "Work · \(time((state.endsAt ?? now) - now)) left"
        case .workDone: activity = "Waiting for break · +\(time(now - (state.endedAt ?? now)))"
        case .break: activity = "Break · \(state.task ?? "Break") · \(time((state.endsAt ?? now) - now))"
        case .breakDone: activity = "Waiting for answer · \(state.task ?? "Break") · +\(time(now - (state.endedAt ?? now)))"
        case .paused: activity = "Paused · \(time(state.remaining ?? 0))"
        case .lunch: activity = "Lunch · \(time((state.lunch?.endsAt ?? now) - now))"
        case .stopped: activity = "not running"
        }
        return "\(activity)\nToday: \(state.completedToday) of \(state.dailyGoal)"
    }
}
