/// Chooses what the UI session should do after the current engine has been
/// cleaned up successfully. A pending Quit consumes its flag so it cannot
/// affect a later, unrelated stop.
public enum SessionCleanupDecision: Equatable {
    case quit
    case restart
    case recover
    case stopped

    public static func resolve(restartAfter: Bool, quitRequested: inout Bool) -> SessionCleanupDecision {
        if quitRequested {
            quitRequested = false
            return .quit
        }
        return restartAfter ? .restart : .stopped
    }
}
