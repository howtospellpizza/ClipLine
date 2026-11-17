import AppKit
import CoreGraphics
import Foundation

@MainActor
func runSuite3TranslateOCRAndLockTests(_ t: TestHarness, testPasteboard: NSPasteboard, testTempDirURL: URL) {
    let f = makeDefaultCaptureFixtures()
    let baseImg = f.baseImg
    let vm = f.makeViewModel()
    // Suite 3: URL Encoding, OCR Stale-Pasteboard Guard & Single-Instance Lock
    // -------------------------------------------------------------------------
    print("\n🔹 Suite 3: URL Encoding, OCR Pasteboard Guard & Single-Instance Lock")
    let trickyText = "Hello & World = 100% + #tag ?query; /path"
    let googleURL = PinSessionViewModel.buildGoogleTranslateURL(text: trickyText)
    t.check(googleURL != nil, "buildGoogleTranslateURL constructs valid URL for reserved characters")
    if let gURL = googleURL, let comps = URLComponents(url: gURL, resolvingAgainstBaseURL: false) {
        let textParam = comps.queryItems?.first(where: { $0.name == "text" })?.value
        t.check(
            textParam == trickyText,
            "URLComponents round-trips '&', '=', '+', '#', '?', ';' without parameter truncation",
            detail: "got \(String(describing: textParam))"
        )
    } else {
        t.check(false, "URLComponents parsed buildGoogleTranslateURL output")
    }

    let customURL = PinSessionViewModel.buildCustomTranslationURL(
        template: "https://example.com/translate?q={text}&from=ocr",
        text: "a&b=c+d#hash"
    )
    t.check(customURL != nil, "buildCustomTranslationURL constructs valid HTTPS URL")
    if let cURL = customURL, let comps = URLComponents(url: cURL, resolvingAgainstBaseURL: false) {
        let qVal = comps.queryItems?.first(where: { $0.name == "q" })?.value
        let fromVal = comps.queryItems?.first(where: { $0.name == "from" })?.value
        t.check(
            qVal == "a&b=c+d#hash" && fromVal == "ocr",
            "strictQueryValueAllowed prevents '&' or '#' in OCR text from injecting/truncating query items",
            detail: "q=\(String(describing: qVal)), from=\(String(describing: fromVal))"
        )
    } else {
        t.check(false, "URLComponents parsed buildCustomTranslationURL output")
    }

    let insecureHTTPURL = PinSessionViewModel.buildCustomTranslationURL(
        template: "http://example.com/translate?q={text}",
        text: "secret"
    )
    let fileSchemeURL = PinSessionViewModel.buildCustomTranslationURL(
        template: "file:///tmp/{text}",
        text: "secret"
    )
    let localhostHTTPURL = PinSessionViewModel.buildCustomTranslationURL(
        template: "http://127.0.0.1:8080/translate?q={text}",
        text: "hello"
    )
    t.check(
        insecureHTTPURL == nil && fileSchemeURL == nil && localhostHTTPURL != nil,
        "buildCustomTranslationURL rejects non-localhost HTTP and file:// schemes while allowing localhost HTTP and HTTPS"
    )

    // Verify per-host translation consent isolation (legacy global key only applies to translate.google.com, never custom hosts)
    let suiteName = "ClipLineConsentTests_\(UUID().uuidString)"
    if let testDefaults = UserDefaults(suiteName: suiteName) {
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        testDefaults.set(true, forKey: "ClipLineAllowWebTranslateFallback")
        t.check(
            PinSessionViewModel.hasStoredWebTranslateConsent(for: "translate.google.com", defaults: testDefaults) == true &&
            PinSessionViewModel.hasStoredWebTranslateConsent(for: "custom-api.example.com", defaults: testDefaults) == false,
            "Legacy global web-translate consent only applies to translate.google.com and does NOT bypass consent for custom hosts"
        )
        testDefaults.set(true, forKey: "ClipLineAllowWebTranslateFallback_custom-api.example.com")
        t.check(
            PinSessionViewModel.hasStoredWebTranslateConsent(for: "custom-api.example.com", defaults: testDefaults) == true &&
            PinSessionViewModel.hasStoredWebTranslateConsent(for: "other-host.example.com", defaults: testDefaults) == false,
            "Host-specific web-translate consent grants only the approved host"
        )
    }

    // Verify OCR stale pasteboard guard does NOT overwrite newer clipboard content
    testPasteboard.clearContents()
    testPasteboard.setString("INITIAL_CLIPBOARD", forType: .string)
    let snapshotCount = testPasteboard.changeCount
    testPasteboard.clearContents()
    testPasteboard.setString("NEWER_USER_COPY", forType: .string)
    vm.applyOCRResult("STALE_OCR_TEXT", andTranslate: false, expectedChangeCount: snapshotCount, pasteboard: testPasteboard)
    t.check(
        testPasteboard.string(forType: .string) == "NEWER_USER_COPY",
        "applyOCRResult skips clipboard write when pasteboard.changeCount changed during async OCR"
    )
    let matchingCount = testPasteboard.changeCount
    vm.applyOCRResult("FRESH_OCR_TEXT", andTranslate: false, expectedChangeCount: matchingCount, pasteboard: testPasteboard)
    t.check(
        testPasteboard.string(forType: .string) == "FRESH_OCR_TEXT",
        "applyOCRResult writes OCR text when pasteboard.changeCount matches"
    )

    // Verify closed session ignores late OCR completion and cancelActiveOCR cancels an in-flight OCR task
    let closedVM = PinSessionViewModel(image: baseImg)
    closedVM.runOCR(andTranslate: false)
    let didStartOCR = (closedVM.isPerformingOCR && closedVM.activeOCRTask != nil)
    closedVM.cancelActiveOCR()
    closedVM.isClosed = true
    let countBeforeClosedOCR = testPasteboard.changeCount
    closedVM.applyOCRResult("LATE_OCR_AFTER_ESC", andTranslate: false, expectedChangeCount: countBeforeClosedOCR, pasteboard: testPasteboard)
    t.check(
        didStartOCR &&
        closedVM.isPerformingOCR == false &&
        closedVM.activeOCRTask == nil &&
        testPasteboard.string(forType: .string) == "FRESH_OCR_TEXT",
        "runOCR starts async task, cancelActiveOCR cancels in-flight task, and closed session ignores late OCR result"
    )

    // Verify SingleInstanceLock acquires lock on disposable lock file
    let testLockPath = testTempDirURL.appendingPathComponent("test_daemon.lock").path
    t.check(
        SingleInstanceLock.acquireOrNotifyExisting(path: testLockPath, notifyExisting: false) == true,
        "SingleInstanceLock.acquireOrNotifyExisting succeeds on unlocked file"
    )

    var settingsRequestPosts = 0
    var settingsRequestWaits = 0
    let retriedSettingsRequestSucceeded = SettingsRequestRetry.send(
        maxAttempts: 3,
        post: { settingsRequestPosts += 1 },
        waitForAcknowledgement: {
            settingsRequestWaits += 1
            return settingsRequestWaits == 2
        }
    )
    t.check(
        retriedSettingsRequestSucceeded && settingsRequestPosts == 2,
        "Acknowledged settings requests retry after a lost startup notification and stop after an acknowledgement"
    )
    settingsRequestPosts = 0
    let timedOutSettingsRequest = SettingsRequestRetry.send(
        maxAttempts: 3,
        post: { settingsRequestPosts += 1 },
        waitForAcknowledgement: { false }
    )
    t.check(
        !timedOutSettingsRequest && settingsRequestPosts == 3,
        "Settings request retries stop at the configured bound when the daemon never acknowledges"
    )

}
