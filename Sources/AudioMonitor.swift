import AppKit
import Combine
import CoreAudio

struct ActiveAudioApp: Identifiable {
    let id: String
    let identity: AppIdentity
    let processes: [AppIdentity]
    let output: Bool
    let input: Bool
    let devices: [String]
    let since: Date
}

struct AudioEvent: Identifiable, Codable {
    var id = UUID()
    let date: Date
    let appName: String
    let bundleID: String?
    let processName: String
    let pid: pid_t
    let kind: Kind
    let devices: [String]
    var sound: String? = nil

    enum Kind: String, Codable {
        case outputStarted, outputStopped, inputStarted, inputStopped, systemSound, notificationSound
        var title: String {
            switch self {
            case .outputStarted: return String(localized: "开始输出")
            case .outputStopped: return String(localized: "停止输出")
            case .inputStarted: return String(localized: "开始输入")
            case .inputStopped: return String(localized: "停止输入")
            case .systemSound: return String(localized: "系统音效")
            case .notificationSound: return String(localized: "通知音效")
            }
        }
        var isOutput: Bool { self != .inputStarted && self != .inputStopped }
        var isStart: Bool { self == .outputStarted || self == .inputStarted }
        var isTrigger: Bool { self == .systemSound || self == .notificationSound }
    }
}

struct HistoryDateRange: Hashable {
    // nil means "today", so an untouched range keeps following the current day across midnight.
    var start: Date?
    var end: Date?

    func bounds(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let first = calendar.startOfDay(for: start ?? now)
        let last = calendar.startOfDay(for: end ?? now)
        return min(first, last)...max(first, last)
    }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        bounds(now: now, calendar: calendar).contains(calendar.startOfDay(for: date))
    }
}

struct AudioLogDay: Identifiable {
    let date: Date
    let events: [AudioEvent]
    var id: Date { date }

    static func grouped(_ events: [AudioEvent], calendar: Calendar = .current) -> [AudioLogDay] {
        Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
            .map { AudioLogDay(date: $0.key, events: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
    }
}

final class AudioMonitor: ObservableObject {
    @Published private(set) var apps: [ActiveAudioApp] = []
    @Published private(set) var events: [AudioEvent] = []
    @Published private(set) var isMonitoring = false
    @Published private(set) var outputDevice = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var storageError: String?
    @Published private(set) var traceError: String?

    var onEvent: ((AudioEvent) -> Void)?
    private let soundLog = SoundLogStream()
    private var soundFiles: [pid_t: String] = [:]
    private var lastRequests: [String: Date] = [:]
    private var lastNotification: (pid: pid_t, date: Date)?
    private var previous: [AudioObjectID: AudioProcessSample] = [:]
    private var identities: [AudioObjectID: AppIdentity] = [:]
    private var startedAt: [String: Date] = [:]
    private var timer: Timer?
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var listeners: [Listener] = []
    private var observedObjects = Set<AudioObjectID>()
    private var saveWork: DispatchWorkItem?
    private let historyURL: URL?

    init(persistHistory: Bool = true) {
        if persistHistory {
            historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SoundTrace", isDirectory: true).appendingPathComponent("history.json")
        } else {
            historyURL = nil
        }
        if let url = historyURL, FileManager.default.fileExists(atPath: url.path) {
            do {
                events = Array(try JSONDecoder().decode([AudioEvent].self, from: Data(contentsOf: url)).prefix(500))
            } catch {
                storageError = String(localized: "历史记录未能读取")
            }
        }
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
        addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice)
        addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyServiceRestarted)
        refresh()
        traceError = nil
        soundLog.start(onLine: { [weak self] line, sender in self?.handle(line, from: sender, at: Date()) },
                       onFailure: { [weak self] in self?.traceError = String(localized: "无法读取系统音效来源") })
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        soundLog.stop()
        soundFiles = [:]
        lastRequests = [:]
        lastNotification = nil
        removeListeners()
        isMonitoring = false
        apps = []
        previous = [:]
        identities = [:]
        startedAt = [:]
        flushHistory()
    }

    func clearHistory() {
        events = []
        flushHistory()
    }

    func refresh() {
        guard isMonitoring else { return }
        do {
            let objects = try CoreAudioReader.processIDs()
            synchronizeListeners(objects: Set(objects))
            apply(samples: objects.compactMap(CoreAudioReader.sample), at: Date())
            outputDevice = CoreAudioReader.defaultOutputName()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            apps = []
        }
    }

