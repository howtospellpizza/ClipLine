import AppKit
import Carbon
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Lightweight Assertion Harness

@MainActor
final class TestHarness {
    var passed = 0
    var failed = 0

    func check(_ condition: @autoclosure () -> Bool, _ name: String, detail: String = "") {
        if condition() {
            passed += 1
            print("  ✅ PASS: \(name)")
        } else {
            failed += 1
            print("  ❌ FAIL: \(name) \(detail.isEmpty ? "" : "(\(detail))")")
        }
    }

    func summary() -> Int32 {
        print("\n========================================")
        print("📊 Test Summary: \(passed) passed, \(failed) failed")
        print("========================================")
        return failed == 0 ? 0 : 1
    }
}

@MainActor
final class ShortcutRecorderNavigationWindow: NSWindow {
    private(set) var selectedNextKeyView = false
    private(set) var selectedPreviousKeyView = false

    override func selectNextKeyView(_ sender: Any?) {
        selectedNextKeyView = true
        super.selectNextKeyView(sender)
    }

    override func selectPreviousKeyView(_ sender: Any?) {
        selectedPreviousKeyView = true
        super.selectPreviousKeyView(sender)
    }
}

// MARK: - Synthetic Test Image Builders

func makeSyntheticScreenCGImage(width: Int = 800, height: Int = 600) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // Top-left quadrant red, top-right green, bottom-left blue, bottom-right yellow
    ctx.setFillColor(NSColor.systemRed.cgColor)
    ctx.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
    ctx.setFillColor(NSColor.systemGreen.cgColor)
    ctx.fill(CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2))
    ctx.setFillColor(NSColor.systemBlue.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
    ctx.setFillColor(NSColor.systemYellow.cgColor)
    ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2))

    // Draw high-contrast horizontal stripes in center so mosaic pixelation changes pixel values
    for y in stride(from: 100, to: 500, by: 4) {
        ctx.setFillColor((y % 8 == 0) ? NSColor.black.cgColor : NSColor.white.cgColor)
        ctx.fill(CGRect(x: 100, y: y, width: 600, height: 2))
    }

    return ctx.makeImage()!
}

func makeTextImage(text: String, size: NSSize = NSSize(width: 320, height: 90)) -> NSImage {
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor.white.setFill()
    NSBezierPath.fill(NSRect(origin: .zero, size: size))
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 32, weight: .bold),
        .foregroundColor: NSColor.black
    ]
    (text as NSString).draw(at: NSPoint(x: 24, y: 26), withAttributes: attrs)
    img.unlockFocus()
    return img
}

func sampleImageLuminanceVariance(_ image: NSImage, in normalizedRect: CGRect) -> Double {
    guard let tiff = image.tiffRepresentation,
          let bmp = NSBitmapImageRep(data: tiff) else { return 0 }
    let w = bmp.pixelsWide
    let h = bmp.pixelsHigh
    let minX = max(0, Int( CGFloat(w) * normalizedRect.minX ))
    let maxX = min(w - 1, Int( CGFloat(w) * normalizedRect.maxX ))
    let minY = max(0, Int( CGFloat(h) * normalizedRect.minY ))
    let maxY = min(h - 1, Int( CGFloat(h) * normalizedRect.maxY ))
    guard maxX >= minX, maxY >= minY else { return 0 }

    var diffs = 0.0
    var count = 0.0
    for x in stride(from: minX, through: maxX, by: 4) {
        var prevLuma: Double? = nil
        for y in minY...maxY {
            if let c = bmp.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                let luma = 0.299 * Double(c.redComponent) + 0.587 * Double(c.greenComponent) + 0.114 * Double(c.blueComponent)
                if let p = prevLuma {
                    diffs += abs(luma - p)
                    count += 1
                }
                prevLuma = luma
            }
        }
    }
    return count > 0 ? (diffs / count) : 0
}

// MARK: - In-Process Unit + AppKit GUI Regression Suites

