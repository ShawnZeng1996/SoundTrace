import AppKit
import CoreAudio

@main
struct MonitorTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        checks += 1
        print("PASS: \(message)")
    }

    static func sample(_ object: AudioObjectID = 900001, pid: pid_t = 990001,
                       output: Bool = false, input: Bool = false, bundle: String = "test.audio") -> AudioProcessSample {
        AudioProcessSample(objectID: object, pid: pid, bundleID: bundle,
                           output: output, input: input, devices: ["测试输出"])
    }

    static func main() throws {
        let monitor = AudioMonitor(persistHistory: false)
        let date = Date()
        monitor.apply(samples: [sample()], at: date)
        check(monitor.apps.isEmpty && monitor.events.isEmpty, "空闲音频进程不上榜")
        monitor.apply(samples: [sample(output: true)], at: date)
        check(monitor.apps.count == 1 && monitor.events.first?.kind == .outputStarted, "开始输出生成记录")
        monitor.apply(samples: [sample(output: true)], at: date.addingTimeInterval(1))
        check(monitor.events.count == 1 && monitor.apps[0].since == date, "重复快照不重复记录且保留开始时间")
        monitor.apply(samples: [sample(output: true, input: true)], at: date.addingTimeInterval(2))
        check(monitor.events.first?.kind == .inputStarted && monitor.apps[0].input, "输入与输出可同时显示")
        monitor.apply(samples: [sample(input: true)], at: date.addingTimeInterval(3))
        check(monitor.events.first?.kind == .outputStopped && !monitor.apps[0].output, "停止输出但保留输入状态")
        monitor.apply(samples: [], at: date.addingTimeInterval(4))
        check(monitor.apps.isEmpty && monitor.events.first?.kind == .inputStopped, "进程退出生成停止记录")
        monitor.clearHistory()
        check(monitor.events.isEmpty, "清空记录")

        monitor.apply(samples: [sample(output: true), sample(900002, pid: 990002, output: true)], at: date)
        check(monitor.apps.count == 1 && monitor.apps[0].processes.count == 2, "同一应用的多个进程合并")
        monitor.apply(samples: [sample(900002, pid: 990002, output: true)], at: date.addingTimeInterval(1))
        check(monitor.apps.count == 1 && monitor.apps[0].output, "单个子进程停止不会移除仍在输出的应用")
        monitor.apply(samples: [sample(900002, pid: 990003, output: true, bundle: "test.new")], at: date)
        check(monitor.events[1].kind == .outputStopped && monitor.events[1].pid == 990002
              && monitor.events[0].kind == .outputStarted && monitor.events[0].pid == 990003, "对象 ID 重用不混淆应用")
        monitor.apply(samples: [sample(pid: getpid(), output: true)], at: date)
        check(monitor.apps.isEmpty, "不显示监控工具自身")
        monitor.clearHistory()
        for index in 0..<510 {
            monitor.apply(samples: [sample(output: index % 2 == 0)], at: date.addingTimeInterval(Double(index)))
        }
        check(monitor.events.count == 500, "历史记录数量上限")
        let encoder = JSONEncoder()
        let data = try encoder.encode(monitor.events)
        let decoded = try JSONDecoder().decode([AudioEvent].self, from: data)
        check(decoded.count == 500, "历史记录 JSON 可往返编码")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let now = today.addingTimeInterval(3600)
        let todayRange = HistoryDateRange()
        let yesterdayRange = HistoryDateRange(start: yesterday, end: yesterday)
        let span = HistoryDateRange(start: yesterday, end: nil)
        check(todayRange.contains(today, now: now, calendar: calendar), "默认区间包含当天零点")
        check(todayRange.contains(tomorrow.addingTimeInterval(-1), now: now, calendar: calendar), "默认区间包含当天最后一秒")
        check(!todayRange.contains(tomorrow, now: now, calendar: calendar), "默认区间不包含次日零点")
        check(!todayRange.contains(yesterday, now: now, calendar: calendar), "默认区间排除昨天")
        check(yesterdayRange.contains(yesterday.addingTimeInterval(3600), now: now, calendar: calendar), "可按单日区间筛选")
        check(!yesterdayRange.contains(today, now: now, calendar: calendar), "单日区间不混入当天")
        check(span.contains(yesterday, now: now, calendar: calendar) && span.contains(tomorrow.addingTimeInterval(-1), now: now, calendar: calendar)
              && !span.contains(yesterday.addingTimeInterval(-1), now: now, calendar: calendar)
              && !span.contains(tomorrow, now: now, calendar: calendar), "多日区间包含首尾两天")
        check(HistoryDateRange(start: today, end: yesterday).contains(yesterday, now: now, calendar: calendar), "起止颠倒时按正序筛选")
        check(todayRange.contains(tomorrow, now: tomorrow.addingTimeInterval(1), calendar: calendar)
              && !todayRange.contains(today, now: tomorrow.addingTimeInterval(1), calendar: calendar), "跨过午夜后默认区间自动更新")
        let dayEvents = [today.addingTimeInterval(60), yesterday, today.addingTimeInterval(120)].map {
            AudioEvent(date: $0, appName: "日期测试", bundleID: nil, processName: "test", pid: 990001,
                       kind: .outputStarted, devices: [])
        }
        let groups = AudioLogDay.grouped(dayEvents, calendar: calendar)
        check(groups.count == 2 && groups[0].date == today && groups[1].date == yesterday, "日志按日期分组且最新日期在前")
        check(groups[0].events.count == 2 && groups[0].events[0].date > groups[0].events[1].date, "组内事件按时间倒序")
        let dayData = try encoder.encode(dayEvents.filter { yesterdayRange.contains($0.date, now: now, calendar: calendar) })
        let dayExport = try JSONDecoder().decode([AudioEvent].self, from: dayData)
        check(dayExport.count == 1 && dayExport[0].date == yesterday, "导出只包含筛选日期的记录")

        let fileLine = "          SSServerImp.cpp:1510  clientPID 999123(SoundProbe), ssid 4097, audio data size 162516, audio file path /System/Library/Sounds/Tink.aiff, customVibeDataProvided 0, inClientAudioSessionID: 0"
        let requestLine = "          SSServerImp.cpp:741   -> Incoming Request : actionID 4097, inClientPID 999123(SoundProbe), inBehavior 0, customVibeDataProvided 0, loop 0"
        let ncRequestLine = "          SSServerImp.cpp:741   -> Incoming Request : actionID 4098, inClientPID 751(NotificationCent), inBehavior 0"
        let noticeLine = "Playing notification sound { nam: newMsgComeIn.caf } for com.tencent.WeWorkMac"
        check(SoundLogLine.parse(fileLine) == .soundFile(pid: 999123, path: "/System/Library/Sounds/Tink.aiff"), "解析系统音效文件")
        check(SoundLogLine.parse(requestLine) == .request(pid: 999123, process: "SoundProbe", actionID: 4097), "解析系统音效请求方")
        check(SoundLogLine.parse(noticeLine) == .notification(bundleID: "com.tencent.WeWorkMac", sound: "newMsgComeIn.caf"), "解析通知音效来源应用")
        check(SoundLogLine.parse("Playing sound Glass.aiff for 5198CA23") == nil, "忽略无来源的通知播放日志")

        let tracer = AudioMonitor(persistHistory: false)
        let soundTime = Date()
        tracer.handle(SoundLogLine.parse(fileLine)!, from: 34828, at: soundTime)
        tracer.handle(SoundLogLine.parse(requestLine)!, from: 34828, at: soundTime)
        tracer.handle(SoundLogLine.parse(requestLine)!, from: 34828, at: soundTime.addingTimeInterval(0.01))
        check(tracer.events.count == 1 && tracer.events[0].kind == .systemSound, "系统音效请求只记录一次")
        check(tracer.events[0].pid == 999123 && tracer.events[0].processName == "SoundProbe" && tracer.events[0].sound == "Tink.aiff",
              "系统音效归属到真实请求进程")
        tracer.handle(SoundLogLine.parse(noticeLine)!, from: 751, at: soundTime.addingTimeInterval(5))
        tracer.handle(SoundLogLine.parse(ncRequestLine)!, from: 34828, at: soundTime.addingTimeInterval(5.01))
        check(tracer.events.count == 2 && tracer.events[0].kind == .notificationSound, "通知音效不重复记为通知中心")
        check(tracer.events[0].bundleID == "com.tencent.WeWorkMac" && tracer.events[0].processName == "NotificationCenter"
              && tracer.events[0].sound == "newMsgComeIn.caf", "通知音效归属到发通知的应用")
        tracer.handle(SoundLogLine.parse(ncRequestLine)!, from: 34828, at: soundTime.addingTimeInterval(9))
        check(tracer.events.count == 3 && tracer.events[0].kind == .systemSound && tracer.events[0].pid == 751, "无通知来源时保留通知中心请求")
        let legacy = try JSONDecoder().decode([AudioEvent].self, from: Data(#"[{"id":"9BEC2EC5-0000-0000-0000-000000000000","date":0,"appName":"旧记录","processName":"a","pid":1,"kind":"outputStarted","devices":[]}]"#.utf8))
        check(legacy.count == 1 && legacy[0].sound == nil, "兼容旧版历史记录")

        let live = AudioMonitor(persistHistory: false)
        live.start()
        check(live.errorMessage == nil, "本机 Core Audio 进程列表读取成功")
        check(!live.outputDevice.isEmpty, "本机输出设备读取成功")
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0", "/System/Library/Sounds/Hero.aiff"]
        try player.run()
        let pid = player.processIdentifier
        var sawActive = false
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if live.apps.contains(where: { $0.processes.contains { $0.pid == pid } }) { sawActive = true }
        }
        player.waitUntilExit()
        check(player.terminationStatus == 0, "静音测试播放器正常退出")
        check(sawActive, "真实播放器运行时显示为活动应用")
        check(live.events.contains { $0.pid == pid && $0.kind == .outputStarted }, "真实音频开始事件被捕获")
        check(live.events.contains { $0.pid == pid && $0.kind == .outputStopped }, "真实音频停止事件被捕获")
        check(!live.apps.contains { $0.processes.contains { $0.pid == pid } }, "播放器退出后移出当前列表")
        check(live.traceError == nil, "系统音效日志流持续运行")
        live.stop()
        check(!live.isMonitoring && live.apps.isEmpty, "暂停移除监听并清空实时状态")
        let count = live.events.count
        live.start()
        check(live.isMonitoring && live.errorMessage == nil && live.events.count >= count, "继续监控保留历史")
        live.stop()
        print("\(checks) checks passed")
    }
}
