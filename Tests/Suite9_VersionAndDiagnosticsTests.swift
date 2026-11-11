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
    t.check(
        tailAfterRotation.count <= 105 && tailAfterRotation.last?.contains("event_149") == true,
        "DiagnosticsService.recordEvent rotates log file when size exceeds maxBytes (\(tailAfterRotation.count) lines retained)"
    )

    // 3. collectReport produces accurate read-only text & JSON without touching live settings
    let diagSuiteName = "ClipLineDoctorTests_\(UUID().uuidString)"
    if let diagDefaults = UserDefaults(suiteName: diagSuiteName) {
        defer { diagDefaults.removePersistentDomain(forName: diagSuiteName) }
        let unlockedLockPath = testTempDirURL.appendingPathComponent("unlocked_doctor.lock").path
        let report = DiagnosticsService.collectReport(
            defaults: diagDefaults,
            logFileURL: logFileURL,
            lockPath: unlockedLockPath,
            preflightAccess: { true },
            windowProbe: { true }
        )
        t.check(
            report.version == ver &&
            report.daemonLockHeldByRunningProcess == false &&
            report.screenCapturePreflightGranted == true &&
            report.windowTitleProbeStatus == "authorized_or_inconclusive" &&
            report.configuredShortcuts["capture"] == "⌃X" &&
            report.recentLogTail.count == 10,
            "DiagnosticsService.collectReport gathers version, lock status, permissions, shortcuts, and log tail"
        )
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
