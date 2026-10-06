import Foundation
import TOMLKit

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct Config: Codable, Equatable, Sendable {
    public var timer = TimerConfig()
    public var breaks = BreakConfig()
    public var workHours: [String: [String]] = [
        "mon": ["09:00", "18:00"], "tue": ["09:00", "18:00"],
        "wed": ["09:00", "18:00"], "thu": ["09:00", "18:00"],
        "fri": ["09:00", "18:00"], "sat": [], "sun": [],
    ]
    public var nags = NagConfig()
    public var meetings = MeetingConfig()
    public var sounds = SoundConfig()
    public var sketchybar = SketchyBarConfig()
    public var general = GeneralConfig()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case timer, breaks, nags, meetings, sounds, sketchybar, general
        case workHours = "work_hours"
    }

    public static func parse(_ text: String) throws -> (config: Config, warnings: [String]) {
        let input: TOMLTable
        do { input = try TOMLTable(string: text) }
        catch { throw ConfigError("Invalid TOML: \(error)") }
        if let hours = input["work_hours"]?.table {
            for day in hours.keys.sorted() where !WorkHoursEditor.days.contains(day) {
                throw ConfigError("Unknown weekday: \(day)")
            }
        }
        let defaults: TOMLTable
        do { defaults = try TOMLEncoder().encode(Config()) }
        catch { throw ConfigError("Cannot encode defaults: \(error)") }
        var warnings: [String] = []
        func merge(_ source: TOMLTable, into target: TOMLTable, prefix: String) {
            for key in source.keys {
                let path = prefix + key
                guard let original = target[key] else {
                    warnings.append("Unknown key: \(path)")
                    continue
                }
                if let nested = source[key]?.table, let existing = original.table {
                    merge(nested, into: existing, prefix: path + ".")
                } else {
                    target[key] = source[key]
                }
            }
        }
        merge(input, into: defaults, prefix: "")
        do {
            let config = try TOMLDecoder().decode(Config.self, from: defaults)
            try config.validate()
            return (config, warnings.sorted())
        } catch let error as ConfigError { throw error }
        catch { throw ConfigError("Invalid config value: \(error)") }
    }

    public func toml() throws -> String {
        try TOMLEncoder().encode(self)
    }

    public func validate() throws {
        for (name, value) in [
            ("timer.work_minutes", timer.workMinutes),
            ("timer.short_break_minutes", timer.shortBreakMinutes),
            ("timer.long_break_minutes", timer.longBreakMinutes),
            ("timer.long_break_every", timer.longBreakEvery),
            ("timer.extend_minutes", timer.extendMinutes),
            ("timer.lunch_minutes", timer.lunchMinutes),
            ("nags.interval_minutes", nags.intervalMinutes),
            ("general.day_end_idle_minutes", general.dayEndIdleMinutes),
        ] where value <= 0 || value > Int.max / 60 {
            throw ConfigError("\(name) must be positive and fit in seconds")
        }
        if timer.dailyGoal < 0 { throw ConfigError("timer.daily_goal must not be negative") }
        if nags.idleThresholdMinutes < 0 { throw ConfigError("nags.idle_threshold_minutes must not be negative") }
        if !sketchybar.path.isEmpty && !sketchybar.path.hasPrefix("/") {
            throw ConfigError("sketchybar.path must be absolute or empty")
        }
        for day in workHours.keys.sorted() where !WorkHoursEditor.days.contains(day) {
            throw ConfigError("Unknown weekday: \(day)")
        }
        for day in WorkHoursEditor.days {
            let window = workHours[day] ?? []
            if window.isEmpty { continue }
            guard window.count == 2,
                  let start = Self.minutes(window[0]), let end = Self.minutes(window[1]), start < end else {
                throw ConfigError("work_hours.\(day) must be [HH:MM, HH:MM] with start before end")
            }
        }
    }

    private static func minutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), hour < 24, minute < 60 else { return nil }
        return hour * 60 + minute
    }
}

public struct TimerConfig: Codable, Equatable, Sendable {
    public var workMinutes = 25
    public var shortBreakMinutes = 5
    public var longBreakMinutes = 15
    public var longBreakEvery = 4
    public var extendMinutes = 5
    public var lunchMinutes = 60
    public var dailyGoal = 8
    public init() {}
    enum CodingKeys: String, CodingKey {
        case workMinutes = "work_minutes", shortBreakMinutes = "short_break_minutes"
        case longBreakMinutes = "long_break_minutes", longBreakEvery = "long_break_every"
        case extendMinutes = "extend_minutes", lunchMinutes = "lunch_minutes", dailyGoal = "daily_goal"
    }
}

public struct BreakConfig: Codable, Equatable, Sendable {
    public var short = ["Pushups", "Squats", "Yoga", "Meditate"]
    public var long = ["Go for Walk", "Yoga"]
    public var other = ["Other"]
    public init() {}
}

public struct NagConfig: Codable, Equatable, Sendable {
    public var enabled = true
    public var intervalMinutes = 10
    public var idleThresholdMinutes = 5
    public var unused = [
        "Oh, you must be so busy you can't use your timer.", "The tomato misses you.",
        "Free-range working again, are we?", "Bold strategy: no timer, no breaks, no plan.",
        "Your pushups have filed a missing persons report.",
        "I'm not mad. I'm just a timer, sitting here, untimed.",
        "Tick tock. Well, it would, if you started me.",
        "Somewhere a Pomodoro is going unused. It's this one.",
    ]
    public var waiting = [
        "The timer finished ages ago. It's waiting. Patiently. Mostly.",
        "This is your timer's version of an unacknowledged page.",
        "Overtime is for incidents, not for forgetting to click.",
        "Your break is getting cold.", "Paused is a state, not a lifestyle.",
        "Still there? The next step is one click away.",
        "Did you do the pushups, or are we pretending?",
        "Confirmation pending. Escalating to nobody. Still, click it.",
    ]
    public init() {}
    enum CodingKeys: String, CodingKey {
        case enabled, unused, waiting
        case intervalMinutes = "interval_minutes", idleThresholdMinutes = "idle_threshold_minutes"
    }
}

public struct MeetingConfig: Codable, Equatable, Sendable {
    public var camera = true
    public var microphone = false
    public init() {}
}

public struct SoundConfig: Codable, Equatable, Sendable {
    public var workEnd = "Glass"
    public var breakEnd = "Hero"
    public var lunchEnd = "Ping"
    public var nag = "Funk"
    public var muteInMeeting = true
    public init() {}
    enum CodingKeys: String, CodingKey {
        case workEnd = "work_end", breakEnd = "break_end", lunchEnd = "lunch_end"
        case nag, muteInMeeting = "mute_in_meeting"
    }
}

public struct SketchyBarConfig: Codable, Equatable, Sendable {
    public var enabled = true
    public var event = "fromo_update"
    public var path = ""
    public init() {}
}

public struct GeneralConfig: Codable, Equatable, Sendable {
    public var launchAtLogin = true
    public var dayEndIdleMinutes = 60
    public init() {}
    enum CodingKeys: String, CodingKey {
        case launchAtLogin = "launch_at_login"
        case dayEndIdleMinutes = "day_end_idle_minutes"
    }
}
