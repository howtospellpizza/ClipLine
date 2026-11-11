import AppKit
import CoreGraphics
import Foundation

// MARK: - Privacy-Preserving Event Log & Read-Only `--doctor` Diagnostics

struct DiagnosticDisplaySummary: Codable, Equatable {
    let index: Int
    let widthPoints: Int
    let heightPoints: Int
    let backingScaleFactor: Double
}

struct DiagnosticReport: Codable, Equatable {
    let version: String
    let architecture: String
    let macOSVersion: String
    let executablePath: String
    let daemonLockHeldByRunningProcess: Bool
    let screenCapturePreflightGranted: Bool
    let windowTitleProbeStatus: String
    let displays: [DiagnosticDisplaySummary]
    let configuredShortcuts: [String: String]
    let shortcutNote: String
    let logFilePath: String
    let recentLogTail: [String]
    let macOSCrashReportsDirectory: String

    func formattedText() -> String {
        var lines: [String] = []
        lines.append("ClipLine Doctor (\(version) · \(architecture))")
        lines.append("================================================")
        lines.append("macOS:              \(macOSVersion)")
        lines.append("Executable:         \(executablePath)")
        lines.append("Daemon running:     \(daemonLockHeldByRunningProcess ? "yes (lock held)" : "no (lock unlocked)")")
        lines.append("Screen Recording:   preflight=\(screenCapturePreflightGranted ? "granted" : "denied"), windowTitleProbe=\(windowTitleProbeStatus)")
        if displays.isEmpty {
            lines.append("Displays:           none detected")
        } else {
            let summary = displays.map {
                "#\($0.index) \($0.widthPoints)x\($0.heightPoints)pt @\(String(format: "%.1fx", $0.backingScaleFactor))"
            }.joined(separator: ", ")
            lines.append("Displays (\(displays.count)):       \(summary)")
        }
        let scOrder = ["capture", "capture-secondary", "clipboard"]
        let scSummary = scOrder.compactMap { key in
            configuredShortcuts[key].map { "\(key)=\($0)" }
        }.joined(separator: ", ")
        lines.append("Configured hotkeys: \(scSummary)")
        lines.append("Hotkey note:        \(shortcutNote)")
        lines.append("Event log path:     \(logFilePath)")
        lines.append("macOS crash dir:    \(macOSCrashReportsDirectory)")
        if !recentLogTail.isEmpty {
            lines.append("\nRecent diagnostic events (last \(recentLogTail.count)):")
            for entry in recentLogTail {
                lines.append("  \(entry)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func formattedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

enum DiagnosticsService {
    static var defaultLogFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Logs/ClipLine", isDirectory: true)
            .appendingPathComponent("clipline-events.log", isDirectory: false)
    }

    static var macOSDiagnosticReportsPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
            .path
    }

    /// Appends a single privacy-safe operational event line (`launch`, `permission_denied`, `hotkey_failure`, `capture_aborted`, `update_error`).
    /// Never pass user clipboard text, OCR strings, window titles, or image paths.
    static func recordEvent(
        category: String,
        message: String,
        logFileURL: URL? = nil,
        maxBytes: Int = 256 * 1024
    ) {
        #if CLIPLINE_TEST
        guard let logFileURL else { return }
        #else
        let logFileURL = logFileURL ?? defaultLogFileURL
        #endif
        let sanitizedCategory = category
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let sanitizedMessage = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [v\(ClipLineVersion.current)] [\(sanitizedCategory)] \(sanitizedMessage)\n"
        guard let data = line.data(using: .utf8) else { return }

        let dirURL = logFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
               let size = attrs[.size] as? NSNumber,
               size.intValue > maxBytes,
               let existing = try? String(contentsOf: logFileURL, encoding: .utf8) {
                let allLines = existing.components(separatedBy: "\n").filter { !$0.isEmpty }
                let kept = allLines.suffix(100).joined(separator: "\n") + "\n"
                try? kept.data(using: .utf8)?.write(to: logFileURL, options: .atomic)
            }
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
    }

    static func readRecentLogLines(
        limit: Int = 10,
        logFileURL: URL = defaultLogFileURL
    ) -> [String] {
        guard limit > 0,
              let content = try? String(contentsOf: logFileURL, encoding: .utf8) else {
            return []
        }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return Array(lines.suffix(limit))
    }

    /// Probes whether another process currently holds an exclusive flock on the daemon lock file without keeping it locked.
    static func isDaemonLockHeld(atPath lockPath: String = SingleInstanceLock.lockFilePath) -> Bool {
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    @MainActor
    static func collectReport(
        defaults: UserDefaults = UserDefaults(suiteName: ShortcutConfigurationStore.suiteName)!,
        logFileURL: URL = defaultLogFileURL,
        lockPath: String = SingleInstanceLock.lockFilePath,
        preflightAccess: () -> Bool = { CGPreflightScreenCaptureAccess() },
        windowProbe: () -> Bool = { ScreenCaptureOverlayController.hasLiveScreenCaptureAccess(preflight: { true }) }
    ) -> DiagnosticReport {
        let config = ShortcutConfigurationStore(defaults: defaults).load()
        let configuredMap: [String: String] = [
            "capture": config.capture.displayString,
            "capture-secondary": config.captureSecondary.displayString,
            "clipboard": config.clipboard.displayString
        ]

        let displays: [DiagnosticDisplaySummary] = NSScreen.screens.enumerated().map { idx, screen in
            DiagnosticDisplaySummary(
                index: idx + 1,
                widthPoints: Int(screen.frame.width.rounded()),
                heightPoints: Int(screen.frame.height.rounded()),
                backingScaleFactor: Double(screen.backingScaleFactor)
            )
        }

        let preflight = preflightAccess()
        let probeAllowed = windowProbe()
        let probeStatus = probeAllowed ? "authorized_or_inconclusive" : "denied_on_external_windows"

        return DiagnosticReport(
            version: ClipLineVersion.current,
            architecture: ClipLineVersion.architectureTag,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            executablePath: CommandLine.arguments.first ?? "clipline",
            daemonLockHeldByRunningProcess: isDaemonLockHeld(atPath: lockPath),
            screenCapturePreflightGranted: preflight,
            windowTitleProbeStatus: probeStatus,
            displays: displays,
            configuredShortcuts: configuredMap,
            shortcutNote: "Shows persisted UserDefaults bindings; live Carbon hotkey registration belongs to the running daemon process.",
            logFilePath: logFileURL.path,
            recentLogTail: readRecentLogLines(limit: 10, logFileURL: logFileURL),
            macOSCrashReportsDirectory: macOSDiagnosticReportsPath
        )
    }
}
