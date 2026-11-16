import AppKit
import SwiftUI

@main
struct UITests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { exit(1) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.applicationIconImage = NSImage(contentsOf: output.deletingLastPathComponent().appendingPathComponent("Assets/AppIcon.png"))
        let monitor = AudioMonitor(persistHistory: false)
        let view = NSHostingView(rootView: ContentView(monitor: monitor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "音源排查 · 界面验证"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        monitor.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try snapshot(view: view, to: output.appendingPathComponent("ui-idle.png"))

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0", "/System/Library/Sounds/Hero.aiff"]
        try player.run()
        let deadline = Date().addingTimeInterval(2)
        var sawActive = false
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if monitor.apps.contains(where: { $0.processes.contains { $0.pid == player.processIdentifier } }) {
                sawActive = true
                break
            }
        }
        guard sawActive else {
            fputs("播放器没有出现在界面模型中\n", stderr)
            exit(1)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        try snapshot(view: view, to: output.appendingPathComponent("ui-active.png"))
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        player.waitUntilExit()
        try snapshot(view: view, to: output.appendingPathComponent("ui-history.png"))
        monitor.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try snapshot(view: view, to: output.appendingPathComponent("ui-paused.png"))

        let fixtures = AudioMonitor(persistHistory: false)
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let missingDay = Calendar.current.date(byAdding: .day, value: -7, to: today)!
        for (day, bundle) in [(yesterday, "test.yesterday"), (today, "test.today")] {
            fixtures.apply(samples: [AudioProcessSample(objectID: 900001, pid: 990001, bundleID: bundle,
                                                        output: true, input: false, devices: ["测试输出"])],
                           at: day.addingTimeInterval(9 * 3600))
            fixtures.apply(samples: [], at: day.addingTimeInterval(9 * 3600 + 60))
        }
        let cases: [(String, HistoryDateFilter)] = [
            ("today", .today), ("yesterday", .day(yesterday)), ("all", .all), ("empty-date", .day(missingDay))
        ]
        for (name, filter) in cases {
            let fixtureView = NSHostingView(rootView: ContentView(monitor: fixtures, initialDateFilter: filter))
            window.contentView = fixtureView
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            try snapshot(view: fixtureView, to: output.appendingPathComponent("ui-\(name).png"))
            guard let picker = datePicker(in: fixtureView) else {
                fputs("未找到原生日期选择器\n", stderr)
                exit(1)
            }
            guard picker.presentsCalendarOverlay else {
                fputs("日期选择器没有启用弹出日历\n", stderr)
                exit(1)
            }
            guard picker.isEnabled == (name != "all") else {
                fputs("全部日期模式的日期选择器状态不正确\n", stderr)
                exit(1)
            }
            if name == "today" {
                guard Calendar.current.isDateInToday(picker.dateValue) else {
                    fputs("日期选择器没有默认当天\n", stderr)
                    exit(1)
                }
                picker.dateValue = yesterday
                guard let action = picker.action,
                      application.sendAction(action, to: picker.target, from: picker) else {
                    fputs("日期选择器未触发更新\n", stderr)
                    exit(1)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                try snapshot(view: fixtureView, to: output.appendingPathComponent("ui-picked-date.png"))
            }
        }
        let pgrep = Process()
        let pgrepOutput = Pipe()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "systemsoundserverd"]
        pgrep.standardOutput = pgrepOutput
        try pgrep.run()
        pgrep.waitUntilExit()
        let soundServer = String(decoding: pgrepOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").first.flatMap { pid_t($0) }
        guard let soundServer else {
            fputs("未找到 systemsoundserverd\n", stderr)
            exit(1)
        }
        let traced = AudioMonitor(persistHistory: false)
        let now = Date()
        traced.handle(.notification(bundleID: "com.apple.ScriptEditor2", sound: "Glass"), from: 751, at: now)
        traced.apply(samples: [AudioProcessSample(objectID: 900002, pid: soundServer, bundleID: nil,
                                                  output: true, input: false, devices: ["测试输出"])], at: now)
        guard traced.apps.first?.processes.first?.processName == "systemsoundserverd" else {
            fputs("系统音效进程没有出现在当前列表\n", stderr)
            exit(1)
        }
        let tracedView = NSHostingView(rootView: ContentView(monitor: traced))
        window.contentView = tracedView
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try snapshot(view: tracedView, to: output.appendingPathComponent("ui-trigger.png"))
        window.orderOut(nil)
        print("已验证原生日期选择器默认当天及选择历史日期；已渲染全部日期与无记录日期")
    }

    private static func datePicker(in view: NSView) -> NSDatePicker? {
        if let picker = view as? NSDatePicker { return picker }
        for child in view.subviews {
            if let picker = datePicker(in: child) { return picker }
        }
        return nil
    }

    private static func snapshot(view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        try data.write(to: url)
    }
}
