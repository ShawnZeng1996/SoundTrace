import Foundation

enum SoundLogLine: Equatable {
    case soundFile(pid: pid_t, path: String)
    case request(pid: pid_t, process: String, actionID: Int)
    case notification(bundleID: String, sound: String)

    private static let soundFile = try! NSRegularExpression(pattern: #"clientPID (\d+)\([^)]*\), .*audio file path (.+?), customVibeDataProvided"#)
    private static let request = try! NSRegularExpression(pattern: #"Incoming Request : actionID (\d+), inClientPID (\d+)\(([^)]*)\)"#)
    private static let notification = try! NSRegularExpression(pattern: #"Playing notification sound \{ nam: (.*?) \} for (\S+)"#)

    static func parse(_ message: String) -> SoundLogLine? {
        if let groups = match(notification, message) {
            return .notification(bundleID: groups[1], sound: groups[0])
        }
        if let groups = match(request, message), let action = Int(groups[0]), let pid = pid_t(groups[1]) {
            return .request(pid: pid, process: groups[2], actionID: action)
        }
        if let groups = match(soundFile, message), let pid = pid_t(groups[0]) {
            return .soundFile(pid: pid, path: groups[1])
        }
        return nil
    }

    private static func match(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let result = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

final class SoundLogStream {
    private var process: Process?
    private var buffer = Data()

    func start(onLine: @escaping (SoundLogLine, pid_t) -> Void, onFailure: @escaping () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--level", "info", "--predicate",
                             #"(process == "systemsoundserverd" AND (eventMessage CONTAINS "Incoming Request" OR eventMessage CONTAINS "audio file path")) OR (subsystem == "com.apple.unc" AND category == "sound")"#]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data, onLine: onLine) }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                onFailure()
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            onFailure()
        }
    }

    func stop() {
        let running = process
        process = nil
        buffer = Data()
        running?.terminate()
    }

    private func consume(_ data: Data, onLine: (SoundLogLine, pid_t) -> Void) {
        guard process != nil else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  let parsed = SoundLogLine.parse(message) else { continue }
            onLine(parsed, (object["processID"] as? NSNumber)?.int32Value ?? 0)
        }
    }
}
