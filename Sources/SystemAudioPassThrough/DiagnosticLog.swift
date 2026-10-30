import Darwin
import Foundation

enum DiagnosticLog {
    private static let lock = NSLock()
    private static var handle: FileHandle?
    private(set) static var path = "stdout"

    static func configure(requestedPath: String?) {
        lock.lock()
        defer { lock.unlock() }
        let requested = requestedPath ?? "/private/tmp/levelup-poc-\(getpid()).log"
        let url = URL(fileURLWithPath: requested)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: requested) {
                FileManager.default.createFile(atPath: requested, contents: nil)
            }
            handle = try FileHandle(forWritingTo: url)
            try handle?.truncate(atOffset: 0)
            path = "stdout + file:\(requested)"
        } catch {
            handle = nil
            path = "stdout only (requested file \(requested) unavailable: \(error))"
            fputs("Could not open diagnostic log at \(requested): \(error)\n", stderr)
        }
    }

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        let data = Data(line.utf8)
        FileHandle.standardOutput.write(data)
        try? handle?.write(contentsOf: data)
    }
}
