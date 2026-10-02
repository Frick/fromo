public enum LoginItemStatus: String, Sendable {
    case notRegistered = "not_registered"
    case enabled
    case requiresApproval = "requires_approval"
    case notFound = "not_found"
    case unknown
}

public enum LoginItemAction: String, Sendable {
    case none, register, unregister
}

public enum LoginItemPolicy {
    public static func action(enabled: Bool, status: LoginItemStatus) -> LoginItemAction {
        if enabled {
            return status == .enabled || status == .requiresApproval ? .none : .register
        }
        return status == .notRegistered || status == .notFound ? .none : .unregister
    }
}
