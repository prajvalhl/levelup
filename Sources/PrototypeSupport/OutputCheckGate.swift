/// Main-thread gate for an asynchronous read-only Core Audio check. It permits
/// one queued query at a time and identifies results from replaced sessions.
public struct OutputCheckGate: Equatable, Sendable {
    private var inFlightGeneration: Int?

    public init() {}

    public mutating func begin(generation: Int) -> Bool {
        guard inFlightGeneration == nil else { return false }
        inFlightGeneration = generation
        return true
    }

    /// Always clears the matching query. Returns true only if the result still
    /// belongs to the current session generation.
    public mutating func complete(generation: Int, currentGeneration: Int) -> Bool {
        guard inFlightGeneration == generation else { return false }
        inFlightGeneration = nil
        return generation == currentGeneration
    }
}