    func apply(samples: [AudioProcessSample], at date: Date) {
        let samples = samples.filter { $0.pid != getpid() }
        let current = Dictionary(uniqueKeysWithValues: samples.map { ($0.objectID, $0) })
        let previousIdentities = identities
        for sample in samples {
            if identities[sample.objectID]?.pid != sample.pid {
                identities[sample.objectID] = AppResolver.resolve(pid: sample.pid, bundleIDHint: sample.bundleID)
            }
        }
        for object in Set(previous.keys).union(current.keys).sorted() {
            let before = previous[object]
            let after = current[object]
            if let before, let after, before.pid != after.pid {
                let old = previousIdentities[object]!
                transition(before: before, after: nil, identity: old, at: date)
                transition(before: nil, after: after, identity: identities[object]!, at: date)
            } else if let identity = identities[object] {
                transition(before: before, after: after, identity: identity, at: date)
            }
        }
        previous = current
        identities = identities.filter { current[$0.key] != nil }
        let active = samples.filter { $0.output || $0.input }
        let grouped = Dictionary(grouping: active) { identities[$0.objectID]!.key }
        startedAt = startedAt.filter { grouped[$0.key] != nil }
        apps = grouped.map { key, group in
            let sorted = group.sorted { $0.pid < $1.pid }
            let processes = sorted.compactMap { identities[$0.objectID] }
            let since = startedAt[key] ?? date
            startedAt[key] = since
            return ActiveAudioApp(id: key, identity: processes[0], processes: processes,
                                  output: group.contains { $0.output }, input: group.contains { $0.input },
                                  devices: Array(Set(group.flatMap(\.devices))).sorted(), since: since)
        }.sorted {
            if $0.output != $1.output { return $0.output }
            return $0.since > $1.since
        }
    }

    func handle(_ line: SoundLogLine, from sender: pid_t, at date: Date) {
        switch line {
        case .soundFile(let pid, let path):
            soundFiles[pid] = URL(fileURLWithPath: path).lastPathComponent
        case .notification(let bundleID, let sound):
            lastNotification = (sender, date)
            let identity = AppResolver.resolve(bundleID: bundleID, viaProcess: "NotificationCenter", pid: sender)
            record(identity: identity, kind: .notificationSound, devices: [], sound: sound, at: date)
        case .request(let pid, let process, let actionID):
            guard pid != getpid() else { return }
            let sound = soundFiles.removeValue(forKey: pid)
            if let notice = lastNotification, notice.pid == pid, date.timeIntervalSince(notice.date) < 2 { return }
            let key = "\(pid):\(actionID)"
            lastRequests = lastRequests.filter { date.timeIntervalSince($0.value) < 1 }
            guard lastRequests[key] == nil else { return }
            lastRequests[key] = date
            let identity = AppResolver.resolve(pid: pid, bundleIDHint: nil, nameHint: process)
            record(identity: identity, kind: .systemSound, devices: [], sound: sound, at: date)
        }
    }

    private func transition(before: AudioProcessSample?, after: AudioProcessSample?, identity: AppIdentity, at date: Date) {
        let devices = after?.devices.isEmpty == false ? after!.devices : before?.devices ?? []
        if (before?.output ?? false) != (after?.output ?? false) {
            record(identity: identity, kind: after?.output == true ? .outputStarted : .outputStopped, devices: devices, at: date)
        }
        if (before?.input ?? false) != (after?.input ?? false) {
            record(identity: identity, kind: after?.input == true ? .inputStarted : .inputStopped, devices: devices, at: date)
        }
    }

    private func record(identity: AppIdentity, kind: AudioEvent.Kind, devices: [String], sound: String? = nil, at date: Date) {
        let event = AudioEvent(date: date, appName: identity.name, bundleID: identity.bundleID,
                               processName: identity.processName, pid: identity.pid, kind: kind, devices: devices, sound: sound)
        events.insert(event, at: 0)
        if events.count > 500 { events.removeLast(events.count - 500) }
        onEvent?(event)
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushHistory() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func flushHistory() {
        saveWork?.cancel()
        guard let url = historyURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(events).write(to: url, options: .atomic)
            storageError = nil
        } catch {
            storageError = String(localized: "历史记录未能保存")
        }
    }

    private func addListener(object: AudioObjectID, selector: AudioObjectPropertySelector) {
        var address = CoreAudioReader.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            if selector == kAudioHardwarePropertyServiceRestarted {
                self?.removeListeners()
                self?.stop()
                self?.start()
            } else {
                self?.refresh()
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            listeners.append(Listener(object: object, address: address, block: block))
        }
    }

    private func synchronizeListeners(objects: Set<AudioObjectID>) {
        let removed = observedObjects.subtracting(objects)
        for index in listeners.indices.reversed() where removed.contains(listeners[index].object) {
            var listener = listeners.remove(at: index)
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
        for object in objects.subtracting(observedObjects) {
            addListener(object: object, selector: kAudioProcessPropertyIsRunningOutput)
            addListener(object: object, selector: kAudioProcessPropertyIsRunningInput)
        }
        observedObjects = objects
    }

    private func removeListeners() {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
        listeners = []
        observedObjects = []
    }
}
