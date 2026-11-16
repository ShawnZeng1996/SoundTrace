import AppKit

if CommandLine.arguments.contains("--diagnose") {
    let duration = CommandLine.arguments.last.flatMap(Double.init) ?? 10
    guard duration > 0, duration <= 3600 else {
        fputs(String(localized: "诊断时长需在 0–3600 秒之间。") + "\n", stderr)
        exit(1)
    }
    let monitor = AudioMonitor(persistHistory: false)
    monitor.onEvent = { event in
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(event), let line = String(data: data, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
    }
    monitor.start()
    print(String(localized: "输出设备：\(monitor.outputDevice)；监控 \(Int(duration)) 秒"))
    fflush(stdout)
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
    let error = monitor.errorMessage
    monitor.stop()
    if let error {
        fputs("\(error)\n", stderr)
        exit(1)
    }
} else {
    SoundTraceApp.main()
}
