import AppKit
import Darwin

struct AppIdentity {
    let name: String
    let bundleID: String?
    let icon: NSImage
    let processName: String
    let pid: pid_t

    var key: String { bundleID ?? "pid:\(pid)" }
}

enum AppResolver {
    static func resolve(bundleID: String, viaProcess processName: String, pid: pid_t) -> AppIdentity {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            return AppIdentity(name: app.localizedName ?? bundleID, bundleID: bundleID,
                               icon: app.icon ?? genericIcon, processName: processName, pid: pid)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let identity = bundleIdentity(path: url.path + "/", pid: pid, processName: processName) {
            return identity
        }
        return AppIdentity(name: bundleID, bundleID: bundleID, icon: genericIcon, processName: processName, pid: pid)
    }

    static func resolve(pid: pid_t, bundleIDHint: String?, nameHint: String? = nil) -> AppIdentity {
        let path = executablePath(of: pid)
        let processName = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? nameHint ?? "PID \(pid)"

        if let path, let identity = bundleIdentity(path: path, pid: pid, processName: processName) {
            return identity
        }
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil {
            return identity(app: app, pid: pid, processName: processName)
        }
        if let hint = bundleIDHint,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == hint }) {
            return identity(app: app, pid: pid, processName: processName)
        }

        var parent = pid
        var visited = Set<pid_t>()
        for _ in 0..<12 {
            guard visited.insert(parent).inserted, let next = parentPID(of: parent), next > 1 else { break }
            parent = next
            if let parentPath = executablePath(of: parent),
               let identity = bundleIdentity(path: parentPath, pid: pid, processName: processName) {
                return identity
            }
        }

        return AppIdentity(name: processName, bundleID: bundleIDHint,
                           icon: path.map { NSWorkspace.shared.icon(forFile: $0) } ?? genericIcon,
                           processName: processName, pid: pid)
    }

    private static func identity(app: NSRunningApplication, pid: pid_t, processName: String) -> AppIdentity {
        AppIdentity(name: app.localizedName ?? processName, bundleID: app.bundleIdentifier,
                    icon: app.icon ?? genericIcon, processName: processName, pid: pid)
    }

    private static func bundleIdentity(path: String, pid: pid_t, processName: String) -> AppIdentity? {
        guard let range = path.range(of: ".app/") else { return nil }
        let appPath = String(path[..<range.lowerBound]) + ".app"
        guard let bundle = Bundle(path: appPath) else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        return AppIdentity(name: name, bundleID: bundle.bundleIdentifier,
                           icon: NSWorkspace.shared.icon(forFile: appPath), processName: processName, pid: pid)
    }

    private static var genericIcon: NSImage {
        NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return count > 0 ? String(cString: buffer) : nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
