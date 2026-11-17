import AppKit
import Foundation

@MainActor
func runSuite9VersionAndDiagnosticsTests(_ t: TestHarness, testPasteboard: NSPasteboard, testTempDirURL: URL) {
    print("\n🔹 Suite 9: Version Metadata & Local Diagnostics")

    // 1. Version metadata is non-empty and matches semantic version format
    let ver = ClipLineVersion.current
    let parts = ver.split(separator: ".")
    t.check(
        parts.count == 3 && parts.allSatisfy({ Int($0) != nil }),
        "ClipLineVersion.current is a valid x.y.z semantic version (\(ver))"
    )
    t.check(
        ClipLineVersion.cliBanner.contains("ClipLine \(ver)") &&
        ClipLineVersion.cliBanner.contains("-apple-macosx"),
        "ClipLineVersion.cliBanner includes version and target architecture (\(ClipLineVersion.cliBanner))"
    )

    // 2. Event logging writes sanitized lines and rotates oversized logs
    let logFileURL = testTempDirURL.appendingPathComponent("logs/test-events.log")
    DiagnosticsService.recordEvent(
        category: "launch",
        message: "daemon_started\nwith_newline",
        logFileURL: logFileURL
    )
    DiagnosticsService.recordEvent(
        category: "hotkey_failure",
        message: "action=capture status=-9878",
        logFileURL: logFileURL
    )
    let recentLines = DiagnosticsService.readRecentLogLines(limit: 5, logFileURL: logFileURL)
    t.check(
        recentLines.count == 2 &&
        recentLines[0].contains("[v\(ver)] [launch] daemon_started with_newline") &&
        recentLines[1].contains("[hotkey_failure] action=capture status=-9878"),
        "DiagnosticsService.recordEvent appends sanitized single-line event records"
    )

    // Verify log rotation bounds file when maxBytes threshold is exceeded
    for idx in 0..<150 {
        DiagnosticsService.recordEvent(
            category: "probe",
            message: "event_\(idx)",
            logFileURL: logFileURL,
            maxBytes: 1024
        )
    }
    let tailAfterRotation = DiagnosticsService.readRecentLogLines(limit: 200, logFileURL: logFileURL)
    let rotatedBytes = (try? FileManager.default.attributesOfItem(atPath: logFileURL.path)[.size] as? NSNumber)?.intValue ?? Int.max
    t.check(
        rotatedBytes <= 1024 && tailAfterRotation.count >= 5 && tailAfterRotation.last?.contains("event_149") == true,
        "DiagnosticsService.recordEvent rotates log file within maxBytes budget (\(rotatedBytes)B <= 1024B, \(tailAfterRotation.count) lines retained)"
    )

        // 2. Verify oversized single event (including multi-byte UTF-8) is truncated safely within maxBytes
        let oversizedMessage = "utf8_trunc_marker_" + String(repeating: "🔥截屏", count: 400)
        DiagnosticsService.recordEvent(
            category: "probe",
            message: oversizedMessage,
            logFileURL: logFileURL,
            maxBytes: 256
        )
        let bytesAfterOversized = (try? FileManager.default.attributesOfItem(atPath: logFileURL.path)[.size] as? NSNumber)?.intValue ?? Int.max
        let linesAfterOversized = DiagnosticsService.readRecentLogLines(limit: 5, logFileURL: logFileURL)
        t.check(
            bytesAfterOversized <= 256 &&
            linesAfterOversized.last?.contains("utf8_trunc_marker_🔥截屏") == true,
            "DiagnosticsService.recordEvent truncates oversized multi-byte UTF-8 event within maxBytes (\(bytesAfterOversized)B <= 256B)"
        )

    // 3. collectReport produces accurate read-only text & JSON without creating directories/files or touching live settings
    let diagSuiteName = "ClipLineDoctorTests_\(UUID().uuidString)"
    if let diagDefaults = UserDefaults(suiteName: diagSuiteName) {
        defer { diagDefaults.removePersistentDomain(forName: diagSuiteName) }
        let nonExistentDir = testTempDirURL.appendingPathComponent("absent_support_dir", isDirectory: true)
        let missingLockPath = nonExistentDir.appendingPathComponent("clipline_daemon.lock").path
        let report = DiagnosticsService.collectReport(
            defaults: diagDefaults,
            logFileURL: logFileURL,
            lockPath: missingLockPath,
            preflightAccess: { true },
            windowProbe: { true }
        )
        t.check(
            !FileManager.default.fileExists(atPath: nonExistentDir.path) &&
            !FileManager.default.fileExists(atPath: missingLockPath),
            "DiagnosticsService.collectReport is strictly read-only and does not create missing lock directories or files"
        )
        t.check(
            report.version == ver &&
            report.daemonLockHeldByRunningProcess == false &&
            report.screenCapturePreflightGranted == true &&
            report.windowTitleProbeStatus == "authorized_or_inconclusive" &&
            report.configuredShortcuts["capture"] == "⌃X" &&
            report.recentLogTail.count <= 10 &&
            !report.recentLogTail.isEmpty,
            "DiagnosticsService.collectReport gathers version, lock status, permissions, shortcuts, and log tail"
        )

        // Verify held exclusive lock & denied window probe detection
        let activeLockPath = testTempDirURL.appendingPathComponent("active_daemon.lock").path
        let heldFD = open(activeLockPath, O_CREAT | O_RDWR, 0o600)
        if heldFD >= 0 {
            defer {
                _ = flock(heldFD, LOCK_UN)
                close(heldFD)
            }
            _ = flock(heldFD, LOCK_EX | LOCK_NB)
            let heldReport = DiagnosticsService.collectReport(
                defaults: diagDefaults,
                logFileURL: logFileURL,
                lockPath: activeLockPath,
                preflightAccess: { false },
                windowProbe: { false }
            )
            t.check(
                heldReport.daemonLockHeldByRunningProcess == true &&
                heldReport.screenCapturePreflightGranted == false &&
                heldReport.windowTitleProbeStatus == "denied_on_external_windows",
                "DiagnosticsService.collectReport detects active exclusive daemon lock without blocking and reports denied probe states"
            )
        } else {
            t.check(false, "Opened temporary lock file for active-daemon probe test")
        }

        let textOut = report.formattedText()
        let jsonOut = (try? report.formattedJSON()) ?? ""
        t.check(
            textOut.contains("ClipLine Doctor (\(ver)") &&
            textOut.contains("Screen Recording:   preflight=granted") &&
            textOut.contains("live Carbon hotkey registration belongs to the running daemon process") &&
            jsonOut.contains("\"version\" : \"\(ver)\""),
            "DiagnosticReport formats both human-readable text and structured JSON with explicit hotkey scope note"
        )
    } else {
        t.check(false, "Created isolated UserDefaults suite for doctor report test")
    }

    // 4. Test suite filter parsing and non-matching filter rejection
    t.check(
        parseTestSuiteFilter(arguments: ["clipline-tests", "--filter", "Suite 5"]) == "Suite 5" &&
        parseTestSuiteFilter(arguments: ["clipline-tests", "--filter=updater"]) == "updater",
        "parseTestSuiteFilter supports both '--filter <value>' and '--filter=<value>'"
    )
}