@MainActor
func runAllTests() -> Int32 {
    let t = TestHarness()
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    // Create isolated pasteboard and disposable temporary directory so `make test` NEVER touches the user's live clipboard or temp files
    let testPasteboard = NSPasteboard.withUniqueName()
    let testTempDirURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipLineTests_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: testTempDirURL, withIntermediateDirectories: true)

    ClotheslineManager.shared.pasteboardProvider = { testPasteboard }
    ClotheslineManager.shared.tempDirOverride = testTempDirURL.path

    defer {
        ClotheslineManager.shared.pasteboardProvider = { .general }
        ClotheslineManager.shared.tempDirOverride = nil
        testPasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: testTempDirURL)
    }

    print("🚀 Running ClipLine In-Process Unit & AppKit Regression Suite (Isolated Pasteboard & TempDir)...\n")

    // -------------------------------------------------------------------------
    // Suite 1: Coordinate Geometry & Crop Math
    // -------------------------------------------------------------------------
    print("🔹 Suite 1: Geometry & Crop Math")
    let screenFrame = NSRect(x: 0, y: 0, width: 400, height: 300)
    let cgScreen = makeSyntheticScreenCGImage(width: 800, height: 600) // 2x Retina

    let cropRect = NSRect(x: 100, y: 80, width: 160, height: 120)
    let cropped = PixPinSelectionView.cropImage(
        cgImage: cgScreen,
        viewHeight: screenFrame.height,
        scaleFactor: 2.0,
        rect: cropRect
    )
    t.check(cropped != nil, "PixPinSelectionView.cropImage returns non-nil image")
    t.check(cropped?.size == NSSize(width: 160, height: 120), "Cropped image preserves logical point size 160x120")

    let panelFrame = PinSessionViewModel.panelFrameForImageScreenRect(cropRect)
    t.check(
        panelFrame == NSRect(x: 84, y: 64, width: 192, height: 152),
        "panelFrameForImageScreenRect adds exact 16pt canvasMargin on all 4 sides",
        detail: "got \(panelFrame)"
    )

    let deniedCaptureController = ScreenCaptureOverlayController()
    var preflightChecks = 0
    var requestAttempts = 0
    var alertPresentations = 0
    deniedCaptureController.preflightAccess = {
        preflightChecks += 1
        return false
    }
    deniedCaptureController.requestAccess = {
        requestAttempts += 1
        return false
    }
    deniedCaptureController.presentPermissionAlert = {
        alertPresentations += 1
    }
    let launchPermissionGranted = deniedCaptureController.ensureScreenCaptureAccess(showAlertOnDenial: false)
    t.check(
        !launchPermissionGranted && requestAttempts == 1 && alertPresentations == 0,
        "Launch permission check triggers CGRequestScreenCaptureAccess without blocking on modal alert"
    )
    var deniedCaptureCompletedWithNil = false
    deniedCaptureController.beginCapture { result in
        deniedCaptureCompletedWithNil = (result == nil)
    }
    t.check(
        deniedCaptureCompletedWithNil && requestAttempts == 2 && alertPresentations == 1 && preflightChecks >= 2,
        "beginCapture aborts before showing wallpaper-only fullscreen overlay when Screen Recording permission is denied"
    )

    // Window auto-detection & single-click snap vs drag override
    let convertedWindowRect = ScreenCaptureOverlayController.convertCGWindowBoundsToViewRect(
        cgBounds: CGRect(x: 50, y: 40, width: 180, height: 100),
        primaryScreenHeight: 300,
        targetScreenFrame: screenFrame
    )
    t.check(
        convertedWindowRect == NSRect(x: 50, y: 160, width: 180, height: 100),
        "convertCGWindowBoundsToViewRect converts top-left CGWindow bounds to bottom-left AppKit view rect",
        detail: "got \(String(describing: convertedWindowRect))"
    )
    t.check(
        !ScreenCaptureOverlayController.shouldIncludeWindowForSnap(
            ownerPID: 200,
            ownPID: 100,
            ownerName: "Dock",
            layer: 20,
            alpha: 1.0,
            viewRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            screenSize: NSSize(width: 400, height: 300)
        ) &&
        ScreenCaptureOverlayController.shouldIncludeWindowForSnap(
            ownerPID: 201,
            ownPID: 100,
            ownerName: "WindowManager",
            layer: 0,
            alpha: 1.0,
            viewRect: NSRect(x: 16, y: 195, width: 83, height: 120),
            screenSize: NSSize(width: 400, height: 300)
        ) &&
        ScreenCaptureOverlayController.shouldIncludeWindowForSnap(
            ownerPID: 202,
            ownPID: 100,
            ownerName: "Ghostty",
            layer: 0,
            alpha: 1.0,
            viewRect: NSRect(x: 40, y: 30, width: 300, height: 220),
            screenSize: NSSize(width: 400, height: 300)
        ),
        "shouldIncludeWindowForSnap excludes full-screen Dock backdrop (layer 20) while keeping Stage Manager thumbnails and real app windows"
    )
    var snappedResult: CaptureSelectionResult?
    let snapSelectionView = PixPinSelectionView(
        frame: screenFrame,
        screenOrigin: .zero,
        frozenImage: NSImage(cgImage: cgScreen, size: screenFrame.size),
        cgImage: cgScreen,
        scaleFactor: 2.0,
        candidateWindowRects: [
            NSRect(x: 60, y: 90, width: 140, height: 100),
            NSRect(x: 20, y: 20, width: 300, height: 240)
        ],
        onFinish: { snappedResult = $0 }
    )
    t.check(
        snapSelectionView.hoveredWindowRect(at: NSPoint(x: 100, y: 120)) == NSRect(x: 60, y: 90, width: 140, height: 100),
        "hoveredWindowRect returns the topmost front-to-back window containing cursor"
    )
    if let downSnap = NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 100, y: 120), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1.0
    ),
       let upSnap = NSEvent.mouseEvent(
        with: .leftMouseUp, location: NSPoint(x: 101, y: 121), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 1.0
       ) {
        snapSelectionView.mouseDown(with: downSnap)
        snapSelectionView.mouseUp(with: upSnap)
        t.check(
            snappedResult?.selectedScreenRect == NSRect(x: 60, y: 90, width: 140, height: 100),
            "Single-clicking (<4pt drag) on a hovered window snaps capture to that window's exact bounds",
            detail: "got \(String(describing: snappedResult?.selectedScreenRect))"
        )
    }
    snappedResult = nil
    if let spaceKey = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
    ) {
        snapSelectionView.keyDown(with: spaceKey)
        t.check(
            snappedResult?.selectedScreenRect == screenFrame,
            "Pressing Space in capture overlay captures the entire screen",
            detail: "got \(String(describing: snappedResult?.selectedScreenRect))"
        )
    }

    // Shift-constrained square & 45-degree arrow math + Step Counter + Highlighter
    let constrainedSquareEnd = PinSessionViewModel.constrainedNormalizedEndPoint(
        for: .rect,
        start: CGPoint(x: 0.2, y: 0.2),
        rawEnd: CGPoint(x: 0.7, y: 0.4),
        canvasSize: NSSize(width: 200, height: 100)
    )
    let squareWidthPt = abs(constrainedSquareEnd.x - 0.2) * 200.0
    let squareHeightPt = abs(constrainedSquareEnd.y - 0.2) * 100.0
    t.check(
        abs(squareWidthPt - squareHeightPt) < 0.01 && squareWidthPt > 10,
        "Shift-constrained .rect locks 1:1 point-space square even on non-square canvases",
        detail: "w=\(squareWidthPt), h=\(squareHeightPt)"
    )

    let constrainedArrowEnd = PinSessionViewModel.constrainedNormalizedEndPoint(
        for: .arrow,
        start: CGPoint(x: 0.5, y: 0.5),
        rawEnd: CGPoint(x: 0.82, y: 0.53),
        canvasSize: NSSize(width: 200, height: 100)
    )
    let arrowDxPt = (constrainedArrowEnd.x - 0.5) * 200.0
    let arrowDyPt = (constrainedArrowEnd.y - 0.5) * 100.0
    t.check(
        abs(arrowDyPt) < 0.01 && arrowDxPt > 20,
        "Shift-constrained .arrow snaps near-horizontal drag to exact 0° horizontal angle",
        detail: "dx=\(arrowDxPt), dy=\(arrowDyPt)"
    )

    let featureVM = PinSessionViewModel(image: makeTextImage(text: "HIGHLIGHT", size: NSSize(width: 200, height: 80)))
    t.check(featureVM.nextCounterLabel == "1", "nextCounterLabel starts at 1 when no counter annotations exist")
    featureVM.annotations.append(PinAnnotation(tool: .counter, color: .systemRed, lineWidth: 28, points: [CGPoint(x: 0.3, y: 0.4)], text: featureVM.nextCounterLabel))
    t.check(featureVM.nextCounterLabel == "2", "nextCounterLabel increments to 2 after placing first counter badge")
    featureVM.annotations.append(PinAnnotation(tool: .highlighter, color: .systemYellow, lineWidth: 22, points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)]))
    let renderedWithCounterAndHighlight = featureVM.renderCompositeImage()
    t.check(
        renderedWithCounterAndHighlight?.size == NSSize(width: 200, height: 80),
        "renderCompositeImage renders .counter badges and .highlighter multiply strokes cleanly"
    )
    featureVM.undo()
    featureVM.undo()
    t.check(
        featureVM.nextCounterLabel == "1",
        "Undoing counter badge decrements nextCounterLabel back to 1"
    )

    var openedSettingsFromHUD = false
    var revealedBinaryFromHUD = false
    var dismissedHUD = false
    let hudPanel = ScreenCaptureOverlayController.makeScreenRecordingPermissionPanel(
        onOpenSettings: { openedSettingsFromHUD = true },
        onRevealBinary: { revealedBinaryFromHUD = true },
        onDismiss: {
            dismissedHUD = true
            ScreenCaptureOverlayController.dismissScreenRecordingPermissionAlert()
        }
    )
    t.check(
        hudPanel.styleMask.contains(.borderless) && !hudPanel.isOpaque && hudPanel.contentView != nil,
        "makeScreenRecordingPermissionPanel builds borderless translucent HUD card instead of default generic folder NSAlert"
    )
    hudPanel.cancelOperation(nil)
    t.check(
        dismissedHUD && !openedSettingsFromHUD && !revealedBinaryFromHUD,
        "Permission HUD card dismisses cleanly on Escape/cancelOperation"
    )

    // -------------------------------------------------------------------------
    // Suite 2: Lazy CIPixellate Mosaic Pixel Verification & Fail-Closed Redaction
    // -------------------------------------------------------------------------
    print("\n🔹 Suite 2: Lazy Mosaic Pixel Verification, Fail-Closed Redaction & Window Drag Crop Invalidation")
    let baseImg = cropped!
    let vm = PinSessionViewModel(
        image: baseImg,
        fullScreenCGImage: cgScreen,
        fullScreenFrame: screenFrame,
        captureScaleFactor: 2.0,
        cropScreenRect: cropRect
    )
    t.check(vm.pixelatedBaseImage == nil, "pixelatedBaseImage is lazy (nil on init for fast capture)")
    t.check(vm.canAdjustCrop == true, "canAdjustCrop is true immediately after capture")

    let preMosaicStripeVariation = sampleImageLuminanceVariance(baseImg, in: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
    vm.activeTool = .mosaic
    t.check(vm.pixelatedBaseImage != nil, "Selecting .mosaic lazily generates pixelatedBaseImage")
    if let pixImg = vm.pixelatedBaseImage {
        let postMosaicStripeVariation = sampleImageLuminanceVariance(pixImg, in: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        t.check(
            postMosaicStripeVariation < preMosaicStripeVariation * 0.65,
            "CIPixellate mosaic visibly reduces high-frequency stripe variation",
            detail: "before=\(String(format: "%.3f", preMosaicStripeVariation)), after=\(String(format: "%.3f", postMosaicStripeVariation))"
        )
    } else {
        t.check(false, "pixelatedBaseImage available for pixel comparison")
    }

    // Verify fail-closed mosaic redaction over a high-contrast patterned base image when pixelation fails
    let failClosedVM = PinSessionViewModel(image: baseImg)
    failClosedVM.pixelatedBaseImage = nil
    failClosedVM.forceMosaicFallbackForTesting = true
    failClosedVM.annotations = [
        PinAnnotation(
            tool: .mosaic,
            color: .red,
            lineWidth: 28,
            points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)]
        )
    ]
    let failClosedOut = failClosedVM.renderCompositeImage()!
    let failClosedLumaDiff = sampleImageLuminanceVariance(failClosedOut, in: CGRect(x: 0.3, y: 0.48, width: 0.4, height: 0.04))
    var centerPixelOpaqueDark = false
    if let tiff = failClosedOut.tiffRepresentation,
       let bmp = NSBitmapImageRep(data: tiff),
       let c = bmp.colorAt(x: bmp.pixelsWide / 2, y: bmp.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) {
        let luma = 0.299 * Double(c.redComponent) + 0.587 * Double(c.greenComponent) + 0.114 * Double(c.blueComponent)
        centerPixelOpaqueDark = (c.alphaComponent > 0.98 && luma > 0.05 && luma < 0.22)
    }
    t.check(
        failClosedLumaDiff < 0.01 && centerPixelOpaqueDark,
        "Mosaic stroke fails closed (paints uniform opaque dark redaction block over patterned source) if pixelation fails",
        detail: "variance=\(failClosedLumaDiff), centerPixelOpaqueDark=\(centerPixelOpaqueDark)"
    )

    // Verify renderCompositeImage fails closed (returns nil and leaves pasteboard untouched) when baseSize is invalid
    testPasteboard.clearContents()
    testPasteboard.setString("PRESERVED_ON_RENDER_FAILURE", forType: .string)
    let invalidSizeVM = PinSessionViewModel(image: baseImg)
    invalidSizeVM.baseSize = .zero
    t.check(
        invalidSizeVM.renderCompositeImage() == nil &&
        invalidSizeVM.copyToClipboard() == false &&
        testPasteboard.string(forType: .string) == "PRESERVED_ON_RENDER_FAILURE",
        "renderCompositeImage and copyToClipboard fail closed (return nil/false and leave pasteboard untouched) on invalid context"
    )

    vm.activeTool = nil

    // Simulate dragging the floating window -> must disable 8-handle screen re-crop
    vm.hasMovedWindow = true
    t.check(vm.canAdjustCrop == false, "Moving window sets hasMovedWindow=true and disables canAdjustCrop")
    vm.hasMovedWindow = false
    t.check(vm.canAdjustCrop == true, "Resetting hasMovedWindow restores canAdjustCrop when unannotated & scale==1")

    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Suite 4: Native Dual-Panel GUI Lifecycle, 8-Handle Resize & Keyboard Forwarding
    // -------------------------------------------------------------------------
    print("\n🔹 Suite 4: Native AppKit + SwiftUI Dual-Panel GUI Regression")
    let daemon = PinDaemonApp()
    daemon.presentPinPanel(vm: vm, frame: panelFrame)

    guard let pinPanel = vm.hostingPanel,
          let canvas = pinPanel.canvasView,
          let tbPanel = vm.toolbarPanel as? PinToolbarPanel else {
        t.check(false, "presentPinPanel creates PinFloatingPanel, PinCanvasNSView, and PinToolbarPanel")
        return t.summary()
    }

    t.check(pinPanel.isVisible, "PinFloatingPanel is visible on screen")
    t.check(tbPanel.isVisible, "Detached PinToolbarPanel is visible on screen")
    t.check(
        tbPanel.level.rawValue > pinPanel.level.rawValue,
        "PinToolbarPanel level stays strictly above PinFloatingPanel so editing/clicking canvas never obscures toolbar"
    )
    t.check(tbPanel.viewModel === vm, "PinToolbarPanel.viewModel is wired to PinSessionViewModel")

    // Verify 4A: Image rect & all 8 handle hit-testing
    let imgRect = canvas.imageRectInView
    t.check(
        imgRect == NSRect(x: 16, y: 16, width: 160, height: 120),
        "canvas.imageRectInView sits inside 16pt margin (16, 16, 160, 120)"
    )

    let bottomHandleScreenY = pinPanel.frame.minY + imgRect.minY
    let toolbarMaxY = tbPanel.frame.maxY
    t.check(
        toolbarMaxY <= bottomHandleScreenY - 8 || tbPanel.frame.minY >= pinPanel.frame.maxY - 8,
        "Detached toolbar panel never overlaps bottom resize handles",
        detail: "toolbarMaxY=\(toolbarMaxY), bottomHandleScreenY=\(bottomHandleScreenY)"
    )

    // Verify full-screen pin keeps toolbar panel within visible screen bounds
    let mainScreen = pinPanel.screen ?? NSScreen.main ?? NSScreen.screens.first
    if let mainScreen {
        let fullFrame = PinSessionViewModel.panelFrameForImageScreenRect(mainScreen.frame)
        pinPanel.setFrame(fullFrame, display: false)
        vm.updateToolbarPanelPosition()
        t.check(
            tbPanel.frame.minY >= mainScreen.visibleFrame.minY &&
            tbPanel.frame.maxY <= mainScreen.visibleFrame.maxY,
            "Full-screen pin clamps toolbar panel inside visible screen bounds instead of off-screen above menu bar",
            detail: "tbPanel.frame=\(tbPanel.frame), visibleFrame=\(mainScreen.visibleFrame)"
        )
        pinPanel.setFrame(panelFrame, display: false)
        vm.updateToolbarPanelPosition()
    }

    let handlePts = canvas.handlePointsInView()
    t.check(handlePts.count == 8, "handlePointsInView returns all 8 resize handles")
    for (expectedHandle, pt) in handlePts {
        let hit = canvas.hitTestResizeHandle(viewPoint: pt)
        t.check(hit == expectedHandle, "hitTestResizeHandle hits \(expectedHandle) at \(pt)")
    }

    // Verify 4B: Post-capture live 8-handle resize across all 8 directions
    let baseCrop = NSRect(x: 100, y: 80, width: 160, height: 120)
    let directionCases: [(PinSessionViewModel.ResizeHandle, NSPoint, NSPoint, NSRect)] = [
        (.topLeft, NSPoint(x: 100, y: 200), NSPoint(x: 90, y: 215), NSRect(x: 90, y: 80, width: 170, height: 135)),
        (.topCenter, NSPoint(x: 180, y: 200), NSPoint(x: 180, y: 210), NSRect(x: 100, y: 80, width: 160, height: 130)),
        (.topRight, NSPoint(x: 260, y: 200), NSPoint(x: 275, y: 210), NSRect(x: 100, y: 80, width: 175, height: 130)),
        (.middleLeft, NSPoint(x: 100, y: 140), NSPoint(x: 85, y: 140), NSRect(x: 85, y: 80, width: 175, height: 120)),
        (.middleRight, NSPoint(x: 260, y: 140), NSPoint(x: 280, y: 140), NSRect(x: 100, y: 80, width: 180, height: 120)),
        (.bottomLeft, NSPoint(x: 100, y: 80), NSPoint(x: 90, y: 70), NSRect(x: 90, y: 70, width: 170, height: 130)),
        (.bottomCenter, NSPoint(x: 180, y: 80), NSPoint(x: 180, y: 65), NSRect(x: 100, y: 65, width: 160, height: 135)),
        (.bottomRight, NSPoint(x: 260, y: 80), NSPoint(x: 280, y: 65), NSRect(x: 100, y: 65, width: 180, height: 135))
    ]
    for (handle, startPt, dragPt, expectedRect) in directionCases {
        vm.applyResize(handle: handle, startMouse: startPt, startCropRect: baseCrop, currentMouse: dragPt)
        vm.finishResize()
        t.check(
            vm.cropScreenRect == expectedRect,
            "applyResize(\(handle)) updates cropScreenRect to \(expectedRect)",
            detail: "got \(String(describing: vm.cropScreenRect))"
        )
    }

    t.check(
        pinPanel.frame.size == NSSize(width: 212, height: 167),
        "PinFloatingPanel resizes synchronously to 212x167 (180+32 x 135+32)"
    )

    // Verify dragging right handle past left edge clamps only right edge (never shifts anchored left edge X=100)
    vm.applyResize(handle: .middleRight, startMouse: NSPoint(x: 280, y: 140), startCropRect: NSRect(x: 100, y: 65, width: 180, height: 135), currentMouse: NSPoint(x: 20, y: 140))
    t.check(
        vm.cropScreenRect == NSRect(x: 100, y: 65, width: 24, height: 135),
        "Dragging right handle past left edge clamps at minCropSize (width=24) without shifting anchored left edge X=100",
        detail: "got \(String(describing: vm.cropScreenRect))"
    )
    // Restore to (100, 65, 180, 135)
    vm.applyResize(handle: .bottomRight, startMouse: NSPoint(x: 260, y: 80), startCropRect: baseCrop, currentMouse: NSPoint(x: 280, y: 65))
    vm.finishResize()

    let secondBottomCenterPt = NSPoint(x: canvas.imageRectInView.midX, y: canvas.imageRectInView.minY)
    t.check(
        canvas.hitTestResizeHandle(viewPoint: secondBottomCenterPt) == .bottomCenter,
        "Bottom-center handle remains hit-testable after resize completes"
    )

    // Verify 4C: Toolbar expansion when selecting tools does NOT clip image canvas
    let canvasFrameBeforeTool = pinPanel.frame
    let tbWidthBeforeTool = tbPanel.frame.width
    vm.activeTool = .pen
    let tbWidthAfterTool = tbPanel.frame.width
    t.check(
        pinPanel.frame == canvasFrameBeforeTool,
        "Selecting .pen tool does NOT alter or clip PinFloatingPanel frame"
    )
    t.check(
        tbWidthAfterTool > tbWidthBeforeTool,
        "Detached toolbar panel auto-expands width (\(Int(tbWidthBeforeTool))pt -> \(Int(tbWidthAfterTool))pt) to show 细/中/粗 + colors"
    )

    // Verify 4D: Drawing annotations & Cmd+Z Undo via PinToolbarPanel key forwarding
    vm.annotations.append(
        PinAnnotation(
            tool: .rect,
            color: .red,
            lineWidth: vm.currentToolLineWidth,
            points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.8, y: 0.8)]
        )
    )
    t.check(vm.annotations.count == 1, "Annotation appended to session")

    if let cmdZEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: tbPanel.windowNumber,
        context: nil,
        characters: "z",
        charactersIgnoringModifiers: "z",
        isARepeat: false,
        keyCode: 6 // kVK_ANSI_Z
    ) {
        tbPanel.keyDown(with: cmdZEvent)
        t.check(
            vm.annotations.isEmpty,
            "Pressing Cmd+Z while PinToolbarPanel is key window forwards to PinFloatingPanel and undoes annotation"
        )
    } else {
        t.check(false, "Constructed Cmd+Z keyEvent")
    }

    // Verify 4E: Composite rendering with annotations + inline text clamping + live color/background sync + text dragging
    vm.activeTool = .text
    if let canvas = pinPanel.canvasView {
        canvas.showInlineTextField(atNormalized: CGPoint(x: 0.30, y: 0.30), in: canvas.imageRectInView, initialText: "LiveColorText")
        let openSettings = pinPanel.onOpenSettings
        var settingsOpenCount = 0
        pinPanel.onOpenSettings = { settingsOpenCount += 1 }
        let originalTextPosition = vm.pendingTextNormalizedPos
        func commaEvent(modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: pinPanel.windowNumber, context: nil,
                characters: ",", charactersIgnoringModifiers: ",",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_Comma)
            )!
        }
        t.check(
            pinPanel.firstResponder is NSTextView && vm.pendingTextNormalizedPos != nil,
            "Settings shortcut regression starts with an active inline field editor"
        )
        let settingsEvent = commaEvent(modifiers: [.command])
        let settingsHandled = pinPanel.performKeyEquivalent(with: settingsEvent)
        t.check(
            settingsHandled && settingsOpenCount == 1,
            "Cmd+, opens settings through window key equivalents while the inline field editor is active"
        )
        tbPanel.keyDown(with: settingsEvent)
        t.check(
            settingsOpenCount == 2,
            "Toolbar key forwarding opens settings even with pending inline text"
        )
        _ = pinPanel.performKeyEquivalent(with: commaEvent(modifiers: []))
        _ = pinPanel.performKeyEquivalent(with: commaEvent(modifiers: [.command, .shift]))
        t.check(
            settingsOpenCount == 2,
            "Plain comma and modified Cmd+comma do not trigger settings"
        )
        t.check(
            vm.pendingTextNormalizedPos == originalTextPosition &&
                canvas.textField?.stringValue == "LiveColorText" && vm.annotations.isEmpty,
            "Routing the settings shortcut preserves pending text without committing or discarding it"
        )
        pinPanel.onOpenSettings = openSettings
        t.check(
            canvas.textField?.drawsBackground == false && canvas.textField?.backgroundColor == .clear,
            "Inline text field has transparent background by default (no gray box)"
        )
        vm.selectedColor = .green
        let tfColorMatch = canvas.textField?.textColor == NSColor(.green)
        let editor = pinPanel.fieldEditor(false, for: canvas.textField) as? NSTextView
        let editorColorMatch = (editor == nil) || (editor?.textColor == NSColor(.green))
        t.check(
            tfColorMatch && editorColorMatch,
            "Changing vm.selectedColor while editing immediately updates NSTextField & active fieldEditor textColor"
        )
        vm.textBackgroundStyle = .black
        t.check(
            canvas.textField?.layer?.borderWidth == 0,
            "Inline textField layer stays borderless (pill & neutral selection frame are rendered cleanly by canvas)"
        )
        t.check(
            canvas.textField?.hitTest(NSPoint(x: 10, y: 10)) == nil,
            "DraggableInlineTextField returns nil from hitTest so dragging anywhere on the box moves it"
        )
        let fieldFrameBeforeCommit = canvas.textField?.frame ?? .zero
        vm.commitPendingText()
        t.check(
            vm.annotations.count == 1 && vm.annotations.first?.text == "LiveColorText" && vm.annotations.first?.textBackgroundStyle == .black,
            "commitPendingText commits text annotation with selected textBackgroundStyle and auto-selects it"
        )
        if let committedHitRect = canvas.textAnnotationHitRectInView(vm.annotations[0]) {
            let deltaMidY = abs(committedHitRect.midY - fieldFrameBeforeCommit.midY)
            t.check(
                deltaMidY <= 4.0,
                "Pressing Enter keeps committed text at exact vertical position of inline textField (no jump)",
                detail: "fieldMidY=\(fieldFrameBeforeCommit.midY), committedMidY=\(committedHitRect.midY)"
            )
        }
        t.check(
            vm.selectedTextAnnotationID == vm.annotations.first?.id,
            "Committed text annotation remains selected (selectedTextAnnotationID) for post-commit color/background changes"
        )

        // Post-commit color & background changes update the selected committed text annotation!
        vm.selectedColor = .yellow
        vm.textBackgroundStyle = .white
        t.check(
            vm.annotations[0].color == NSColor(.yellow) && vm.annotations[0].textBackgroundStyle == .white,
            "Changing selectedColor or textBackgroundStyle after pressing Enter updates the selected committed text annotation"
        )

        // Verify committed text hit-testing & dragging (even if user switches tool e.g. to .pen)
        vm.activeTool = .pen
        if let hitRect = canvas.textAnnotationHitRectInView(vm.annotations[0]) {
            let hitCenter = NSPoint(x: hitRect.midX, y: hitRect.midY)
            t.check(
                canvas.hitTestTextAnnotationIndex(viewPoint: hitCenter) == 0,
                "hitTestTextAnnotationIndex hits committed text annotation at its rendered position"
            )
            if let downEv = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: pinPanel.convertPoint(fromScreen: pinPanel.convertPoint(toScreen: hitCenter)),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: pinPanel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1.0
            ),
               let dragEv = NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: NSPoint(x: hitCenter.x + 40, y: hitCenter.y - 20),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: pinPanel.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1.0
            ),
               let upEv = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: NSPoint(x: hitCenter.x + 40, y: hitCenter.y - 20),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: pinPanel.windowNumber,
                context: nil,
                eventNumber: 3,
                clickCount: 1,
                pressure: 1.0
            ) {
                let beforePt = vm.annotations[0].points[0]
                canvas.mouseDown(with: downEv)
                canvas.mouseDragged(with: dragEv)
                canvas.mouseUp(with: upEv)
                let afterPt = vm.annotations[0].points[0]
                t.check(
                    afterPt.x > beforePt.x && afterPt.y > beforePt.y,
                    "Dragging committed text annotation moves its normalized coordinates regardless of activeTool",
                    detail: "before=\(beforePt), after=\(afterPt)"
                )
            }
        }
        vm.activeTool = .text

        // Verify typing a long caption near right edge syncs pendingTextNormalizedPos with clampedX and commits via controlTextDidEndEditing (Return) without jumping
        canvas.showInlineTextField(atNormalized: CGPoint(x: 0.72, y: 0.25), in: canvas.imageRectInView, initialText: "A")
        let initialNormX = vm.pendingTextNormalizedPos?.x ?? 0
        if let tf = canvas.textField {
            tf.stringValue = "LongRightEdgeCaptionThatClampsLeft"
            canvas.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: tf))
            let clampedFieldMinX = tf.frame.minX
            let syncedNormX = vm.pendingTextNormalizedPos?.x ?? 0
            let expectedGlyphX = canvas.imageRectInView.minX + syncedNormX * canvas.imageRectInView.width
            // Commit through NSTextField's controlTextDidEndEditing path (same delegate callback triggered by Return in field editor)
            canvas.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: tf))
            let committedLong = vm.annotations.last
            let committedRect = committedLong.flatMap { canvas.textAnnotationHitRectInView($0) } ?? .zero
            let padX: CGFloat = committedLong?.textBackgroundStyle == .transparent ? 8.0 : 10.0
            t.check(
                syncedNormX < initialNormX &&
                abs(expectedGlyphX - (clampedFieldMinX + 2.0)) <= 1.0 &&
                committedLong?.text == "LongRightEdgeCaptionThatClampsLeft" &&
                abs((committedRect.minX + padX) - expectedGlyphX) <= 1.5,
                "Typing long text near right edge syncs pendingTextNormalizedPos with clamped field origin and commits via controlTextDidEndEditing without jumping",
                detail: "initialNormX=\(initialNormX), syncedNormX=\(syncedNormX), expectedGlyphX=\(expectedGlyphX), committedGlyphX=\(committedRect.minX + padX)"
            )
            // Remove the second test annotation so subsequent tests start with 1 annotation
            if vm.annotations.count > 1 {
                vm.annotations.removeLast()
            }
        }

        // Verify double-click re-edit preserves color/font preset/background even if style is mutated while editing, and cancelling restores original snapshot
        vm.selectedTextAnnotationID = nil
        vm.annotations[0].color = NSColor(.orange)
        vm.annotations[0].lineWidth = StrokePreset.thick.textFontSize
        vm.annotations[0].textBackgroundStyle = .black
        vm.selectedColor = .blue
        vm.strokePreset = .thin
        vm.textBackgroundStyle = .transparent
        if let hitRect2 = canvas.textAnnotationHitRectInView(vm.annotations[0]) {
            let center2 = NSPoint(x: hitRect2.midX, y: hitRect2.midY)
            if let dblClickEv = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: center2,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: pinPanel.windowNumber,
                context: nil,
                eventNumber: 10,
                clickCount: 2,
                pressure: 1.0
            ) {
                canvas.mouseDown(with: dblClickEv)
                t.check(
                    vm.editingExistingTextAnnotationID == vm.annotations[0].id && vm.strokePreset == .thick && vm.textBackgroundStyle == .black,
                    "Double-clicking committed text restores original strokePreset (.thick) and textBackgroundStyle (.black) for in-place re-editing"
                )
                // Mutate color, preset, background, and text during active re-edit, then cancel via Escape command selector
                vm.selectedColor = .purple
                vm.strokePreset = .thin
                vm.textBackgroundStyle = .white
                canvas.textField?.stringValue = "DiscardedEdit"
                if let tf = canvas.textField {
                    _ = canvas.control(tf, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
                } else {
                    vm.cancelPendingTextEditing()
                }
                t.check(
                    vm.annotations.count == 1 &&
                    vm.annotations[0].text == "LiveColorText" &&
                    vm.annotations[0].color == NSColor(.orange) &&
                    vm.annotations[0].lineWidth == StrokePreset.thick.textFontSize &&
                    vm.annotations[0].textBackgroundStyle == .black &&
                    vm.editingExistingTextAnnotationID == nil,
                    "Pressing Esc during double-click re-edit restores the original text, color, font size, and background style"
                )
            }
        }

        // Verify clicking a second text annotation while an empty re-edit on the first annotation is committed does NOT crash or select stale index
        let secondAnnotation = PinAnnotation(
            tool: .text,
            color: NSColor(.cyan),
            lineWidth: StrokePreset.medium.textFontSize,
            points: [CGPoint(x: 0.2, y: 0.75)],
            text: "SecondItem",
            textBackgroundStyle: .black
        )
        vm.annotations.append(secondAnnotation)
        let firstID = vm.annotations[0].id
        let secondID = secondAnnotation.id
        vm.editingExistingTextAnnotationID = firstID
        vm.editingOriginalAnnotationSnapshot = vm.annotations[0]
        canvas.showInlineTextField(atNormalized: vm.annotations[0].points[0], in: canvas.imageRectInView, initialText: "")
        if let secondHitRect = canvas.textAnnotationHitRectInView(secondAnnotation),
           let clickSecondEv = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: secondHitRect.midX, y: secondHitRect.midY),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: pinPanel.windowNumber,
            context: nil,
            eventNumber: 11,
            clickCount: 1,
            pressure: 1.0
           ) {
            canvas.mouseDown(with: clickSecondEv)
            canvas.mouseUp(with: clickSecondEv)
            t.check(
                vm.annotations.count == 1 &&
                vm.annotations[0].id == secondID &&
                vm.selectedTextAnnotationID == secondID,
                "Clicking a second text annotation while committing an empty re-edit on the first deletes the first and safely selects the second without index out-of-range"
            )
        }
    }
    let composite = vm.renderCompositeImage()
    t.check(composite?.size == vm.baseSize, "renderCompositeImage outputs exact baseSize")

    let tinyImg = makeTextImage(text: "TINY", size: NSSize(width: 48, height: 36))
    let tinyVM = PinSessionViewModel(image: tinyImg)
    let tinyCanvas = PinCanvasNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 68), vm: tinyVM)
    tinyCanvas.showInlineTextField(atNormalized: CGPoint(x: 0.95, y: 0.95), in: tinyCanvas.imageRectInView)
    if let tfFrame = tinyCanvas.textField?.frame {
        t.check(
            tfFrame.minX >= 4 && tfFrame.maxX <= tinyCanvas.bounds.width - 4 && tfFrame.width >= 56,
            "showInlineTextField clamps NSTextField safely inside tiny (<160pt) canvas bounds",
            detail: "tfFrame=\(tfFrame), bounds=\(tinyCanvas.bounds)"
        )
    } else {
        t.check(false, "showInlineTextField creates NSTextField on tiny canvas")
    }

    // Verify 4F: Clipping to Clothesline Dock (`P` key) & Unclipping (using isolated testPasteboard)
    if let pKeyEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: tbPanel.windowNumber,
        context: nil,
        characters: "p",
        charactersIgnoringModifiers: "p",
        isARepeat: false,
        keyCode: 35 // kVK_ANSI_P
    ) {
        tbPanel.keyDown(with: pKeyEvent)
        t.check(ClotheslineManager.shared.items.count == 1, "Pressing 'P' on toolbar panel clips item onto ClotheslineManager")
        t.check(!pinPanel.isVisible && !tbPanel.isVisible, "Clipping hides both floating canvas panel and toolbar panel")
        t.check(ClotheslineManager.shared.dockPanel?.isVisible == true, "Clothesline dock panel is visible at top of screen")
    } else {
        t.check(false, "Constructed P keyEvent")
    }

    if let clippedItem = ClotheslineManager.shared.items.first {
        ClotheslineManager.shared.restoreToCanvas(clippedItem)
        t.check(ClotheslineManager.shared.items.isEmpty, "restoreToCanvas removes item from clothesline")
        t.check(pinPanel.isVisible && tbPanel.isVisible, "restoreToCanvas makes both pinPanel and tbPanel visible again")
    } else {
        t.check(false, "Clipped item present for restoreToCanvas")
    }

    // Verify 4G: Esc key discards/closes both panels without writing to clipboard
    testPasteboard.clearContents()
    testPasteboard.setString("SENTINEL_CLIPBOARD_STRING", forType: .string)
    if let escEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: pinPanel.windowNumber,
        context: nil,
        characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false,
        keyCode: 53 // kVK_Escape
    ) {
        pinPanel.keyDown(with: escEvent)
        t.check(!pinPanel.isVisible && !tbPanel.isVisible, "Pressing Esc closes both PinFloatingPanel and PinToolbarPanel")
        t.check(vm.isClosed == true, "Closing panel marks PinSessionViewModel.isClosed = true to block late OCR callbacks")
        t.check(daemon.activePanels.isEmpty && daemon.activeToolbars.isEmpty, "Closing panel removes references from PinDaemonApp")
        t.check(
            testPasteboard.string(forType: .string) == "SENTINEL_CLIPBOARD_STRING",
            "Pressing Esc discards screenshot WITHOUT overwriting pasteboard"
        )
    } else {
        t.check(false, "Constructed Esc keyEvent")
    }

    // Verify 4H: Pressing Return/Enter copies to pasteboard and closes synchronously (no 150ms race window)
    let enterVM = PinSessionViewModel(image: baseImg)
    daemon.presentPinPanel(vm: enterVM, frame: panelFrame)
    if let enterPanel = enterVM.hostingPanel,
       let returnEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: enterPanel.windowNumber,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: 36 // kVK_Return
    ) {
        enterPanel.keyDown(with: returnEvent)
        t.check(
            !enterPanel.isVisible && daemon.activePanels.isEmpty && enterVM.isClosed,
            "Pressing Return copies image and closes PinFloatingPanel synchronously (no delayed close race)"
        )
    }

    // -------------------------------------------------------------------------
    // Suite 5: Multi-Image Pasteboard Copy & Scoped Temp File Hygiene
    // -------------------------------------------------------------------------
    print("\n🔹 Suite 5: Multi-Image Pasteboard Copy & Scoped Temp File Hygiene")
    let img1 = makeTextImage(text: "CLIP ONE", size: NSSize(width: 200, height: 60))
    let img2 = makeTextImage(text: "CLIP TWO", size: NSSize(width: 240, height: 80))
    let copiedMulti = ClipboardHelper.copyImages([img1, img2], pasteboard: testPasteboard, tempDir: testTempDirURL.path)
    let pbItems = testPasteboard.pasteboardItems ?? []
    t.check(
        copiedMulti && pbItems.count == 2,
        "copyImages writes 2 separate NSPasteboardItems when 2 images are selected",
        detail: "got \(pbItems.count) items"
    )
    let item0HasDataAndFile = (pbItems.first?.data(forType: .png) != nil) && (pbItems.first?.string(forType: .fileURL) != nil)
    let item1HasDataAndFile = (pbItems.last?.data(forType: .png) != nil) && (pbItems.last?.string(forType: .fileURL) != nil)
    t.check(
        item0HasDataAndFile && item1HasDataAndFile &&
        pbItems.first?.string(forType: .fileURL) != pbItems.last?.string(forType: .fileURL),
        "Each NSPasteboardItem carries its own independent PNG data, TIFF data, and unique fileURL"
    )

    let stitched = ClipboardHelper.stitchImagesGrid([img1, img2])
    t.check(
        stitched.size == NSSize(width: 240, height: 140),
        "stitchImagesGrid seamlessly stitches vertically with zero gap by default (maxW = 240, sumH = 140)",
        detail: "got \(stitched.size)"
    )

    // Verify Retina 2x pixel density is preserved through renderCompositeImage and stitchImagesGrid
    let retinaRep1 = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 400,
        pixelsHigh: 120,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    retinaRep1.size = NSSize(width: 200, height: 60)
    let retinaImg1 = NSImage(size: NSSize(width: 200, height: 60))
    retinaImg1.addRepresentation(retinaRep1)

    let retinaVM = PinSessionViewModel(image: retinaImg1)
    let compositeRetina = retinaVM.renderCompositeImage()
    let compositeRep = compositeRetina?.representations.first
    t.check(
        compositeRep?.pixelsWide == 400 && compositeRep?.pixelsHigh == 120,
        "renderCompositeImage preserves exact 2x Retina pixel dimensions (400x120 px for 200x60 pt)"
    )

    let stitchedRetina = ClipboardHelper.stitchImagesGrid([ compositeRetina!, compositeRetina! ])
    let stitchedRep = stitchedRetina.representations.first
    t.check(
        stitchedRetina.size == NSSize(width: 200, height: 120) &&
        stitchedRep?.pixelsWide == 400 && stitchedRep?.pixelsHigh == 240,
        "stitchImagesGrid preserves full 2x Retina pixel resolution (400x240 px for 200x120 pt) without blur"
    )

    let copiedStitched = ClipboardHelper.copyStitchedImage([img1, img2], pasteboard: testPasteboard, tempDir: testTempDirURL.path)
    t.check(
        copiedStitched && (testPasteboard.pasteboardItems?.count == 1),
        "copyStitchedImage writes 1 combined stitched NSPasteboardItem to pasteboard"
    )

    let staleClipURL = testTempDirURL.appendingPathComponent("ClipLine_StaleTest.png")
    let unrelatedURL = testTempDirURL.appendingPathComponent("user_notes.txt")
    do {
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: staleClipURL)
        try Data("keep".utf8).write(to: unrelatedURL)
        let oldDate = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleClipURL.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: unrelatedURL.path)
    } catch {
        t.check(false, "Created stale temp file fixtures in isolated test directory", detail: "\(error)")
    }

    ClipboardHelper.cleanupStaleTempFiles(olderThan: 3600, in: testTempDirURL.path)
    t.check(
        !FileManager.default.fileExists(atPath: staleClipURL.path),
        "cleanupStaleTempFiles removes stale ClipLine_*.png files in target directory"
    )
    t.check(
        FileManager.default.fileExists(atPath: unrelatedURL.path),
        "cleanupStaleTempFiles preserves non-ClipLine files in target directory"
    )

    // -------------------------------------------------------------------------
    // Suite 6: Editable Global Shortcuts, Safe Registration & Native Settings
    // -------------------------------------------------------------------------
    print("\n🔹 Suite 6: Editable Global Shortcuts & Transactional Registration")
    let shortcutSuiteName = "ClipLineShortcutTests_\(UUID().uuidString)"
    guard let shortcutDefaults = UserDefaults(suiteName: shortcutSuiteName) else {
        t.check(false, "Created isolated UserDefaults suite for shortcut tests")
        return t.summary()
    }
    shortcutDefaults.removePersistentDomain(forName: shortcutSuiteName)
    defer { shortcutDefaults.removePersistentDomain(forName: shortcutSuiteName) }
    let shortcutStore = ShortcutConfigurationStore(defaults: shortcutDefaults)

    t.check(
        ShortcutConfiguration.defaults.capture.displayString == "⌃X" &&
        ShortcutConfiguration.defaults.captureSecondary.displayString == "⌘⇧X" &&
        ShortcutConfiguration.defaults.clipboard.displayString == "⌃⌘V",
        "Shortcut defaults preserve the three existing global bindings"
    )
    do {
        try ShortcutValidator.validate(.defaults)
        t.check(true, "Default global shortcut configuration passes validation")
    } catch {
        t.check(false, "Default global shortcut configuration passes validation", detail: "\(error)")
    }

    var invalidShortcut = ShortcutConfiguration.defaults
    invalidShortcut.set(ShortcutBinding(keyCode: 0, carbonModifiers: 0), for: .capture)
    do {
        try ShortcutValidator.validate(invalidShortcut)
        t.check(false, "Shortcut validation rejects a binding without modifiers")
    } catch ShortcutValidationError.requiredModifier {
        t.check(true, "Shortcut validation rejects a binding without modifiers")
    } catch {
        t.check(false, "Shortcut validation rejects a binding without modifiers", detail: "\(error)")
    }

    invalidShortcut.set(ShortcutBinding(keyCode: 0, carbonModifiers: UInt32(shiftKey)), for: .capture)
    do {
        try ShortcutValidator.validate(invalidShortcut)
        t.check(false, "Shortcut validation rejects a shift-only binding")
    } catch ShortcutValidationError.requiredModifier {
        t.check(true, "Shortcut validation rejects a shift-only binding")
    } catch {
        t.check(false, "Shortcut validation rejects a shift-only binding", detail: "\(error)")
    }

    invalidShortcut.set(ShortcutBinding(keyCode: 999, carbonModifiers: UInt32(controlKey)), for: .capture)
    do {
        try ShortcutValidator.validate(invalidShortcut)
        t.check(false, "Shortcut validation rejects unsupported key codes")
    } catch ShortcutValidationError.unsupportedKeyCode(999) {
        t.check(true, "Shortcut validation rejects unsupported key codes")
    } catch {
        t.check(false, "Shortcut validation rejects unsupported key codes", detail: "\(error)")
    }

    invalidShortcut.set(ShortcutBinding(keyCode: UInt16(kVK_ANSI_Q), carbonModifiers: UInt32(cmdKey)), for: .capture)
    do {
        try ShortcutValidator.validate(invalidShortcut)
        t.check(false, "Shortcut validation rejects common app navigation shortcuts")
    } catch ShortcutValidationError.reservedShortcut {
        t.check(true, "Shortcut validation rejects common app navigation shortcuts")
    } catch {
        t.check(false, "Shortcut validation rejects common app navigation shortcuts", detail: "\(error)")
    }

    let commandReservedKeyCodes: [UInt16] = [
        0, 1, 3, 4, 6, 7, 8, 9, 12, 13, 17, 31, 35, 43, 45, 46, 47, 50
    ]
    let blocksBareCommandEditingAndNavigation = commandReservedKeyCodes.allSatisfy { keyCode in
        do {
            try ShortcutValidator.validate(
                ShortcutBinding(keyCode: keyCode, carbonModifiers: UInt32(cmdKey))
            )
            return false
        } catch ShortcutValidationError.reservedShortcut {
            return true
        } catch {
            return false
        }
    }
    t.check(
        blocksBareCommandEditingAndNavigation,
        "Shortcut validation reserves plain Cmd editing and existing app-navigation chords"
    )
    let modifiedEditingChords: [ShortcutBinding] = [
        ShortcutBinding(keyCode: UInt16(kVK_ANSI_V), carbonModifiers: UInt32(controlKey | cmdKey)),
        ShortcutBinding(keyCode: UInt16(kVK_ANSI_X), carbonModifiers: UInt32(cmdKey | shiftKey)),
        ShortcutBinding(keyCode: UInt16(kVK_ANSI_C), carbonModifiers: UInt32(optionKey | cmdKey))
    ]
    t.check(
        modifiedEditingChords.allSatisfy { (try? ShortcutValidator.validate($0)) != nil },
        "Shortcut validation allows useful modified Cmd chords, including Ctrl+Cmd+V"
    )

    invalidShortcut = .defaults
    invalidShortcut.set(invalidShortcut.capture, for: .clipboard)
    do {
        try ShortcutValidator.validate(invalidShortcut)
        t.check(false, "Shortcut validation rejects duplicate bindings")
    } catch ShortcutValidationError.duplicate(.capture, .clipboard) {
        t.check(true, "Shortcut validation rejects duplicate bindings")
    } catch {
        t.check(false, "Shortcut validation rejects duplicate bindings", detail: "\(error)")
    }

    var customShortcuts = ShortcutConfiguration.defaults
    customShortcuts.set(ShortcutBinding(keyCode: UInt16(kVK_ANSI_A), carbonModifiers: UInt32(controlKey)), for: .capture)
    do {
        try shortcutStore.save(customShortcuts)
        t.check(shortcutStore.load() == customShortcuts, "Shortcut settings persist and reload from an isolated defaults suite")
    } catch {
        t.check(false, "Shortcut settings persist and reload from an isolated defaults suite", detail: "\(error)")
    }

    shortcutDefaults.set(Data("not-json".utf8), forKey: ShortcutConfigurationStore.key)
    t.check(shortcutStore.load() == .defaults, "Corrupt shortcut settings safely fall back to defaults")
    shortcutDefaults.set(try! JSONEncoder().encode(invalidShortcut), forKey: ShortcutConfigurationStore.key)
    t.check(shortcutStore.load() == .defaults, "Invalid persisted shortcut settings safely fall back to defaults")
    try? shortcutStore.save(.defaults)
    let persistedDefaults = shortcutDefaults.data(forKey: ShortcutConfigurationStore.key)

    var activeHotKeys: Set<ShortcutAction> = []
    let recordingRuntime = ShortcutRuntime(
        configuration: .defaults,
        register: { action, _ in activeHotKeys.insert(action); return noErr },
        unregister: { action in activeHotKeys.remove(action); return noErr }
    )
    t.check(recordingRuntime.registerAtLaunch().isEmpty && activeHotKeys.count == 3, "Shortcut runtime registers the three hotkeys through injected callbacks")
    let recordingModel = ShortcutSettingsModel(store: shortcutStore, runtime: recordingRuntime)
    let didStartRecording = recordingModel.beginRecording(.capture)
    let recorder = ShortcutRecordingButton(title: "", target: nil, action: nil)
    recorder.configure(
        idleTitle: "⌃X",
        recordingTitle: L10n.shortcutRecordingTitle,
        recording: true,
        accessibilityLabel: "Capture Region shortcut",
        accessibilityValue: L10n.shortcutRecordingAccessibilityValue,
        accessibilityHelp: L10n.shortcutSettingsHelp
    )
    recorder.onCancelled = { recordingModel.cancelRecording(.capture) }
    if let escEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false,
        keyCode: UInt16(kVK_Escape)
    ) {
        let consumed = recorder.handleRecordingEvent(escEvent)
        t.check(
            didStartRecording && consumed && activeHotKeys.count == 3 &&
            recordingModel.recordingAction == nil && recordingRuntime.configuration == .defaults &&
            shortcutDefaults.data(forKey: ShortcutConfigurationStore.key) == persistedDefaults,
            "Escape cancels recording, restores old hotkeys, and leaves persisted settings unchanged"
        )
    } else {
        t.check(false, "Constructed Escape event for shortcut recording")
    }

    var activationHotKeys: Set<ShortcutAction> = []
    let activationRuntime = ShortcutRuntime(
        configuration: .defaults,
        register: { action, _ in activationHotKeys.insert(action); return noErr },
        unregister: { action in activationHotKeys.remove(action); return noErr }
    )
    _ = activationRuntime.registerAtLaunch()
    let activationModel = ShortcutSettingsModel(store: shortcutStore, runtime: activationRuntime)
    let activationButton = ShortcutRecordingButton(title: "", target: nil, action: nil)
    activationButton.configure(
        idleTitle: "⌃X",
        recordingTitle: L10n.shortcutRecordingTitle,
        recording: false,
        accessibilityLabel: "Capture Region shortcut",
        accessibilityValue: "⌃X",
        accessibilityHelp: L10n.shortcutSettingsHelp
    )
    activationButton.onBeginRecording = { activationModel.beginRecording(.capture) }
    activationButton.onCancelled = { activationModel.cancelRecording(.capture) }
    activationButton.performClick(nil)
    t.check(
        activationModel.recordingAction == .capture && activationRuntime.isSuspended,
        "NSButton performClick activates shortcut recording through target/action"
    )
    activationButton.performClick(nil)
    t.check(
        activationModel.recordingAction == nil && activationHotKeys.count == 3,
        "A second standard button activation cancels recording and restores hotkeys"
    )

    let navigationWindow = ShortcutRecorderNavigationWindow(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    let keyViewContainer = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
    let previousKeyView = NSButton(title: "Previous", target: nil, action: nil)
    let nextKeyView = NSButton(title: "Next", target: nil, action: nil)
    let navigationRecorder = ShortcutRecordingButton(title: "", target: nil, action: nil)
    previousKeyView.frame = NSRect(x: 8, y: 30, width: 90, height: 30)
    navigationRecorder.frame = NSRect(x: 120, y: 30, width: 120, height: 30)
    nextKeyView.frame = NSRect(x: 252, y: 30, width: 90, height: 30)
    keyViewContainer.addSubview(previousKeyView)
    keyViewContainer.addSubview(navigationRecorder)
    keyViewContainer.addSubview(nextKeyView)
    previousKeyView.nextKeyView = navigationRecorder
    navigationRecorder.nextKeyView = nextKeyView
    nextKeyView.nextKeyView = previousKeyView
    navigationWindow.contentView = keyViewContainer
    NSApp.activate(ignoringOtherApps: true)
    navigationWindow.makeKeyAndOrderFront(nil)
    navigationRecorder.configure(
        idleTitle: "⌃X",
        recordingTitle: L10n.shortcutRecordingTitle,
        recording: true,
        accessibilityLabel: "Capture Region shortcut",
        accessibilityValue: L10n.shortcutRecordingAccessibilityValue,
        accessibilityHelp: L10n.shortcutSettingsHelp
    )
    var navigationCancelCount = 0
    navigationRecorder.onCancelled = { navigationCancelCount += 1 }
    _ = navigationWindow.makeFirstResponder(navigationRecorder)
    if let tabEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: navigationWindow.windowNumber,
        context: nil,
        characters: "\t",
        charactersIgnoringModifiers: "\t",
        isARepeat: false,
        keyCode: UInt16(kVK_Tab)
    ) {
        let didHandleTab = navigationRecorder.handleRecordingEvent(tabEvent)
        let advancedFocus = navigationWindow.selectedNextKeyView
        navigationRecorder.configure(
            idleTitle: "⌃X",
            recordingTitle: L10n.shortcutRecordingTitle,
            recording: true,
            accessibilityLabel: "Capture Region shortcut",
            accessibilityValue: L10n.shortcutRecordingAccessibilityValue,
            accessibilityHelp: L10n.shortcutSettingsHelp
        )
        _ = navigationWindow.makeFirstResponder(navigationRecorder)
        if let shiftTabEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: navigationWindow.windowNumber,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: UInt16(kVK_Tab)
        ) {
            let didHandleShiftTab = navigationRecorder.handleRecordingEvent(shiftTabEvent)
            let reversedFocus = navigationWindow.selectedPreviousKeyView
            t.check(
                didHandleTab && advancedFocus && didHandleShiftTab &&
                reversedFocus && navigationCancelCount == 2,
                "Tab and Shift+Tab cancel recording and move focus forward/backward",
                detail: "tab=\(didHandleTab), forward=\(advancedFocus), shiftTab=\(didHandleShiftTab), backward=\(reversedFocus), cancels=\(navigationCancelCount)"
            )
        } else {
            t.check(false, "Constructed Shift+Tab event for shortcut recording")
        }
    } else {
        t.check(false, "Constructed Tab event for shortcut recording")
    }
    navigationWindow.close()

    var rejectedBinding: ShortcutBinding?
    activeHotKeys.removeAll()
    let failingRuntime = ShortcutRuntime(
        configuration: .defaults,
        register: { action, binding in
            if binding == rejectedBinding { return -9878 }
            activeHotKeys.insert(action)
            return noErr
        },
        unregister: { action in activeHotKeys.remove(action); return noErr }
    )
    _ = failingRuntime.registerAtLaunch()
    let failingModel = ShortcutSettingsModel(store: shortcutStore, runtime: failingRuntime)
    _ = failingModel.beginRecording(.capture)
    rejectedBinding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_A), carbonModifiers: UInt32(controlKey))
    failingModel.accept(rejectedBinding!, for: .capture)
    t.check(
        failingRuntime.configuration == .defaults && activeHotKeys.count == 3 &&
        activeHotKeys.contains(.capture) && shortcutDefaults.data(forKey: ShortcutConfigurationStore.key) == persistedDefaults &&
        failingModel.errorMessage?.contains("-9878") == true,
        "Registration failure rolls back hotkeys, preserves persisted settings, and reports the Carbon error"
    )

    var contestedHotKeys: Set<ShortcutAction> = []
    var refuseClipboardRestore = false
    let contestedRuntime = ShortcutRuntime(
        configuration: .defaults,
        register: { action, binding in
            if refuseClipboardRestore && action == .clipboard && binding == ShortcutConfiguration.defaults.clipboard {
                return -9878
            }
            contestedHotKeys.insert(action)
            return noErr
        },
        unregister: { action in contestedHotKeys.remove(action); return noErr }
    )
    _ = contestedRuntime.registerAtLaunch()
    let contestedModel = ShortcutSettingsModel(store: shortcutStore, runtime: contestedRuntime)
    _ = contestedModel.beginRecording(.capture)
    refuseClipboardRestore = true
    contestedModel.cancelRecording(.capture)
    t.check(
        contestedRuntime.registeredActions == Set([.capture, .captureSecondary]) &&
        contestedModel.errorMessage?.contains("-9878") == true,
        "A registration conflict while resuming leaves the failed shortcut inactive and reports its OSStatus"
    )
    let switchedRecorder = contestedModel.beginRecording(.captureSecondary)
    t.check(
        switchedRecorder && contestedModel.errorMessage?.contains("-9878") == true,
        "Starting another recorder does not silently clear an unresolved restoration error"
    )
    contestedModel.cancelRecording(.captureSecondary)
    contestedModel.restoreDefaults()
    t.check(
        contestedRuntime.registeredActions == Set([.capture, .captureSecondary]) &&
        contestedModel.errorMessage?.contains("-9878") == true && shortcutStore.load() == .defaults,
        "Restore Defaults retries a missing unchanged shortcut and keeps a failed retry visible"
    )
    refuseClipboardRestore = false
    contestedModel.restoreDefaults()
    t.check(
        contestedRuntime.registeredActions.count == 3 && contestedModel.errorMessage == nil &&
        shortcutStore.load() == .defaults,
        "Restore Defaults retries and recovers the previously contested shortcut"
    )

    var failedLaunchHotKeys: Set<ShortcutAction> = []
    let failedLaunchRuntime = ShortcutRuntime(
        configuration: .defaults,
        register: { action, _ in failedLaunchHotKeys.insert(action); return -9878 },
        unregister: { action in failedLaunchHotKeys.remove(action); return noErr }
    )
    let launchFailures = failedLaunchRuntime.registerAtLaunch()
    let failedLaunchModel = ShortcutSettingsModel(
        store: shortcutStore,
        runtime: failedLaunchRuntime,
        launchRegistrationFailures: launchFailures
    )
    t.check(
        launchFailures.count == 3 && failedLaunchModel.errorMessage?.contains("-9878") == true,
        "Shortcut settings model surfaces every global shortcut registration failure from launch"
    )
    let failedLaunchWindowController = ShortcutSettingsWindowController(model: failedLaunchModel)
    if let failedLaunchWindow = failedLaunchWindowController.window,
       let hostingView = failedLaunchWindow.contentView as? NSHostingView<ShortcutSettingsView> {
        let fitSize = hostingView.fittingSize
        let contentSize = hostingView.bounds.size
        t.check(
            contentSize.width + 1 >= fitSize.width && contentSize.height + 1 >= fitSize.height &&
            abs(contentSize.width - 460) < 1,
            "Shortcut settings window fits the hosting view and long launch errors without horizontal overflow",
            detail: "content=\(contentSize), fitting=\(fitSize)"
        )
    } else {
        t.check(false, "Shortcut settings window hosts a measurable SwiftUI settings view")
    }

    var lostKeyHotKeys: Set<ShortcutAction> = []
    let lostKeyRuntime = ShortcutRuntime(
        configuration: .defaults,
        register: { action, _ in lostKeyHotKeys.insert(action); return noErr },
        unregister: { action in lostKeyHotKeys.remove(action); return noErr }
    )
    _ = lostKeyRuntime.registerAtLaunch()
    let lostKeyModel = ShortcutSettingsModel(store: shortcutStore, runtime: lostKeyRuntime)
    let lostKeyController = ShortcutSettingsWindowController(model: lostKeyModel)
    let lostKeyRecordingStarted = lostKeyModel.beginRecording(.capture)
    lostKeyController.windowDidResignKey(
        Notification(name: NSWindow.didResignKeyNotification, object: lostKeyController.window)
    )
    t.check(
        lostKeyRecordingStarted && lostKeyModel.recordingAction == nil &&
        lostKeyRuntime.registeredActions.count == 3 && !lostKeyRuntime.isSuspended,
        "Losing key-window status cancels recording and restores all global hotkeys"
    )

    shortcutDefaults.set(try! shortcutStore.encodedData(for: customShortcuts), forKey: ShortcutConfigurationStore.key)
    var restoredHotKeys: Set<ShortcutAction> = []
    let restoreRuntime = ShortcutRuntime(
        configuration: customShortcuts,
        register: { action, _ in restoredHotKeys.insert(action); return noErr },
        unregister: { action in restoredHotKeys.remove(action); return noErr }
    )
    _ = restoreRuntime.registerAtLaunch()
    let restoreModel = ShortcutSettingsModel(store: shortcutStore, runtime: restoreRuntime)
    restoreModel.restoreDefaults()
    t.check(
        restoreModel.configuration == .defaults && restoreRuntime.configuration == .defaults &&
        shortcutStore.load() == .defaults && restoredHotKeys.count == 3,
        "Restore Defaults atomically applies and persists all factory shortcuts"
    )

    do {
        let json = try ShortcutConfiguration.defaults.cliJSON()
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]]
        t.check(
            object?["capture"]?["shortcut"] as? String == "⌃X" &&
            object?["capture-secondary"]?["keyCode"] as? Int == Int(kVK_ANSI_X) &&
            object?["clipboard"]?["carbonModifiers"] as? Int == Int(controlKey | cmdKey),
            "--shortcuts JSON names all three bindings and includes readable labels plus key codes"
        )
    } catch {
        t.check(false, "--shortcuts JSON names all three bindings and includes readable labels plus key codes", detail: "\(error)")
    }

    let settingsController = ShortcutSettingsWindowController(model: restoreModel)
    t.check(
        settingsController.window?.title == L10n.shortcutWindowTitle && settingsController.window?.contentView != nil,
        "Native shortcut settings controller creates a titled window with hosted UI"
    )

    // -------------------------------------------------------------------------
    // Suite 7: Localization (Language Tag Matching, Exhaustive EN/zh-Hans Copy & Toolbar Layout)
    // -------------------------------------------------------------------------
    print("\n🔹 Suite 7: Localization (EN & Simplified Chinese)")
    let originalLang = AppLanguage.current
    defer { AppLanguage.current = originalLang }

    t.check(
        AppLanguage.resolveLanguage(envOverride: "zh-CN", preferredLanguages: ["en-US"]) == .zhHans &&
        AppLanguage.resolveLanguage(envOverride: "en_US", preferredLanguages: ["zh-Hans-CN"]) == .en,
        "CLIP_LINE_LANG environment override takes precedence over preferredLanguages"
    )
    t.check(
        AppLanguage.resolveLanguage(envOverride: nil, preferredLanguages: ["zh-Hant-HK", "en-US"]) == .en &&
        AppLanguage.resolveLanguage(envOverride: nil, preferredLanguages: ["zh-Hans-CN", "en-US"]) == .zhHans &&
        AppLanguage.resolveLanguage(envOverride: nil, preferredLanguages: ["ja-JP", "zh-SG"]) == .zhHans &&
        AppLanguage.resolveLanguage(envOverride: nil, preferredLanguages: ["fr-FR", "de-DE"]) == .en,
        "Preferred language resolution matches first supported tag and does not misclassify Traditional Chinese (zh-Hant) as zh-Hans"
    )
    t.check(
        AppLanguage.resolveTranslateTargetLanguage(envOverride: "ja", uiLanguage: .en) == "ja" &&
        AppLanguage.resolveTranslateTargetLanguage(envOverride: nil, uiLanguage: .en) == "en" &&
        AppLanguage.resolveTranslateTargetLanguage(envOverride: nil, uiLanguage: .zhHans) == "zh-CN",
        "CLIP_LINE_TRANSLATE_TARGET overrides default translate target while keeping UI language independent"
    )

    AppLanguage.current = .en
    t.check(
        PinAnnotation.Tool.rect.localizedName == "Rectangle" &&
        StrokePreset.thin.localizedShortLabel == "S" &&
        TextBackgroundStyle.transparent.localizedShortLabel == "Clear" &&
        L10n.toolbarTranslateShortLabel == "Trans" &&
        L10n.toastCopiedPhotos(1) == "Copied 1 image to clipboard" &&
        L10n.toastCopiedPhotos(3) == "Copied 3 images to clipboard",
        "English localization produces compact labels and proper singular/plural toasts"
    )

    // Verify English toolbar layout with .text tool active (widest configuration: tools + S/M/L + 6 colors + Clear/Dark/Light + actions)
    let enVM = PinSessionViewModel(image: baseImg)
    daemon.presentPinPanel(vm: enVM, frame: panelFrame)
    enVM.activeTool = .text
    let enToolbarWidth = enVM.toolbarPanel?.frame.width ?? 0
    let screenVisibleWidth = max(1280, (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.width ?? 1440)
    t.check(
        enToolbarWidth > 500 && enToolbarWidth < min(1100, screenVisibleWidth - 16),
        "English toolbar in widest (.text) state fits cleanly within screen bounds (\(Int(enToolbarWidth))pt)"
    )
    enVM.hostingPanel?.onClosePanel?()

    AppLanguage.current = .zhHans
    t.check(
        PinAnnotation.Tool.rect.localizedName == "框选" &&
        StrokePreset.thin.localizedShortLabel == "细" &&
        TextBackgroundStyle.transparent.localizedShortLabel == "透明" &&
        L10n.toolbarTranslateShortLabel == "译" &&
        L10n.toastCopiedPhotos(2) == "已复制 2 张照片到剪贴板",
        "Simplified Chinese localization produces expected native labels and toasts"
    )

    runClipLineUpdaterTests(t)

    return t.summary()
}
