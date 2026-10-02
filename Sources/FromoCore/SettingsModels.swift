import Foundation

public struct ConfigReloadResult: Sendable {
    public var changed: Bool
    public var shouldNotify: Bool
}

public struct ConfigReloadPolicy: Sendable {
    public private(set) var config = Config()
    public private(set) var error: String?
    private var seenErrors: Set<String> = []
    public init() {}

    // The caller parses/validates candidates before accepting them.
    public mutating func accept(_ candidate: Config) -> ConfigReloadResult {
        let changed = candidate != config
        config = candidate
        error = nil
        return ConfigReloadResult(changed: changed, shouldNotify: false)
    }

    public mutating func reject(_ message: String) -> ConfigReloadResult {
        error = message
        return ConfigReloadResult(changed: false, shouldNotify: seenErrors.insert(message).inserted)
    }
}

public struct SettingsDraft: Sendable {
    public private(set) var config: Config
    public private(set) var validationError: String?
    private var baseline: Config
    private var deadline: Int?
    public init(config: Config) { self.config = config; baseline = config }

    public mutating func edit(_ candidate: Config, nowMilliseconds: Int) {
        config = candidate
        do {
            try candidate.validate()
            validationError = nil
            deadline = candidate == baseline ? nil : nowMilliseconds + 500
        } catch {
            validationError = String(describing: error)
            deadline = nil
        }
    }

    public mutating func takeWrite(nowMilliseconds: Int, force: Bool = false) -> Config? {
        guard validationError == nil, let deadline, force || nowMilliseconds >= deadline else { return nil }
        self.deadline = nil
        return config
    }

    public mutating func didSave(_ saved: Config) { baseline = saved }

    public mutating func didFailSave(nowMilliseconds: Int) {
        if validationError == nil && config != baseline { deadline = nowMilliseconds + 500 }
    }

    @discardableResult
    public mutating func receive(_ external: Config) -> Bool {
        guard external != baseline else { return false }
        baseline = external
        config = external
        validationError = nil
        deadline = nil
        return true
    }
}

public enum SettingsLists {
    public static func move(_ values: inout [String], from source: IndexSet, to destination: Int) {
        guard (0...values.count).contains(destination), source.allSatisfy({ values.indices.contains($0) }) else { return }
        let moved = source.map { values[$0] }
        for index in source.reversed() { values.remove(at: index) }
        values.insert(contentsOf: moved, at: destination - source.filter { $0 < destination }.count)
    }
    public static func remove(_ values: inout [String], at indexes: IndexSet) {
        for index in indexes.reversed() where values.indices.contains(index) { values.remove(at: index) }
    }
}

public enum WorkHoursEditor {
    public static let days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    public static let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    public static func setEnabled(_ enabled: Bool, day: String, in config: inout Config) {
        guard days.contains(day) else { return }
        if !enabled { config.workHours[day] = [] }
        else if (config.workHours[day] ?? []).isEmpty { config.workHours[day] = ["09:00", "18:00"] }
    }
    public static func time(index: Int, day: String, config: Config) -> (hour: Int, minute: Int) {
        let values = config.workHours[day] ?? []
        let text = values.indices.contains(index) ? values[index] : (index == 0 ? "09:00" : "18:00")
        let parts = text.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : (9, 0)
    }
    public static func setTime(hour: Int, minute: Int, index: Int, day: String, in config: inout Config) {
        guard days.contains(day), (0...1).contains(index), (0...23).contains(hour), (0...59).contains(minute) else { return }
        var values = config.workHours[day] ?? []
        if values.count != 2 { values = ["09:00", "18:00"] }
        values[index] = String(format: "%02d:%02d", hour, minute)
        config.workHours[day] = values
    }
}
