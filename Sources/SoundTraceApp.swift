import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var monitor: AudioMonitor?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Self.monitor?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first(where: { $0.title == "音源排查" })?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

struct SoundTraceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor: AudioMonitor

    init() {
        let monitor = AudioMonitor()
        _monitor = StateObject(wrappedValue: monitor)
        AppDelegate.monitor = monitor
        monitor.start()
    }

    var body: some Scene {
        Window("音源排查", id: "main") {
            ContentView(monitor: monitor)
        }
        .defaultSize(width: 920, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            StatusMenu(monitor: monitor)
        } label: {
            Image(systemName: monitor.isMonitoring ? "waveform.circle.fill" : "waveform.circle")
            if monitor.apps.contains(where: \.output) {
                Text("\(monitor.apps.filter(\.output).count)")
            }
        }
    }
}

private struct StatusMenu: View {
    @ObservedObject var monitor: AudioMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(monitor.isMonitoring ? "音源排查 · 监控中" : "音源排查 · 已暂停")
        Divider()
        let outputs = monitor.apps.filter(\.output)
        if outputs.isEmpty {
            Text("暂无应用输出音频")
        } else {
            ForEach(outputs) { app in
                Text("\(app.identity.name) · 输出中")
            }
        }
        if let error = monitor.errorMessage { Text(error) }
        Divider()
        Button("打开音源排查") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button(monitor.isMonitoring ? "暂停监控" : "继续监控") {
            if monitor.isMonitoring { monitor.stop() } else { monitor.start() }
        }
        Divider()
        Button("退出") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
