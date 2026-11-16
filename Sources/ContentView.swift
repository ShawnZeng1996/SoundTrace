import SwiftUI
import UniformTypeIdentifiers

private enum AudioFilter: CaseIterable {
    case output, all

    var title: LocalizedStringKey {
        switch self {
        case .output: return "音频输出"
        case .all: return "输出与输入"
        }
    }
}

struct ContentView: View {
    @ObservedObject var monitor: AudioMonitor
    @State private var filter = AudioFilter.output
    @State private var search = ""
    @State private var confirmClear = false
    @State private var exportError: String?
    @State private var dateRange: HistoryDateRange

    init(monitor: AudioMonitor, initialDateRange: HistoryDateRange = HistoryDateRange()) {
        self.monitor = monitor
        _dateRange = State(initialValue: initialDateRange)
    }

    private var visibleApps: [ActiveAudioApp] {
        monitor.apps.filter {
            (filter == .all || $0.output) && matches($0.identity.name, $0.processes.map(\.processName).joined(separator: " "))
        }
    }

    private var visibleEvents: [AudioEvent] {
        monitor.events.filter {
            dateRange.contains($0.date)
                && (filter == .all || $0.kind.isOutput)
                && matches($0.appName, $0.processName)
        }
    }

    private func dayBinding(_ keyPath: WritableKeyPath<HistoryDateRange, Date?>) -> Binding<Date> {
        Binding {
            dateRange[keyPath: keyPath] ?? Date()
        } set: { date in
            dateRange[keyPath: keyPath] = Calendar.current.isDateInToday(date) ? nil : Calendar.current.startOfDay(for: date)
        }
    }

    private var logDays: [AudioLogDay] { AudioLogDay.grouped(visibleEvents) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    status
                    currentApps
                    TimelineView(.periodic(from: .now, by: 60)) { _ in history }
                }
                .padding(24)
            }
            Divider()
            HStack(spacing: 6) {
                Text("仅观察音频通道与系统音效日志，不录音、不联网。静音播放也可能显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("清空全部记录？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { monitor.clearHistory() }
        } message: {
            Text("所有日期的已保存记录都会被清空。")
        }
        .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("音源排查").font(.title2.weight(.semibold))
                Text("找到正在使用音频的应用").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(monitor.isMonitoring && monitor.errorMessage == nil ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(monitor.isMonitoring ? "实时监控" : "监控已暂停")
                    .font(.subheadline)
            }
            Button(monitor.isMonitoring ? "暂停" : "继续") {
                if monitor.isMonitoring { monitor.stop() } else { monitor.start() }
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前输出设备").font(.caption).foregroundStyle(.secondary)
                    Text(monitor.outputDevice.isEmpty ? String(localized: "正在读取…") : monitor.outputDevice)
                        .font(.headline)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(monitor.apps.filter(\.output).count)").font(.title.weight(.semibold)).monospacedDigit()
                        Text("个应用输出中").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = monitor.errorMessage {
                Text(error).font(.subheadline).foregroundStyle(.orange)
            }
            if let error = monitor.storageError {
                Text(error).font(.subheadline).foregroundStyle(.orange)
            }
            if let error = monitor.traceError {
                Text(error).font(.subheadline).foregroundStyle(.orange)
            }
            HStack(spacing: 16) {
                Picker("显示范围", selection: $filter) {
                    ForEach(AudioFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                Spacer()
                TextField("搜索应用或进程", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var currentApps: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("正在使用音频", detail: "\(visibleApps.count) 个应用")
            if visibleApps.isEmpty {
                emptyState(title: !search.isEmpty ? "没有匹配的应用" : monitor.isMonitoring ? "暂无应用使用音频" : "监控已暂停",
                           subtitle: monitor.isMonitoring ? "声音响起时，应用会出现在这里；停止后可在下方回查。" : "继续监控后将恢复记录。")
            } else {
                VStack(spacing: 0) {
                    ForEach(visibleApps) { app in
                        activeRow(app)
                        if app.id != visibleApps.last?.id { Divider().padding(.leading, 70) }
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("最近记录", detail: "\(visibleEvents.count) 条 · 最多保留 500 条")
                Spacer()
                Button("导出") { exportHistory() }.disabled(visibleEvents.isEmpty)
                Button("清空全部") { confirmClear = true }.disabled(monitor.events.isEmpty)
            }
            HStack(spacing: 8) {
                let bounds = dateRange.bounds()
                Text("日期")
                DatePicker("开始日期", selection: dayBinding(\.start),
                           in: ...bounds.upperBound.addingTimeInterval(86_399), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .fixedSize()
                Text("至").foregroundStyle(.secondary)
                DatePicker("结束日期", selection: dayBinding(\.end), in: bounds.lowerBound..., displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .fixedSize()
                Spacer()
            }
            if visibleEvents.isEmpty {
                emptyState(title: !search.isEmpty ? "没有匹配的记录" : "该时间段没有音频记录",
                           subtitle: "记录保存在本机，可调整日期区间查看。")
            } else {
                ForEach(logDays) { day in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Text(day.date, format: .dateTime.year().month().day()).font(.subheadline.weight(.medium))
                            Text("\(day.events.count) 条").font(.caption).foregroundStyle(.secondary)
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(day.events) { event in
                                eventRow(event)
                                if event.id != day.events.last?.id { Divider().padding(.leading, 18) }
                            }
                        }
                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func emptyState(title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func activeRow(_ app: ActiveAudioApp) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: app.identity.icon).resizable().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(app.identity.name).font(.headline).textSelection(.enabled)
                    if app.output { badge(String(localized: "输出中"), color: .blue) }
                    if app.input { badge(String(localized: "输入中"), color: .orange) }
                }
                Text(app.processes.map { "\($0.processName) · PID \($0.pid)" }.joined(separator: "  /  "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                let sources = triggerSources(for: app)
                if !sources.isEmpty {
                    Text("触发来源：\(sources.joined(separator: String(localized: "、")))")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.purple).textSelection(.enabled)
                }
                if !app.devices.isEmpty {
                    Text(app.devices.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(app.since, style: .time).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(18)
    }

    private func eventRow(_ event: AudioEvent) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.date, format: .dateTime.hour().minute().second()).monospacedDigit()
                Text(event.date, format: .dateTime.month().day()).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .frame(width: 76, alignment: .leading)
            badge(event.kind.title, color: event.kind.isTrigger ? .purple : event.kind.isStart ? (event.kind.isOutput ? .blue : .orange) : .secondary)
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.appName).font(.subheadline.weight(.medium))
                Text(verbatim: "\(event.processName) · PID \(event.pid)" + (event.sound.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            Spacer(minLength: 4)
            Text(event.devices.joined(separator: " / "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: 180, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
    }

    private func triggerSources(for app: ActiveAudioApp) -> [String] {
        guard app.processes.contains(where: { $0.processName == "systemsoundserverd" }) else { return [] }
        let start = app.since.addingTimeInterval(-3)
        var names: [String] = []
        for event in monitor.events where event.kind.isTrigger && event.date >= start {
            let name = event.sound.map { String(localized: "\(event.appName)（\($0)）") } ?? event.appName
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    private func matches(_ name: String, _ process: String) -> Bool {
        search.isEmpty || name.localizedCaseInsensitiveContains(search) || process.localizedCaseInsensitiveContains(search)
    }

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String(localized: "音频记录.json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(visibleEvents).write(to: url, options: .atomic)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
