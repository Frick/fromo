import Foundation

public struct MenuAction: Equatable, Sendable {
    public var title: String
    public var command: Command
    public var enabled: Bool
    public var checked: Bool
}

public struct MenuModel: Sendable {
    public var status: String
    public var today: String
    public var countdown: String
    public var primary: MenuAction
    public var controls: [MenuAction]
    public var lunch: MenuAction
    public var notToday: MenuAction
    public var settings: MenuAction

    public init(state: State, config: Config, now: Int, settingsAvailable: Bool = false) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let environment = Environment(now: now, calendar: calendar, config: config)
        func action(_ title: String, _ command: Command, checked: Bool = false) -> MenuAction {
            var copy = Engine(state: state)
            let allowed = (try? copy.handle(command, env: environment)) != nil
            return MenuAction(title: title, command: command, enabled: allowed, checked: checked)
        }
        status = StatePresentation.summary(state, now: now).components(separatedBy: "\n")[0]
        today = "Today: \(state.completedToday) of \(state.dailyGoal)"
        switch state.phase {
        case .work, .break: countdown = StatePresentation.time((state.endsAt ?? now) - now)
        case .lunch: countdown = StatePresentation.time((state.lunch?.endsAt ?? now) - now)
        default: countdown = ""
        }
        switch state.phase {
        case .ready: primary = action("Start Work", .start)
        case .workDone: primary = action("Start Break", .startBreak)
        case .breakDone: primary = action("Answer Break…", .next)
        case .paused: primary = action("Resume", .resume)
        case .lunch: primary = action("End Lunch", .endLunch)
        default: primary = action("Start Work", .start)
        }
        controls = [
            action(state.phase == .paused ? "Resume" : "Pause", state.phase == .paused ? .resume : .pause),
            action("Restart Timer", .restart), action("Extend +\(config.timer.extendMinutes) min", .extend(nil)),
            action("End Break Now", .endBreak), action("Abandon Session", .reset),
        ]
        lunch = action(state.phase == .lunch ? "End Lunch" : "Lunch (\(config.timer.lunchMinutes) min)", state.phase == .lunch ? .endLunch : .lunch(nil))
        notToday = action("Not Today", .notToday(state.nagsOffUntil == nil), checked: state.nagsOffUntil != nil)
        settings = action("Settings…", .settings)
        settings.enabled = settingsAvailable
    }
}

public struct NotificationActionModel: Equatable, Sendable {
    public var id: String
    public var title: String
    public var command: Command
}

public struct NotificationModel: Sendable {
    public static let phaseIdentifiers = ["work_end", "break_end", "lunch_end", "nag"]
    public var kind: String
    public var title: String
    public var body: String
    public var actions: [NotificationActionModel]

    public init(kind: String, state: State, config: Config, detail: String? = nil) {
        self.kind = kind
        actions = []
        switch kind {
        case "work_end":
            title = "Work session done"
            body = state.nextTask.map { "Break next: \($0)" } ?? "Start your break."
            actions = [NotificationActionModel(id: "start_break", title: "Start Break", command: .startBreak)]
        case "break_end":
            title = "Break's over"
            body = state.task.map { "Did you do \($0)?" } ?? "What did you do?"
        case "lunch_end":
            title = "Lunch is over"; body = "Returned to \(state.phase.rawValue)."
            actions = [NotificationActionModel(id: "continue", title: "Continue", command: .next)]
        case "state_corrupt":
            title = "State recovered"; body = "The invalid state file was preserved. Fromo is ready."
        case "config_error":
            title = "Config error"
            body = (detail ?? "Invalid config.").components(separatedBy: "\n")[0]
            actions = [NotificationActionModel(id: "open_config", title: "Open Config", command: .openConfig)]
        default:
            title = "Fromo"; body = kind
        }
    }

    public static func command(for action: String, category: String = "") -> Command? {
        switch action {
        case "start_break": return .startBreak
        case "continue": return .next
        case "not_today": return .notToday(true)
        case "open_config": return .openConfig
        case "body" where category == "break_end": return .next
        default: return nil
        }
    }
}

public struct AnswerPanelModel: Sendable {
    public var suggestion: String?
    public var other: [String]
    public init(state: State, config: Config) {
        suggestion = state.task
        other = config.breaks.other.isEmpty ? ["Other"] : config.breaks.other
    }
    public func command(answer: Answer, startNext: Bool, shift: Bool) -> Command {
        .answer(answer, startNext: startNext != shift)
    }
}

public struct SketchyBarInvocation: Equatable, Sendable {
    public static let knownLocations = ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"]
    public var executable: String
    public var arguments: [String]
    public init?(config: SketchyBarConfig, existing: [String]) {
        guard config.enabled else { return nil }
        if !config.path.isEmpty { executable = config.path }
        else if let found = Self.knownLocations.first(where: { existing.contains($0) }) { executable = found }
        else { return nil }
        arguments = ["--trigger", config.event]
    }
}
