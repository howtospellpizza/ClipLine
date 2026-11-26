import AppKit
import CoreGraphics
import Foundation

@MainActor
private final class AsyncScrollingCaptureGate {
    private var continuations: [CheckedContinuation<CGImage?, Never>?] = []
    private var requestWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var requestCount = 0

    func capture(_ rect: NSRect) async -> CGImage? {
        await withCheckedContinuation { continuation in
            requestCount += 1
            continuations.append(continuation)
            requestWaiters.removeValue(forKey: requestCount)?.resume()
        }
    }

    func waitForRequest(_ count: Int) async {
        guard requestCount < count else { return }
        await withCheckedContinuation { requestWaiters[count] = $0 }
    }

    func resolveRequest(_ index: Int, with image: CGImage?) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else { return }
        continuations[index] = nil
        continuation.resume(returning: image)
    }
}

@MainActor
private func imageMatchesScrollingFrame(_ image: NSImage, _ reference: CGImage) -> Bool {
    var proposedRect = NSRect(origin: .zero, size: image.size)
    guard let actualImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return false }
    let actualRows = ScrollingImageStitcher.extractRowSignatures(from: actualImage)
    let expectedRows = ScrollingImageStitcher.extractRowSignatures(from: reference)
    return actualRows.count == expectedRows.count && zip(actualRows, expectedRows).allSatisfy { $0.samples == $1.samples }
}

@MainActor
private func runAsyncScrollingCaptureTests(
    _ t: TestHarness,
    frame0: CGImage,
    frame1: CGImage,
    frame2: CGImage
) async {
    let screenFrame = NSRect(x: 0, y: 0, width: 100, height: 80)
    let selection = CaptureSelectionResult(
        fullScreenCGImage: frame0,
        fullScreenFrame: screenFrame,
        scaleFactor: 2.0,
        selectedScreenRect: screenFrame,
        croppedImage: NSImage(cgImage: frame0, size: screenFrame.size),
        isScrollingCapture: true
    )

    let overlayController = ScreenCaptureOverlayController()
    let overlayGate = AsyncScrollingCaptureGate()
    overlayController.scrollingRegionCaptureProvider = { rect in await overlayGate.capture(rect) }
    var overlayResult: CaptureSelectionResult?
    overlayController.installCaptureOverlays(
        descriptors: [(screenFrame: screenFrame, cgImage: frame0, candidateWindowRects: [], isInitialCursorScreen: true)],
        hideSystemCursor: false,
        completion: { overlayResult = $0 }
    )
    let overlaySeedTask = overlayController.finish(with: selection)
    await overlayGate.waitForRequest(1)
    t.check(
        overlayController.overlayWindows.isEmpty && overlayGate.requestCount == 1,
        "Overlay-L scrolling capture requests a fresh async seed after hiding the selection overlay"
    )
    overlayGate.resolveRequest(0, with: frame1)
    await overlaySeedTask?.value
    let overlaySession = overlayController.activeScrollingSession
    t.check(
        overlaySession?.isActive == true &&
        overlayResult == nil &&
        overlaySession.map { imageMatchesScrollingFrame($0.previewImage, frame1) } == true,
        "Overlay-L starts its session from the completed fresh seed before delivering a result"
    )
    overlayController.cancelActiveCapture(reason: "async overlay seed test cleanup")

    let directController = ScreenCaptureOverlayController()
    let directGate = AsyncScrollingCaptureGate()
    directController.scrollingRegionCaptureProvider = { rect in await directGate.capture(rect) }
    let directSeedTask = directController.beginDirectScrollingCapture(initialSelection: selection) { _ in }
    await directGate.waitForRequest(1)
    directGate.resolveRequest(0, with: frame1)
    await directSeedTask?.value
    let directSession = directController.activeScrollingSession
    t.check(
        directGate.requestCount == 1 && directSession.map { imageMatchesScrollingFrame($0.previewImage, frame1) } == true,
        "Direct-Pin scrolling capture uses the completed filtered frame as its fresh initial seed"
    )
    directController.cancelActiveCapture(reason: "async direct seed test cleanup")

    let failedSeedController = ScreenCaptureOverlayController()
    var failedSeedRequestCount = 0
    failedSeedController.scrollingRegionCaptureProvider = { _ in
        failedSeedRequestCount += 1
        return nil
    }
    var failedSeedResult: CaptureSelectionResult? = selection
    let failedSeedTask = failedSeedController.beginDirectScrollingCapture(initialSelection: selection) {
        failedSeedResult = $0
    }
    await failedSeedTask?.value
    t.check(
        failedSeedRequestCount == 1 && failedSeedResult == nil && failedSeedController.activeScrollingSession == nil,
        "Async initial-seed failure completes nil without starting a session or falling back to unfiltered capture"
    )

    let seedController = ScreenCaptureOverlayController()
    let seedGate = AsyncScrollingCaptureGate()
    seedController.scrollingRegionCaptureProvider = { rect in await seedGate.capture(rect) }
    var seedCallbackCount = 0
    var seedResult: CaptureSelectionResult? = selection
    let seedTask = seedController.beginDirectScrollingCapture(initialSelection: selection) { result in
        seedCallbackCount += 1
        seedResult = result
    }
    await seedGate.waitForRequest(1)
    seedController.cancelActiveCapture(reason: "async seed cancellation test")
    seedGate.resolveRequest(0, with: frame1)
    await seedTask?.value
    t.check(
        seedCallbackCount == 1 && seedResult == nil && seedController.activeScrollingSession == nil,
        "Cancelling a pending direct-Pin seed suppresses the late capture result and completes only once"
    )

    let sampleGate = AsyncScrollingCaptureGate()
    let session = ScrollingCaptureSessionController(
        initialSelection: selection,
        initialCropCGImage: frame0,
        asyncCaptureRegionProvider: { rect in await sampleGate.capture(rect) }
    )
    var finalResult: CaptureSelectionResult?
    var completionCount = 0
    session.start { result in
        completionCount += 1
        finalResult = result
    }
    _ = session.sampleNextFrameIfChanged()
    await sampleGate.waitForRequest(1)
    session.sampleNextFrameIfChanged()
    session.sampleNextFrameIfChanged()
    let finalFlushTask = session.finishCapture()
    t.check(
        sampleGate.requestCount == 1 && finalResult == nil,
        "Async scrolling capture serializes overlapping sample requests and waits for the in-flight frame"
    )
    sampleGate.resolveRequest(0, with: frame1)
    await sampleGate.waitForRequest(2)
    t.check(
        sampleGate.requestCount == 2 && finalResult == nil,
        "Finishing an in-flight sample queues one final clean frame without completing early"
    )
    sampleGate.resolveRequest(1, with: frame2)
    await finalFlushTask?.value
    t.check(
        completionCount == 1 && finalResult?.croppedImage.size == NSSize(width: 100, height: 128) && !session.isActive,
        "Async finish exports only after the final frame is stitched and invokes completion once"
    )

    let cancellationGate = AsyncScrollingCaptureGate()
    let cancelledSession = ScrollingCaptureSessionController(
        initialSelection: selection,
        initialCropCGImage: frame0,
        asyncCaptureRegionProvider: { rect in await cancellationGate.capture(rect) }
    )
    var cancellationCallbackCount = 0
    var cancellationResult: CaptureSelectionResult? = selection
    cancelledSession.start { result in
        cancellationCallbackCount += 1
        cancellationResult = result
    }
    let lateSampleTask = cancelledSession.sampleNextFrameIfChanged()
    await cancellationGate.waitForRequest(1)
    cancelledSession.cancelCapture()
    cancellationGate.resolveRequest(0, with: frame1)
    await lateSampleTask?.value
    t.check(
        cancellationCallbackCount == 1 && cancellationResult == nil && cancelledSession.pointHeight == 80 && !cancelledSession.isActive,
        "Cancelling an in-flight async sample suppresses late stitching and callback resurrection"
    )

    let failedFinalGate = AsyncScrollingCaptureGate()
    let failedFinalSession = ScrollingCaptureSessionController(
        initialSelection: selection,
        initialCropCGImage: frame0,
        asyncCaptureRegionProvider: { rect in await failedFinalGate.capture(rect) }
    )
    var failedFinalResult: CaptureSelectionResult? = selection
    failedFinalSession.start { failedFinalResult = $0 }
    let precedingSample = failedFinalSession.sampleNextFrameIfChanged()
    await failedFinalGate.waitForRequest(1)
    failedFinalGate.resolveRequest(0, with: frame1)
    await precedingSample?.value
    let failedFinalTask = failedFinalSession.finishCapture()
    await failedFinalGate.waitForRequest(2)
    failedFinalGate.resolveRequest(1, with: nil)
    await failedFinalTask?.value
    t.check(
        failedFinalSession.slicesCount == 2 && failedFinalResult == nil,
        "A failed final async frame rejects the export even after earlier frames stitched successfully"
    )

    let directionGate = AsyncScrollingCaptureGate()
    let directionSession = ScrollingCaptureSessionController(
        initialSelection: selection,
        initialCropCGImage: frame0,
        asyncCaptureRegionProvider: { rect in await directionGate.capture(rect) }
    )
    let now = CFAbsoluteTimeGetCurrent()
    directionSession.recordScrollEvent(scrollingDeltaY: -12, timestamp: now - 0.6)
    let directionTask = directionSession.sampleNextFrameIfChanged()
    await directionGate.waitForRequest(1)
    directionSession.recordScrollEvent(scrollingDeltaY: -8, timestamp: now - 0.4)
    directionSession.recordScrollEvent(scrollingDeltaY: -8, timestamp: now)
    directionGate.resolveRequest(0, with: frame1)
    await directionTask?.value
    t.check(
        directionSession.slicesCount == 2 && directionSession.peekPendingDirectionHint(now: now) == .downward,
        "An expired async snapshot consumes only its own delta and preserves newer in-flight wheel events"
    )
    directionSession.cancelCapture()

    let focusDaemon = PinDaemonApp()
    let focusGate = AsyncScrollingCaptureGate()
    focusDaemon.captureController.scrollingRegionCaptureProvider = { rect in await focusGate.capture(rect) }
    let pinSelection = CaptureSelectionResult(
        fullScreenCGImage: frame0, fullScreenFrame: screenFrame, scaleFactor: 2,
        selectedScreenRect: screenFrame, croppedImage: selection.croppedImage, isScrollingCapture: false
    )
    focusDaemon.createPinWindow(fromCapture: pinSelection)
    let focusPanel = focusDaemon.activePanels.values.first
    focusPanel?.viewModel?.onStartScrollingCapture?()
    await focusGate.waitForRequest(1)
    focusDaemon.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
    t.check(
        focusDaemon.captureController.isScrollingCapturePending && focusPanel?.isVisible == false,
        "Switching to the target app while the fresh toolbar seed is pending does not cancel scrolling capture"
    )
    focusDaemon.captureController.cancelActiveCapture(reason: "pending seed focus test cleanup")
    focusGate.resolveRequest(0, with: frame1)
    focusPanel?.onClosePanel?()

    let failedSession = ScrollingCaptureSessionController(
        initialSelection: selection,
        initialCropCGImage: frame0,
        asyncCaptureRegionProvider: { _ in nil }
    )
    var failedResult: CaptureSelectionResult? = selection
    failedSession.start { failedResult = $0 }
    let failedFinishTask = failedSession.finishCapture()
    await failedFinishTask?.value
    t.check(
        failedResult == nil && failedSession.statusWarning == L10n.scrollingCaptureCaptureFailedWarning,
        "Async final-frame failure warns and fails closed when no live frame was captured"
    )
}

@MainActor
func runSuite1CaptureAndCropTests(_ t: TestHarness, testPasteboard: NSPasteboard, testTempDirURL: URL) {
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

    let captureGeometry1x = ScreenCaptureOverlayController.scrollingCaptureGeometry(
        screenRect: cropRect,
        screenFrame: screenFrame,
        pointPixelScale: 1.0
    )
    let captureGeometry2x = ScreenCaptureOverlayController.scrollingCaptureGeometry(
        screenRect: cropRect,
        screenFrame: screenFrame,
        pointPixelScale: 2.0
    )
    let secondaryCaptureGeometry = ScreenCaptureOverlayController.scrollingCaptureGeometry(
        screenRect: NSRect(x: -1200, y: 100, width: 200, height: 300),
        screenFrame: NSRect(x: -1280, y: -100, width: 1280, height: 1024),
        pointPixelScale: 2.0
    )
    t.check(
        captureGeometry1x?.sourceRect == CGRect(x: 100, y: 100, width: 160, height: 120) &&
        captureGeometry1x?.pixelWidth == 160 && captureGeometry1x?.pixelHeight == 120 &&
        captureGeometry2x?.sourceRect == captureGeometry1x?.sourceRect &&
        captureGeometry2x?.pixelWidth == 320 && captureGeometry2x?.pixelHeight == 240 &&
        secondaryCaptureGeometry?.sourceRect == CGRect(x: 80, y: 524, width: 200, height: 300) &&
        secondaryCaptureGeometry?.pixelWidth == 400 && secondaryCaptureGeometry?.pixelHeight == 600 &&
        ScreenCaptureOverlayController.scrollingCaptureGeometry(
            screenRect: NSRect(x: -1, y: 0, width: 10, height: 10),
            screenFrame: screenFrame,
            pointPixelScale: 2.0
        ) == nil,
        "Scrolling capture geometry maps top-left sourceRect and Retina pixels on primary and negative-origin displays, rejecting out-of-display crops"
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
    // Verify stale TCC scenario: preflightAccess (live check) returns false, even if requestAccess() returns cached true
    let staleTCCController = ScreenCaptureOverlayController()
    var stalePreflightCalls = 0
    var staleRequestCalls = 0
    var staleAlertCalls = 0
    staleTCCController.preflightAccess = {
        stalePreflightCalls += 1
        return false
    }
    staleTCCController.requestAccess = {
        staleRequestCalls += 1
        return true
    }
    staleTCCController.presentPermissionAlert = {
        staleAlertCalls += 1
    }
    var staleCaptureCompletedWithNil = false
    staleTCCController.beginCapture { result in
        staleCaptureCompletedWithNil = (result == nil)
    }
    t.check(
        staleCaptureCompletedWithNil && stalePreflightCalls == 2 && staleRequestCalls == 1 && staleAlertCalls == 1,
        "ensureScreenCaptureAccess re-verifies live preflightAccess after requestAccess() returns true and presents permission HUD on stale TCC"
    )
    t.check(
        !ScreenCaptureOverlayController.canReadWindowNamesFromWindowList([
            [kCGWindowOwnerPID as String: pid_t(1255), kCGWindowOwnerName as String: "Window Server", kCGWindowLayer as String: 24, kCGWindowName as String: "Menubar"],
            [kCGWindowOwnerPID as String: pid_t(1256), kCGWindowOwnerName as String: "Dock", kCGWindowLayer as String: 20, kCGWindowName as String: "Desktop Picture"],
            [kCGWindowOwnerPID as String: pid_t(2566), kCGWindowOwnerName as String: "Google Chrome", kCGWindowLayer as String: 0]
        ], ownPID: 999) &&
        ScreenCaptureOverlayController.canReadWindowNamesFromWindowList([
            [kCGWindowOwnerPID as String: pid_t(1255), kCGWindowOwnerName as String: "Window Server", kCGWindowLayer as String: 24, kCGWindowName as String: "Menubar"],
            [kCGWindowOwnerPID as String: pid_t(2566), kCGWindowOwnerName as String: "Google Chrome", kCGWindowLayer as String: 0, kCGWindowName as String: ""]
        ], ownPID: 999) &&
        ScreenCaptureOverlayController.canReadWindowNamesFromWindowList([
            [kCGWindowOwnerPID as String: pid_t(1255), kCGWindowOwnerName as String: "Window Server", kCGWindowLayer as String: 24, kCGWindowName as String: "Menubar"],
            [kCGWindowOwnerPID as String: pid_t(999), kCGWindowOwnerName as String: "clipline", kCGWindowLayer as String: 3, kCGWindowName as String: "Keyboard Shortcuts"]
        ], ownPID: 999),
        "canReadWindowNamesFromWindowList ignores Window Server/Dock names, denies nameless external windows, and treats desktops with no external app windows as inconclusive-authorized"
    )
    t.check(
        ScreenCaptureOverlayController.hasLiveScreenCaptureAccess(
            preflight: { true },
            windowListProvider: { nil }
        ) &&
        ScreenCaptureOverlayController.hasLiveScreenCaptureAccess(
            preflight: { true },
            windowListProvider: { [] }
        ) &&
        !ScreenCaptureOverlayController.hasLiveScreenCaptureAccess(
            preflight: { false },
            windowListProvider: { [] }
        ) &&
        ScreenCaptureOverlayController.hasLiveScreenCaptureAccess(
            preflight: { true },
            windowListProvider: {
                [[kCGWindowOwnerPID as String: pid_t(2566), kCGWindowOwnerName as String: "Google Chrome", kCGWindowName as String: "Tab"]]
            }
        ),
        "hasLiveScreenCaptureAccess treats empty/nil window list as inconclusive when preflight is true and succeeds when non-system kCGWindowName is present"
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
            ownerPID: 100,
            ownPID: 100,
            ownerName: "ClipLine",
            layer: 0,
            alpha: 1.0,
            viewRect: NSRect(x: 40, y: 30, width: 300, height: 220),
            screenSize: NSSize(width: 400, height: 300)
        ) &&
        !ScreenCaptureOverlayController.shouldIncludeWindowForSnap(
            ownerPID: 200,
            ownPID: 100,
            ownerName: "Dock",
            layer: 0,
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
            viewRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            screenSize: NSSize(width: 400, height: 300)
        ),
        "shouldIncludeWindowForSnap excludes own process and Dock backdrop while keeping Stage Manager thumbnails and fullscreen app windows"
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
    if let downDrag = NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 70, y: 100), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 3, clickCount: 1, pressure: 1.0
    ),
       let moveDrag = NSEvent.mouseEvent(
        with: .leftMouseDragged, location: NSPoint(x: 150, y: 160), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 4, clickCount: 1, pressure: 1.0
       ),
       let upDrag = NSEvent.mouseEvent(
        with: .leftMouseUp, location: NSPoint(x: 150, y: 160), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 5, clickCount: 1, pressure: 1.0
       ) {
        snapSelectionView.mouseDown(with: downDrag)
        snapSelectionView.mouseDragged(with: moveDrag)
        snapSelectionView.mouseUp(with: upDrag)
        t.check(
            snappedResult?.selectedScreenRect == NSRect(x: 70, y: 100, width: 80, height: 60),
            "Dragging >=4pt overrides hovered window snap and captures the custom selection rect",
            detail: "got \(String(describing: snappedResult?.selectedScreenRect))"
        )
    }
    snappedResult = nil
    if let repeatSpace = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: true, keyCode: 49
    ) {
        snapSelectionView.keyDown(with: repeatSpace)
        t.check(
            snappedResult == nil,
            "Auto-repeated Space keyDown is ignored by capture overlay"
        )
    }
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
    snappedResult = nil
    if let cmdAKey = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
        context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
    ) {
        snapSelectionView.keyDown(with: cmdAKey)
        t.check(
            snappedResult?.selectedScreenRect == screenFrame,
            "Pressing Cmd+A in capture overlay captures the entire screen",
            detail: "got \(String(describing: snappedResult?.selectedScreenRect))"
        )
    }

    // Verify Loupe HEX pixel sampling with deterministic quadrant colors & pressing 'C' copies #HEX color to pasteboard and exits capture
    snapSelectionView.pasteboardProvider = { testPasteboard }
    testPasteboard.clearContents()
    if let quadSpace = CGColorSpace(name: CGColorSpace.sRGB),
       let quadCtx = CGContext(
        data: nil,
        width: 200,
        height: 100,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: quadSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
       ) {
        // CoreGraphics context origin is bottom-left:
        // Bottom half (CG y: 0..<50 => CGImage pixel y: 50..<100 => view y: 0..<25 at scale 2.0): pure BLUE (#0000FF)
        quadCtx.setFillColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0)
        quadCtx.fill(CGRect(x: 0, y: 0, width: 200, height: 50))
        // Top-left (CG x: 0..<100, y: 50..<100 => CGImage pixel x: 0..<100, y: 0..<50 => view x: 0..<50, y: 25..<50): pure RED (#FF0000)
        quadCtx.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        quadCtx.fill(CGRect(x: 0, y: 50, width: 100, height: 50))
        // Top-right (CG x: 100..<200, y: 50..<100 => view x: 50..<100, y: 25..<50): pure GREEN (#00FF00)
        quadCtx.setFillColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0)
        quadCtx.fill(CGRect(x: 100, y: 50, width: 100, height: 50))

        if let quadCG = quadCtx.makeImage() {
            let quadViewSize = NSSize(width: 100, height: 50)
            let sampledTopLeft = PixPinSelectionView.samplePixelHexColor(
                cgImage: quadCG,
                viewHeight: quadViewSize.height,
                scaleFactor: 2.0,
                viewPoint: NSPoint(x: 20, y: 40)
            )
            let sampledTopRight = PixPinSelectionView.samplePixelHexColor(
                cgImage: quadCG,
                viewHeight: quadViewSize.height,
                scaleFactor: 2.0,
                viewPoint: NSPoint(x: 75, y: 40)
            )
            let sampledBottom = PixPinSelectionView.samplePixelHexColor(
                cgImage: quadCG,
                viewHeight: quadViewSize.height,
                scaleFactor: 2.0,
                viewPoint: NSPoint(x: 20, y: 10)
            )
            t.check(
                sampledTopLeft?.hex == "#FF0000" &&
                sampledTopRight?.hex == "#00FF00" &&
                sampledBottom?.hex == "#0000FF",
                "samplePixelHexColor maps Retina scale and inverted Y view coordinates to exact deterministic #RRGGBB colors",
                detail: "topLeft=\(String(describing: sampledTopLeft?.hex)), topRight=\(String(describing: sampledTopRight?.hex)), bottom=\(String(describing: sampledBottom?.hex))"
            )
            var finishedOnColorCopy = false
            let colorPickView = PixPinSelectionView(
                frame: NSRect(origin: .zero, size: quadViewSize),
                screenOrigin: .zero,
                frozenImage: NSImage(cgImage: quadCG, size: quadViewSize),
                cgImage: quadCG,
                scaleFactor: 2.0,
                crosshairConfig: CrosshairConfiguration(style: .dotRing, color: .green, showLoupe: true),
                onFinish: { res in finishedOnColorCopy = (res == nil) }
            )
            colorPickView.pasteboardProvider = { testPasteboard }
            if let moveEv = NSEvent.mouseEvent(
                with: .mouseMoved, location: NSPoint(x: 75, y: 40), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 6, clickCount: 0, pressure: 0
            ),
               let cKey = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
               ) {
                colorPickView.mouseMoved(with: moveEv)
                colorPickView.keyDown(with: cKey)
                let copiedHex = testPasteboard.string(forType: .string)
                t.check(
                    finishedOnColorCopy && copiedHex == "#00FF00",
                    "Pressing 'C' in capture overlay copies exact hovered pixel #00FF00 to pasteboard and exits capture cleanly",
                    detail: "copied=\(String(describing: copiedHex))"
                )
            } else {
                t.check(false, "Constructed mouseMoved and 'C' keyEvent for HEX color picker test")
            }
        } else {
            t.check(false, "Created quadrant CGImage for HEX color picker test")
        }
    } else {
        t.check(false, "Created sRGB CGContext for HEX color picker test")
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

    let featureBaseImage = makeTextImage(text: "HIGHLIGHT", size: NSSize(width: 200, height: 80))
    let featureVM = PinSessionViewModel(image: featureBaseImage)
    t.check(featureVM.nextCounterLabel == "1", "nextCounterLabel starts at 1 when no counter annotations exist")
    featureVM.annotations.append(PinAnnotation(tool: .counter, color: .systemRed, lineWidth: 28, points: [CGPoint(x: 0.25, y: 0.28)], text: featureVM.nextCounterLabel))
    t.check(featureVM.nextCounterLabel == "2", "nextCounterLabel increments to 2 after placing first counter badge")
    featureVM.annotations.append(PinAnnotation(tool: .highlighter, color: .systemYellow, lineWidth: 22, points: [CGPoint(x: 0.15, y: 0.72), CGPoint(x: 0.85, y: 0.72)]))
    let renderedWithCounterAndHighlight = featureVM.renderCompositeImage()
    var counterAndHighlightRegionCheck = false
    if let renderedWithCounterAndHighlight,
       let baseTIFF = featureBaseImage.tiffRepresentation,
       let baseBMP = NSBitmapImageRep(data: baseTIFF),
       let outTIFF = renderedWithCounterAndHighlight.tiffRepresentation,
       let outBMP = NSBitmapImageRep(data: outTIFF),
       baseBMP.pixelsWide == outBMP.pixelsWide,
       baseBMP.pixelsHigh == outBMP.pixelsHigh {
        let w = outBMP.pixelsWide
        let h = outBMP.pixelsHigh
        // NSBitmapImageRep.colorAt(x:y:) uses top-left origin (y=0 at top), matching normalized top-down Y!
        // Counter badge is at normalized (0.25, 0.28); highlighter stroke is at normalized y=0.72 across x in [0.15, 0.85].
        var badgeRedInsideRegion = 0
        var badgeRedOutsideRegion = 0
        var highlightYellowInsideRegion = 0
        var highlightYellowOutsideRegion = 0
        var untouchedCornerMatchesBase = true

        for y in stride(from: 2, to: h - 2, by: 2) {
            let ny = CGFloat(y) / CGFloat(h)
            for x in stride(from: 2, to: w - 2, by: 2) {
                let nx = CGFloat(x) / CGFloat(w)
                guard let c = outBMP.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let bc = baseBMP.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }

                let isRed = c.redComponent > 0.75 && c.greenComponent < 0.35 && c.blueComponent < 0.35
                let isYellow = c.redComponent > 0.85 && c.greenComponent > 0.80 && c.blueComponent < 0.75

                let inBadgeBox = (nx >= 0.14 && nx <= 0.36 && ny >= 0.04 && ny <= 0.52)
                let inHighlightBox = (nx >= 0.10 && nx <= 0.90 && ny >= 0.54 && ny <= 0.90)

                if isRed {
                    if inBadgeBox { badgeRedInsideRegion += 1 } else { badgeRedOutsideRegion += 1 }
                }
                if isYellow {
                    if inHighlightBox { highlightYellowInsideRegion += 1 } else { highlightYellowOutsideRegion += 1 }
                }

                // Far top-right region (nx > 0.75, ny < 0.22) must remain identical to base image
                if nx > 0.75 && ny < 0.22 {
                    let diff = abs(c.redComponent - bc.redComponent) + abs(c.greenComponent - bc.greenComponent) + abs(c.blueComponent - bc.blueComponent)
                    if diff > 0.02 {
                        untouchedCornerMatchesBase = false
                    }
                }
            }
        }
        counterAndHighlightRegionCheck = (
            badgeRedInsideRegion >= 8 &&
            badgeRedOutsideRegion == 0 &&
            highlightYellowInsideRegion >= 8 &&
            highlightYellowOutsideRegion == 0 &&
            untouchedCornerMatchesBase
        )
    }
    t.check(
        renderedWithCounterAndHighlight?.size == NSSize(width: 200, height: 80) && counterAndHighlightRegionCheck,
        "renderCompositeImage paints .counter badge and .highlighter stroke inside their expected regions while leaving outside pixels untouched"
    )
    featureVM.undo()
    featureVM.undo()
    t.check(
        featureVM.nextCounterLabel == "1",
        "Undoing counter badge decrements nextCounterLabel back to 1"
    )
    let badge1 = PinAnnotation(tool: .counter, color: .systemRed, lineWidth: 28, points: [CGPoint(x: 0.2, y: 0.3)], text: featureVM.nextCounterLabel)
    featureVM.annotations.append(badge1)
    let badge2 = PinAnnotation(tool: .counter, color: .systemRed, lineWidth: 28, points: [CGPoint(x: 0.5, y: 0.3)], text: featureVM.nextCounterLabel)
    featureVM.annotations.append(badge2)
    let badge3 = PinAnnotation(tool: .counter, color: .systemRed, lineWidth: 28, points: [CGPoint(x: 0.8, y: 0.3)], text: featureVM.nextCounterLabel)
    featureVM.annotations.append(badge3)
    featureVM.selectedTextAnnotationID = badge1.id
    let deletedFirstBadge = featureVM.deleteSelectedAnnotation()
    t.check(
        deletedFirstBadge &&
        featureVM.annotations.map(\.text) == ["1", "2"] &&
        featureVM.nextCounterLabel == "3",
        "Deleting counter badge #1 resequences remaining badges to [1, 2] so the next counter is 3 without duplicate 2s"
    )
    featureVM.undo()
    t.check(
        featureVM.annotations.map(\.id) == [badge1.id, badge2.id, badge3.id] &&
        featureVM.annotations.map(\.text) == ["1", "2", "3"] &&
        featureVM.nextCounterLabel == "4",
        "Undoing a counter deletion restores the deleted badge in place with original [1, 2, 3] sequence"
    )
    featureVM.annotations.removeAll()

    // Verify ScreenCaptureOverlayController multi-display lifecycle, focus handoff, cursor-screen failure guard, and cross-display drag cancel
    let multiController = ScreenCaptureOverlayController()
    var missingInitialAlertCount = 0
    multiController.presentPermissionAlert = { missingInitialAlertCount += 1 }
    var missingInitialResult: CaptureSelectionResult? = nil
    var missingInitialCompleted = false
    multiController.installCaptureOverlays(
        descriptors: [
            (screenFrame: NSRect(x: 400, y: 0, width: 400, height: 300), cgImage: cgScreen, candidateWindowRects: [], isInitialCursorScreen: false)
        ],
        hideSystemCursor: false,
        completion: { res in
            missingInitialResult = res
            missingInitialCompleted = true
        }
    )
    t.check(
        missingInitialCompleted && missingInitialResult == nil &&
        multiController.overlayWindows.isEmpty && missingInitialAlertCount == 1,
        "If capture fails on the cursor's display, controller aborts cleanly instead of silently activating another display"
    )

    var multiCaptureResult: CaptureSelectionResult? = nil
    var multiCaptureFinishedCount = 0
    multiController.installCaptureOverlays(
        descriptors: [
            (screenFrame: NSRect(x: 0, y: 0, width: 400, height: 300), cgImage: cgScreen, candidateWindowRects: [], isInitialCursorScreen: true),
            (screenFrame: NSRect(x: 400, y: 0, width: 400, height: 300), cgImage: cgScreen, candidateWindowRects: [], isInitialCursorScreen: false)
        ],
        hideSystemCursor: false,
        completion: { res in
            multiCaptureResult = res
            multiCaptureFinishedCount += 1
        }
    )
    if multiController.overlayWindows.count == 2,
       let panelA = multiController.overlayWindows.first,
       let panelB = multiController.overlayWindows.last,
       let viewA = panelA.contentView as? PixPinSelectionView,
       let viewB = panelB.contentView as? PixPinSelectionView {
        t.check(
            viewA.isCursorInsideScreen && !viewB.isCursorInsideScreen && panelA.firstResponder === viewA,
            "Initial cursor display starts active and owns first responder"
        )
        // Start a drag on Screen A and release 1pt outside Screen A's bounds (onto Screen B) -> cancels drag without finishing clipped capture
        if let downA = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 350, y: 150), modifierFlags: [],
            timestamp: 0, windowNumber: panelA.windowNumber, context: nil, eventNumber: 31, clickCount: 1, pressure: 1.0
        ),
           let dragOutA = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: 401, y: 150), modifierFlags: [],
            timestamp: 0, windowNumber: panelA.windowNumber, context: nil, eventNumber: 32, clickCount: 1, pressure: 1.0
           ),
           let upOutA = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 401, y: 150), modifierFlags: [],
            timestamp: 0, windowNumber: panelA.windowNumber, context: nil, eventNumber: 33, clickCount: 1, pressure: 1.0
           ) {
            viewA.mouseDown(with: downA)
            viewA.mouseDragged(with: dragOutA)
            viewA.mouseUp(with: upOutA)
            t.check(
                multiCaptureFinishedCount == 0 && multiController.overlayWindows.count == 2,
                "Releasing a drag even 1pt outside its originating display cancels the cross-screen drag instead of capturing a clipped strip"
            )
            // Also verify cross-screen activation handoff clearing Screen A's drag before mouseUp does not dismiss capture overlays
            viewA.mouseDown(with: downA)
            multiController.activateOverlayView(viewB)
            viewA.mouseUp(with: upOutA)
            t.check(
                multiCaptureFinishedCount == 0 && multiController.overlayWindows.count == 2,
                "Cross-screen overlay activation before mouseUp cancels only the active drag and keeps all capture overlays open"
            )
        } else {
            t.check(false, "Constructed cross-display drag events for Screen A")
        }
        // Move cursor onto Screen B -> real controller handoff updates cursor flags and first responder, then Space captures Screen B
        if let moveOntoB = NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 80, y: 120), modifierFlags: [],
            timestamp: 0, windowNumber: panelB.windowNumber, context: nil, eventNumber: 34, clickCount: 0, pressure: 0
        ),
           let spaceB = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panelB.windowNumber,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
           ) {
            viewB.mouseMoved(with: moveOntoB)
            t.check(
                viewB.isCursorInsideScreen && !viewA.isCursorInsideScreen && panelB.firstResponder === viewB,
                "Moving cursor onto secondary screen transfers controller active state and first responder to secondary overlay"
            )
            viewB.keyDown(with: spaceB)
            t.check(
                multiCaptureFinishedCount == 1 &&
                multiCaptureResult?.selectedScreenRect == NSRect(x: 400, y: 0, width: 400, height: 300) &&
                multiController.overlayWindows.isEmpty,
                "Pressing Space after moving to secondary screen captures secondary screen and closes all overlay windows"
            )
            t.check(
                panelA.hidesOnDeactivate == false && panelB.hidesOnDeactivate == false,
                "CaptureOverlayPanel sets hidesOnDeactivate = false so overlays do not silently vanish on transient deactivation"
            )
        } else {
            t.check(false, "Constructed mouseMoved and Space keyEvent for Screen B")
        }
    } else {
        t.check(false, "ScreenCaptureOverlayController created two overlay panels for multi-display test")
        multiController.finish(with: nil)
    }

    // Verify cancelActiveCapture(reason:) tears down overlays and invokes completion(nil) so isCapturing can never stay wedged
    let cancelController = ScreenCaptureOverlayController()
    var cancelCallbackFired = false
    cancelController.installCaptureOverlays(
        descriptors: [(screenFrame: screenFrame, cgImage: cgScreen, candidateWindowRects: [], isInitialCursorScreen: true)],
        hideSystemCursor: false,
        completion: { res in
            cancelCallbackFired = (res == nil)
        }
    )
    cancelController.cancelActiveCapture(reason: "test recovery")
    t.check(
        cancelCallbackFired && cancelController.overlayWindows.isEmpty && !cancelController.hasActiveOverlays,
        "cancelActiveCapture tears down active overlays and fires completion(nil) to clear capture session state"
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

    // Verify ScrollingImageStitcher overlap detection, sticky header/footer tolerance, and ScrollingCaptureSessionController flow
    func makeScrolledDocumentFrame(scrollOffsetPx: Int, widthPx: Int = 200, heightPx: Int = 160) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var buf = [UInt8](repeating: 255, count: widthPx * heightPx * 4)
        for y in 0..<heightPx {
            for x in 0..<widthPx {
                let idx = (y * widthPx + x) * 4
                if y < 12 {
                    // Fixed sticky header (dark navy)
                    buf[idx] = 24; buf[idx + 1] = 32; buf[idx + 2] = 64; buf[idx + 3] = 255
                } else if y >= heightPx - 12 {
                    // Fixed sticky footer (dark slate)
                    buf[idx] = 40; buf[idx + 1] = 44; buf[idx + 2] = 52; buf[idx + 3] = 255
                } else {
                    // Deterministic scrolling document bands every 8px with unique color patterns
                    let docY = y + scrollOffsetPx
                    let band = ((docY / 8) % 251 + 251) % 251
                    let subRow = ((docY % 8) + 8) % 8
                    buf[idx] = UInt8((band * 53 + (x / 16) * 19) % 251)
                    buf[idx + 1] = UInt8((band * 97 + subRow * 13) % 251)
                    buf[idx + 2] = UInt8((band * 149 + (x / 20) * 29) % 251)
                    buf[idx + 3] = 255
                }
            }
        }
        guard let ctx = CGContext(
            data: &buf,
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bytesPerRow: widthPx * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }

    if let frame0 = makeScrolledDocumentFrame(scrollOffsetPx: 0),
       let frame1 = makeScrolledDocumentFrame(scrollOffsetPx: 48),
       let frame2 = makeScrolledDocumentFrame(scrollOffsetPx: 96) {
        var stitcher = ScrollingImageStitcher(initialFrame: frame0, scaleFactor: 2.0)
        let sameRes = stitcher.appendFrame(frame0)
        t.check(
            sameRes == .unchanged && stitcher.accumulatedCGImage.height == 160,
            "ScrollingImageStitcher detects zero-scroll frame as .unchanged without duplicating height"
        )
        let res1 = stitcher.appendFrame(frame1)
        t.check(
            res1 == .appended(addedPixels: 48, totalPixelHeight: 208) && stitcher.frameCount == 2,
            "ScrollingImageStitcher detects exact 48px downward scroll despite sticky header/footer and appends 48px (160 -> 208px)",
            detail: "res1=\(res1), h=\(stitcher.accumulatedCGImage.height)"
        )
        let res2 = stitcher.appendFrame(frame2)
        t.check(
            res2 == .appended(addedPixels: 48, totalPixelHeight: 256) && stitcher.frameCount == 3,
            "ScrollingImageStitcher stitches third scrolled frame seamlessly (208 -> 256px, 128pt @2x)",
            detail: "res2=\(res2), h=\(stitcher.accumulatedCGImage.height)"
        )
        // Verify repeatedly scrolling up and back down through already-captured content does NOT duplicate frames,
        // while scrolling UP past the current top prepends the newly revealed content above it!
        if let frameBackUp = makeScrolledDocumentFrame(scrollOffsetPx: 25),
           let frameBackDown = makeScrolledDocumentFrame(scrollOffsetPx: 71),
           let framePastTop = makeScrolledDocumentFrame(scrollOffsetPx: -36),
           let frameNewBottom = makeScrolledDocumentFrame(scrollOffsetPx: 144),
           let expectedFull340 = makeScrolledDocumentFrame(scrollOffsetPx: -36, heightPx: 340) {
            let upRes = stitcher.appendFrame(frameBackUp)
            let downReplayRes = stitcher.appendFrame(frameBackDown)
            let upToZeroRes = stitcher.appendFrame(frame0)
            t.check(
                upRes == .unchanged &&
                downReplayRes == .unchanged &&
                upToZeroRes == .unchanged &&
                stitcher.accumulatedCGImage.height == 256 &&
                stitcher.frameCount == 3,
                "ScrollingImageStitcher ignores repeated up/down scrolling over already-captured content (including unaligned offsets 25px and 71px) without duplicating height",
                detail: "up=\(upRes), downReplay=\(downReplayRes), zero=\(upToZeroRes), h=\(stitcher.accumulatedCGImage.height), frames=\(stitcher.frameCount)"
            )
            let pastTopRes = stitcher.appendFrame(framePastTop)
            let repeatPastTopRes = stitcher.appendFrame(framePastTop)
            let backToZeroAfterPrepend = stitcher.appendFrame(frame0)
            t.check(
                pastTopRes == .appended(addedPixels: 36, totalPixelHeight: 292) &&
                repeatPastTopRes == .unchanged &&
                backToZeroAfterPrepend == .unchanged &&
                stitcher.accumulatedCGImage.height == 292 &&
                stitcher.frameCount == 4,
                "ScrollingImageStitcher prepends newly revealed content when scrolling UP past current top without duplicating on repeat (256 -> 292px)",
                detail: "pastTop=\(pastTopRes), repeat=\(repeatPastTopRes), backToZero=\(backToZeroAfterPrepend), h=\(stitcher.accumulatedCGImage.height)"
            )
            let resumeRes = stitcher.appendFrame(frameNewBottom)
            let actualSigs = ScrollingImageStitcher.extractRowSignatures(from: stitcher.accumulatedCGImage)
            let expectedSigs = ScrollingImageStitcher.extractRowSignatures(from: expectedFull340)
            let seamMismatchCount = zip(actualSigs, expectedSigs).filter { $0.0.samples != $0.1.samples }.count
            t.check(
                resumeRes == .appended(addedPixels: 48, totalPixelHeight: 340) &&
                stitcher.frameCount == 5 &&
                actualSigs.count == 340 &&
                seamMismatchCount == 0,
                "ScrollingImageStitcher resumes downward stitching cleanly after upward prepend with zero seam row mismatches (292 -> 340px)",
                detail: "resumeRes=\(resumeRes), h=\(stitcher.accumulatedCGImage.height), mismatches=\(seamMismatchCount)"
            )

            // Verify capped upward prepend near maxTotalPixelHeight preserves the full top sticky header (0..<12)
            // when a sticky header is present, and preserves contiguous document rows when no sticky header is present
            var cappedStitcher = ScrollingImageStitcher(initialFrame: frame0, scaleFactor: 2.0, maxTotalPixelHeight: 320)
            _ = cappedStitcher.appendFrame(frame1)
            _ = cappedStitcher.appendFrame(frame2)
            if let framePastTop90 = makeScrolledDocumentFrame(scrollOffsetPx: -90) {
                let capRes = cappedStitcher.appendFrame(framePastTop90)
                let capTopSigs = ScrollingImageStitcher.extractRowSignatures(from: cappedStitcher.accumulatedCGImage)
                let initialTopSigs = ScrollingImageStitcher.extractRowSignatures(from: frame0)
                let headerIntact = capTopSigs.count >= 12 &&
                    initialTopSigs.count >= 12 &&
                    (0..<12).allSatisfy { capTopSigs[$0].samples == initialTopSigs[$0].samples }
                t.check(
                    capRes == .appended(addedPixels: 64, totalPixelHeight: 320) && headerIntact,
                    "ScrollingImageStitcher preserves all 12 rows of top sticky header when upward prepend is truncated by maxTotalPixelHeight",
                    detail: "capRes=\(capRes), headerIntact=\(headerIntact)"
                )
            }
        } else {
            t.check(false, "Synthetic bidirectional scroll frames must be created")
        }

        // Verify periodic/repeating content ambiguity (downward, upward, and cross-direction) is rejected rather than silently mis-stitching,
        // and verify mostly-changed interior content (even when all 5 anchor rows stay unchanged) is not falsely classified as .unchanged
        func makePeriodicFrame(scrollOffsetPx: Int, widthPx: Int = 200, heightPx: Int = 160) -> CGImage? {
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            var buf = [UInt8](repeating: 255, count: widthPx * heightPx * 4)
            for y in 0..<heightPx {
                for x in 0..<widthPx {
                    let idx = (y * widthPx + x) * 4
                    if y < 12 || y >= heightPx - 12 {
                        buf[idx] = 30; buf[idx + 1] = 40; buf[idx + 2] = 50; buf[idx + 3] = 255
                    } else {
                        let absY = y + scrollOffsetPx
                        let docY = (absY >= -20 && absY < 180) ? ((absY % 16) + 16) % 16 : absY
                        let band = ((docY / 4) % 251 + 251) % 251
                        buf[idx] = UInt8((band * 73 + (x / 16) * 19) % 251)
                        buf[idx + 1] = UInt8((band * 109 + ((docY % 4) + 4) % 4 * 31) % 251)
                        buf[idx + 2] = UInt8((band * 163) % 251)
                        buf[idx + 3] = 255
                    }
                }
            }
            guard let ctx = CGContext(
                data: &buf, width: widthPx, height: heightPx, bitsPerComponent: 8, bytesPerRow: widthPx * 4,
                space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
        if let p0 = makePeriodicFrame(scrollOffsetPx: 0),
           let p48 = makePeriodicFrame(scrollOffsetPx: 48),
           let pUp48 = makePeriodicFrame(scrollOffsetPx: -48) {
            var periodicStitcher = ScrollingImageStitcher(initialFrame: p0, scaleFactor: 2.0)
            let pDownRes = periodicStitcher.appendFrame(p48)
            let pUpRes = periodicStitcher.appendFrame(pUp48)
            t.check(
                pDownRes == .skippedNoOverlap &&
                pUpRes == .skippedNoOverlap &&
                periodicStitcher.accumulatedCGImage.height == 160,
                "ScrollingImageStitcher rejects ambiguous periodic overlap in both downward and upward directions instead of silently mis-stitching",
                detail: "pDownRes=\(pDownRes), pUpRes=\(pUpRes), h=\(periodicStitcher.accumulatedCGImage.height)"
            )
        }

        // Verify a frame where all 5 anchor rows and sparse probe rows stay white but non-probe interior rows change
        // (and where even rows change at shift 0) reaches full-row verification and is NOT falsely treated as .unchanged
        func makeMostlyChangedInteriorFrame(changed: Bool, widthPx: Int = 200, heightPx: Int = 256) -> CGImage? {
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            var buf = [UInt8](repeating: 255, count: widthPx * heightPx * 4)
            let topMargin = 20
            let interiorLen = 216
            let anchorSet: Set<Int> = [0, interiorLen / 4, interiorLen / 2, (interiorLen * 3) / 4, interiorLen - 1]
            let probeStep = max(1, interiorLen / 24) // 9
            for y in 0..<heightPx {
                for x in 0..<widthPx {
                    let idx = (y * widthPx + x) * 4
                    let dy = y - topMargin
                    let isUnchangedSampleRow = dy < 0 || dy >= interiorLen || anchorSet.contains(dy) || (dy % probeStep == 0)
                    let val: UInt8 = (changed && !isUnchangedSampleRow) ? 30 : 255
                    buf[idx] = val; buf[idx + 1] = val; buf[idx + 2] = val; buf[idx + 3] = 255
                }
            }
            guard let ctx = CGContext(
                data: &buf, width: widthPx, height: heightPx, bitsPerComponent: 8, bytesPerRow: widthPx * 4,
                space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
        if let fBase = makeMostlyChangedInteriorFrame(changed: false),
           let fChanged = makeMostlyChangedInteriorFrame(changed: true) {
            var sChanged = ScrollingImageStitcher(initialFrame: fBase, scaleFactor: 1.0)
            let changedRes = sChanged.appendFrame(fChanged)
            t.check(
                changedRes != .unchanged,
                "ScrollingImageStitcher full-row verification prevents false .unchanged on mostly-changed periodic interior",
                detail: "changedRes=\(changedRes)"
            )
        }

        // Helper to build deterministic grayscale row images for targeted regression checks
        func makeGrayRowImage(_ rows: [Int], widthPx: Int = 64) -> CGImage? {
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            var buf = [UInt8](repeating: 255, count: rows.count * widthPx * 4)
            for (y, value) in rows.enumerated() {
                let v = UInt8(clamping: value)
                for x in 0..<widthPx {
                    let idx = (y * widthPx + x) * 4
                    buf[idx] = v; buf[idx + 1] = v; buf[idx + 2] = v; buf[idx + 3] = 255
                }
            }
            guard let ctx = CGContext(
                data: &buf, width: widthPx, height: rows.count, bitsPerComponent: 8, bytesPerRow: widthPx * 4,
                space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
        func hashDocRow(_ y: Int) -> Int {
            var v = UInt64(bitPattern: Int64(y)) &+ 0x9E3779B97F4A7C15
            v = (v ^ (v >> 30)) &* 0xBF58476D1CE4E5B9
            v = (v ^ (v >> 27)) &* 0x94D049BB133111EB
            return 48 + Int((v ^ (v >> 31)) & 127)
        }

        // Regression 1: Cross-direction ambiguity (upward scroll with repeated block in newly revealed region, even when an anchor row has a +40 spike or +5 baseline shift) fails closed,
        // and calling `.unknown` followed by `.upward` on the same stitcher returns the complete best shift (not a truncated first candidate)
        if let crossInit = makeGrayRowImage((0..<160).map { $0 < 13 ? 16 : ($0 >= 147 ? 32 : hashDocRow($0)) }),
           let crossNext = makeGrayRowImage((0..<160).map { y in
               if y < 13 { return 16 }
               if y >= 147 { return 32 }
               if y < 37 { return hashDocRow(y + 110) }
               return hashDocRow(y - 110) + (y >= 123 ? 5 : 0) + (y == 123 ? 40 : 0)
           }) {
            var crossStitcher = ScrollingImageStitcher(initialFrame: crossInit, scaleFactor: 1.0)
            let crossRes = crossStitcher.appendFrame(crossNext)
            var staleDownStitcher = ScrollingImageStitcher(initialFrame: crossInit, scaleFactor: 1.0)
            let staleDownRes = staleDownStitcher.appendFrame(crossNext, directionHint: .downward)

            let cacheInitRows = (0..<256).map { y -> Int in
                if y < 20 || y >= 236 { return 24 }
                if (20..<36).contains(y) { return 50 + (y - 20) * 6 + ((y * 7) % 5) }
                if (220..<236).contains(y) { return 48 + (y - 220) * 7 + ((y * 11) % 5) }
                return 32 + ((y * 73 + 19) % 180)
            }
            var cacheNextRows = [Int](repeating: 24, count: 256)
            for y in 20..<236 { cacheNextRows[y] = 40 + ((y * 97 + 41) % 170) }
            // Put two valid downward candidates (shifts 180 and 200 both with 0.0 MAD) so `downEval.isAmbiguous == true` (`!downUnambiguous`),
            // while upward has `s=180` (`score ~= 1.33`) and `s=200` (`score == 0.0`) so `upEval` is unambiguous (`bestShift == 200`).
            for i in 0..<16 { cacheNextRows[20 + i] = cacheInitRows[220 + i] }
            for i in 0..<36 { cacheNextRows[20 + i] = cacheInitRows[200 + i] }
            for i in 0..<16 { cacheNextRows[20 + i] = cacheInitRows[220 + i] }
            for i in 0..<16 { cacheInitRows[200 + i] == cacheInitRows[220 + i] ? () : () }
            var cacheInitRowsMod = cacheInitRows
            for i in 0..<16 { cacheInitRowsMod[200 + i] = cacheInitRowsMod[220 + i] }
            for i in 16..<36 { cacheNextRows[20 + i] = cacheInitRowsMod[200 + i] }
            for i in 0..<36 { cacheNextRows[200 + i] = cacheInitRowsMod[20 + i] + (i % 3 == 0 ? 4 : 0) }
            for i in 0..<16 { cacheNextRows[220 + i] = cacheInitRowsMod[20 + i] }
            var cacheOrderMatches = false
            if let cacheInitImg = makeGrayRowImage(cacheInitRowsMod),
               let cacheNextImg = makeGrayRowImage(cacheNextRows) {
                var freshUp = ScrollingImageStitcher(initialFrame: cacheInitImg, scaleFactor: 2.0)
                let freshUpRes = freshUp.appendFrame(cacheNextImg, directionHint: .upward)
                var cachedUp = ScrollingImageStitcher(initialFrame: cacheInitImg, scaleFactor: 2.0)
                _ = cachedUp.appendFrame(cacheNextImg, directionHint: .unknown)
                let cachedUpRes = cachedUp.appendFrame(cacheNextImg, directionHint: .upward)
                cacheOrderMatches = (freshUpRes == .appended(addedPixels: 200, totalPixelHeight: 456)) && (cachedUpRes == freshUpRes)
            }

            t.check(
                crossRes == .skippedNoOverlap &&
                staleDownRes == .skippedNoOverlap &&
                crossStitcher.accumulatedCGImage.height == 160 &&
                staleDownStitcher.accumulatedCGImage.height == 160 &&
                cacheOrderMatches,
                "ScrollingImageStitcher rejects cross-direction ambiguity (both unhinted and under a stale opposite directionHint) and caches complete sorted directional evaluations across .unknown -> .upward retries",
                detail: "crossRes=\(crossRes), staleDownRes=\(staleDownRes), cacheOrderMatches=\(cacheOrderMatches)"
            )
        } else {
            t.check(false, "Created cross-direction ambiguity regression frames")
        }

        // Regression 1b: Periodic overlap with a 1-row (+7) anomaly still fails closed instead of bypassing periodic self-match
        do {
            var perA = (0..<160).map { hashDocRow($0) }
            var perB = (0..<160).map { hashDocRow($0 + 999) }
            for y in 13..<32 {
                perB[y] = [40, 90, 140, 190][(y - 13) % 4]
            }
            perB[13] += 7
            for y in 13..<32 {
                perA[y + 115] = perB[y]
            }
            if let perImgA = makeGrayRowImage(perA),
               let perImgB = makeGrayRowImage(perB) {
                var perStitcher = ScrollingImageStitcher(initialFrame: perImgA, scaleFactor: 1.0)
                let perRes = perStitcher.appendFrame(perImgB)
                t.check(
                    perRes == .skippedNoOverlap && perStitcher.accumulatedCGImage.height == 160,
                    "ScrollingImageStitcher rejects periodic 4px-period overlap even when one row has a +7 anomaly",
                    detail: "perRes=\(perRes)"
                )
            } else {
                t.check(false, "Created noisy periodic overlap regression frames")
            }
        }

        // Regression 1c: Single changed anchor row (+40 on row 13) still stitches valid 48px scroll, and cache only short-circuits exact signature matches
        do {
            let baseRows0 = (0..<160).map { $0 < 13 ? 16 : ($0 >= 147 ? 32 : hashDocRow($0)) }
            var spikeRows48 = (0..<160).map { $0 < 13 ? 16 : ($0 >= 147 ? 32 : hashDocRow($0 + 48)) }
            spikeRows48[13] += 40
            var failedRows = (0..<160).map { $0 < 13 ? 16 : ($0 >= 147 ? 32 : hashDocRow($0 + 48)) }
            failedRows[13] += 40
            if let baseImg0 = makeGrayRowImage(baseRows0),
               let spikeImg48 = makeGrayRowImage(spikeRows48) {
                var spikeStitcher = ScrollingImageStitcher(initialFrame: baseImg0, scaleFactor: 1.0)
                let spikeRes = spikeStitcher.appendFrame(spikeImg48)
                t.check(
                    spikeRes == .appended(addedPixels: 48, totalPixelHeight: 208),
                    "ScrollingImageStitcher accepts valid 48px scroll even when the first overlap row has a +40 transient change",
                    detail: "spikeRes=\(spikeRes)"
                )
            } else {
                t.check(false, "Created single-anchor-spike regression frames")
            }
        }

        // Regression 2: Capped upward prepend without sticky header (including when moved white gap changes 240 -> 230) AND with 12-row sticky header inside 13px topMargin
        func docRowWithCoincidentalWhiteGap(_ y: Int) -> Int {
            if (y >= 0 && y < 13) || (y >= -90 && y < -77) { return 240 }
            return hashDocRow(y)
        }
        var gapUp90Rows = (0..<160).map { docRowWithCoincidentalWhiteGap($0 - 90) }
        for y in 90..<103 { gapUp90Rows[y] = 230 }
        if let gap0 = makeGrayRowImage((0..<160).map { docRowWithCoincidentalWhiteGap($0) }),
           let gap1 = makeGrayRowImage((0..<160).map { docRowWithCoincidentalWhiteGap($0 + 48) }),
           let gap2 = makeGrayRowImage((0..<160).map { docRowWithCoincidentalWhiteGap($0 + 96) }),
           let gapUp90 = makeGrayRowImage(gapUp90Rows) {
            var gapStitcher = ScrollingImageStitcher(initialFrame: gap0, scaleFactor: 2.0, maxTotalPixelHeight: 320)
            _ = gapStitcher.appendFrame(gap1)
            _ = gapStitcher.appendFrame(gap2)
            let beforeGapRows = ScrollingImageStitcher.extractRowSignatures(from: gapStitcher.accumulatedCGImage)
            let gapRes = gapStitcher.appendFrame(gapUp90)
            let actualGapRows = ScrollingImageStitcher.extractRowSignatures(from: gapStitcher.accumulatedCGImage)
            let up90Sigs = ScrollingImageStitcher.extractRowSignatures(from: gapUp90)
            let expectedContiguousSigs = Array(up90Sigs[26..<103]) + Array(beforeGapRows[13..<256])
            let gapMismatches = zip(actualGapRows, expectedContiguousSigs).filter { $0.0.samples != $0.1.samples }.count
            t.check(
                gapRes == .appended(addedPixels: 64, totalPixelHeight: 320) && gapMismatches == 0,
                "ScrollingImageStitcher capped upward prepend keeps contiguous document rows even when top white gaps change brightness (240 -> 230)",
                detail: "gapRes=\(gapRes), mismatches=\(gapMismatches)"
            )
        } else {
            t.check(false, "Created coincidental white-gap capped prepend frames")
        }

        // Regression 2b: 12-row sticky header inside a 13px topMargin where row 12 is scrolling document content (200 -> 40) preserves all 12 header rows
        func docRowJumpAt12(_ y: Int) -> Int {
            if y == 12 { return 200 }
            if y == -78 { return 40 }
            return hashDocRow(y)
        }
        func makeHeader12Frame(_ off: Int) -> CGImage? {
            makeGrayRowImage((0..<160).map { $0 < 12 ? 16 : ($0 >= 148 ? 32 : docRowJumpAt12($0 + off)) })
        }
        if let h12_0 = makeHeader12Frame(0),
           let h12_1 = makeHeader12Frame(48),
           let h12_2 = makeHeader12Frame(96),
           let h12_up90 = makeHeader12Frame(-90) {
            var h12Stitcher = ScrollingImageStitcher(initialFrame: h12_0, scaleFactor: 2.0, maxTotalPixelHeight: 320)
            _ = h12Stitcher.appendFrame(h12_1)
            _ = h12Stitcher.appendFrame(h12_2)
            let h12Res = h12Stitcher.appendFrame(h12_up90)
            let h12Out = ScrollingImageStitcher.extractRowSignatures(from: h12Stitcher.accumulatedCGImage)
            let first12Intact = h12Out.count == 320 && h12Out.prefix(12).allSatisfy { $0.samples[0] == 16 }
            t.check(
                h12Res == .appended(addedPixels: 64, totalPixelHeight: 320) && first12Intact,
                "ScrollingImageStitcher capped upward prepend preserves 12-row stationary sticky header even when 13th topMargin row is scrolling content",
                detail: "h12Res=\(h12Res), first12Intact=\(first12Intact)"
            )
        } else {
            t.check(false, "Created 12-row sticky header capped prepend frames")
        }

        // Regression 3: Replay deduplication finds genuine match after 40 non-overlapping sparse-probe decoys
        do {
            let topM = 13, botM = 13, frameH3 = 160, interiorLen3 = 134
            let step3 = 5
            let anchors3: Set<Int> = [0, 33, 67, 100, 133]
            var accRows3 = (0..<6600).map { hashDocRow($0) }
            let targetRows3 = (0..<frameH3).map { y -> Int in
                if y < topM || y >= frameH3 - botM { return 30 }
                return hashDocRow(y + 777)
            }
            for k in 0..<40 {
                let base = 40 + k * 150 // Non-overlapping 134-row windows (stride 150 >= 134)
                for dy in 0..<interiorLen3 {
                    accRows3[base + dy] = targetRows3[topM + dy] + ((anchors3.contains(dy) || dy % step3 == 0) ? 0 : 8)
                }
            }
            let trueBase = 6400
            for dy in 0..<interiorLen3 {
                accRows3[trueBase + dy] = targetRows3[topM + dy] + (dy == step3 ? 1 : 0)
            }
            if let accImg3 = makeGrayRowImage(accRows3),
               let targetImg3 = makeGrayRowImage(targetRows3) {
                var decoyStitcher = ScrollingImageStitcher(initialFrame: accImg3, scaleFactor: 1.0)
                let decoyRes = decoyStitcher.appendFrame(targetImg3)

                // Also verify balanced-RGB replay where the 3 primary probe rows (rows 13, 85, 146) are inverted
                // (`rowL1Diff == 24,384` per probe row, while the other 131 rows are exact, so full MAD = 5.71 <= 6.0)
                var balState: UInt64 = 0xA5A5_5A5A_1234_5678
                func makeBalancedReplayImage(_ rows: [[UInt8]]) -> CGImage? {
                    let w = 64, h = rows.count
                    var buf = [UInt8](repeating: 128, count: w * h * 4)
                    for y in 0..<h {
                        for x in 0..<w {
                            let idx = (y * w + x) * 4
                            let cBase = min(31, max(0, (x - 6) * 31 / 52)) * 3
                            buf[idx] = rows[y][cBase]
                            buf[idx + 1] = rows[y][cBase + 1]
                            buf[idx + 2] = rows[y][cBase + 2]
                            buf[idx + 3] = 255
                        }
                    }
                    let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                    return buf.withUnsafeMutableBytes { raw in
                        CGContext(
                            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        )?.makeImage()
                    }
                }
                let balDocRows: [[UInt8]] = (0..<1000).map { _ in
                    var r = [UInt8](repeating: 128, count: 96)
                    for p in 0..<16 {
                        balState = balState &* 6364136223846793005 &+ 1442695040888963407
                        let bits = balState >> 32
                        for c in 0..<3 {
                            let v: UInt8 = ((bits >> c) & 1) == 0 ? 1 : 255
                            r[(p * 2) * 3 + c] = v
                            r[(p * 2 + 1) * 3 + c] = UInt8(256 - Int(v))
                        }
                    }
                    return r
                }
                var balViewport = Array(balDocRows[300..<460])
                for dy in [13, 85, 146] {
                    balViewport[dy] = balViewport[dy].map { UInt8(256 - Int($0)) }
                }
                var balReplayMatched = false
                if let balAccImg = makeBalancedReplayImage(balDocRows),
                   let balVpImg = makeBalancedReplayImage(balViewport) {
                    var balStitcher = ScrollingImageStitcher(initialFrame: balAccImg, scaleFactor: 2.0)
                    balReplayMatched = (balStitcher.appendFrame(balVpImg) == .unchanged)
                }

                t.check(
                    decoyRes == .unchanged && balReplayMatched,
                    "ScrollingImageStitcher replay deduplication finds genuine match past 40 non-overlapping sparse-probe decoys and when 3 balanced-RGB probe rows have localized transient artifacts (MAD 5.71 <= 6.0)",
                    detail: "decoyRes=\(decoyRes), balReplayMatched=\(balReplayMatched)"
                )
            } else {
                t.check(false, "Created 40 non-overlapping decoy replay frames")
            }
        }

        // Regression 4: Exact lower-bound directional matching accepts valid 60px scroll under both 2-row and 4-row periodic scanline noise (full MAD = 11.0 <= 11.5)
        if let parityInit = makeGrayRowImage((0..<256).map { $0 < 20 ? 16 : ($0 >= 236 ? 32 : hashDocRow($0)) }),
           let parityNext = makeGrayRowImage((0..<256).map { y in
               if y < 20 { return 16 }
               if y >= 236 { return 32 }
               return hashDocRow(y + 60) + ((y % 4 == 0 || y % 4 == 1) ? 22 : 0)
           }) {
            var parityStitcher = ScrollingImageStitcher(initialFrame: parityInit, scaleFactor: 2.0)
            let parityRes = parityStitcher.appendFrame(parityNext)
            t.check(
                parityRes == .appended(addedPixels: 60, totalPixelHeight: 316),
                "ScrollingImageStitcher exact lower-bound matching accepts valid 60px scroll despite 4-row pair scanline noise",
                detail: "parityRes=\(parityRes)"
            )
        } else {
            t.check(false, "Created 4-row pair noise regression frames")
        }

        // Regression 5: Real-world sparse text/code page with uniform background & 44px line-height spacing
        // stitches cleanly across slow and medium scrolls (both with `.unknown` and `.downward` directionHint)
        // instead of falsely triggering `.skippedNoOverlap` due to weak opposite-direction line-grid alignments
        func makeSparseTextPageFrame(scrollOffsetPx: Int, widthPx: Int = 400, heightPx: Int = 500) -> CGImage? {
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            var buf = [UInt8](repeating: 255, count: widthPx * heightPx * 4)
            for y in 0..<heightPx {
                let docY = y + scrollOffsetPx
                let lineIdx = docY / 44
                let rowInLine = ((docY % 44) + 44) % 44
                let isTextRow = (12..<26).contains(rowInLine)
                let lineSeed = ((lineIdx * 131 + 17) % 97 + 97) % 97
                let textEndX = 50 + (lineSeed * (widthPx - 100)) / 97
                for x in 0..<widthPx {
                    let idx = (y * widthPx + x) * 4
                    if isTextRow && x >= 50 && x < textEndX {
                        let glyph = ((x * 7 + lineIdx * 29 + rowInLine * 13) % 19)
                        let val: UInt8 = glyph < 7 ? 38 : (glyph < 11 ? 140 : 252)
                        buf[idx] = val; buf[idx + 1] = val; buf[idx + 2] = val; buf[idx + 3] = 255
                    } else {
                        buf[idx] = 250; buf[idx + 1] = 250; buf[idx + 2] = 252; buf[idx + 3] = 255
                    }
                }
            }
            guard let ctx = CGContext(
                data: &buf, width: widthPx, height: heightPx, bitsPerComponent: 8, bytesPerRow: widthPx * 4,
                space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
        if let text0 = makeSparseTextPageFrame(scrollOffsetPx: 0),
           let textSlow = makeSparseTextPageFrame(scrollOffsetPx: 20),
           let textLine = makeSparseTextPageFrame(scrollOffsetPx: 64),
           let textMed = makeSparseTextPageFrame(scrollOffsetPx: 140) {
            var textStitcher = ScrollingImageStitcher(initialFrame: text0, scaleFactor: 2.0)
            let rSlow = textStitcher.appendFrame(textSlow, directionHint: .downward)
            let rLine = textStitcher.appendFrame(textLine, directionHint: .downward)
            let rMed = textStitcher.appendFrame(textMed, directionHint: .downward)

            // Also verify session controller when the first sample after a scrollWheel event still captures the pre-paint
            // unchanged frame (`text0`) before the target window paints `textSlow` on the next timer/trailing sample!
            let selRect = NSRect(x: 100, y: 100, width: 400, height: 500)
            let sel = CaptureSelectionResult(
                fullScreenCGImage: text0,
                fullScreenFrame: selRect,
                scaleFactor: 1.0,
                selectedScreenRect: selRect,
                croppedImage: NSImage(cgImage: text0, size: selRect.size)
            )
            var liveSparseFrame = text0
            let sparseSession = ScrollingCaptureSessionController(
                initialSelection: sel,
                initialCropCGImage: text0,
                captureRegionProvider: { _ in liveSparseFrame }
            )
            let ts0 = CFAbsoluteTimeGetCurrent()
            sparseSession.recordScrollEvent(scrollingDeltaY: -12, screenLocation: NSPoint(x: 150, y: 150), timestamp: ts0)
            // Unrelated wheel event 10pt outside selectedScreenRect's right edge (`x = 510 > 500`) must be ignored
            sparseSession.recordScrollEvent(scrollingDeltaY: 50, screenLocation: NSPoint(x: 510, y: 150), timestamp: ts0 + 0.01)
            // First sample runs before app finishes painting (`liveSparseFrame == text0` -> `.unchanged`)
            sparseSession.sampleNextFrameIfChanged()
            let prePaintWarning = sparseSession.statusWarning
            // Next sample hits an intermediate transient tearing frame (`skippedNoOverlap`) before the window finishes painting `textSlow`
            if let transientTear = makeSparseTextPageFrame(scrollOffsetPx: 9999) {
                liveSparseFrame = transientTear
                sparseSession.sampleNextFrameIfChanged()
            }
            // Third sample sees painted 20px scroll without a new wheel event; preserved `.downward` hint must stitch cleanly and clear the transient warning!
            liveSparseFrame = textSlow
            sparseSession.sampleNextFrameIfChanged()

            t.check(
                rSlow == .appended(addedPixels: 20, totalPixelHeight: 520) &&
                rLine == .appended(addedPixels: 44, totalPixelHeight: 564) &&
                rMed == .appended(addedPixels: 76, totalPixelHeight: 640) &&
                prePaintWarning == nil &&
                sparseSession.pointHeight == 520 &&
                sparseSession.statusWarning == nil,
                "ScrollingImageStitcher & SessionController stitch sparse text/code pages smoothly across slow (20px), single-line (44px), and medium (76px) scrolls even when preceded by pre-paint unchanged or transient skippedNoOverlap samples",
                detail: "rSlow=\(rSlow), rLine=\(rLine), rMed=\(rMed), sessionH=\(sparseSession.pointHeight), sessionWarn=\(String(describing: sparseSession.statusWarning))"
            )
        } else {
            t.check(false, "Created sparse text page regression frames")
        }

        // Regression 6: Net scroll displacement between samples (downward -12 followed by slight +2 bounce),
        // out-of-region scroll event filtering, and scrollbar/PageUp fallback after a wheel scroll
        if let f0 = makeScrolledDocumentFrame(scrollOffsetPx: 0),
           let fDown48 = makeScrolledDocumentFrame(scrollOffsetPx: 48),
           let fUp36 = makeScrolledDocumentFrame(scrollOffsetPx: -36) {
            let selRect = NSRect(x: 100, y: 100, width: 200, height: 160)
            let sel = CaptureSelectionResult(
                fullScreenCGImage: f0,
                fullScreenFrame: selRect,
                scaleFactor: 1.0,
                selectedScreenRect: selRect,
                croppedImage: NSImage(cgImage: f0, size: selRect.size)
            )
            var currentFrame = fDown48
            let session = ScrollingCaptureSessionController(
                initialSelection: sel,
                initialCropCGImage: f0,
                captureRegionProvider: { _ in currentFrame }
            )
            let nowTs = CFAbsoluteTimeGetCurrent()
            // Scroll down (-12) then slight upward bounce (+2) inside selectedScreenRect -> net delta is -10 (.downward)
            session.recordScrollEvent(scrollingDeltaY: -12, screenLocation: NSPoint(x: 150, y: 150), timestamp: nowTs)
            session.recordScrollEvent(scrollingDeltaY: 2, screenLocation: NSPoint(x: 150, y: 150), timestamp: nowTs + 0.01)
            // Unrelated window scroll far outside selectedScreenRect (at 900, 900) must be ignored
            session.recordScrollEvent(scrollingDeltaY: 50, screenLocation: NSPoint(x: 900, y: 900), timestamp: nowTs + 0.02)
            session.sampleNextFrameIfChanged()
            let heightAfterNetDown = session.pointHeight
            let warningAfterNetDown = session.statusWarning

            // Next, user drags scrollbar or presses Page Up to -36 without a new upward wheel event (or even after a stale downward wheel event)
            currentFrame = fUp36
            session.recordScrollEvent(scrollingDeltaY: -8, screenLocation: NSPoint(x: 150, y: 150), timestamp: nowTs + 0.05)
            session.sampleNextFrameIfChanged()
            let heightAfterScrollbarUp = session.pointHeight
            let warningAfterScrollbarUp = session.statusWarning

            t.check(
                heightAfterNetDown == 208 &&
                warningAfterNetDown == nil &&
                heightAfterScrollbarUp == 244 &&
                warningAfterScrollbarUp == nil,
                "ScrollingCaptureSessionController uses net in-region scroll displacement, ignores out-of-region wheel events, and stitches scrollbar/PageUp upward movement cleanly",
                detail: "h1=\(heightAfterNetDown), w1=\(String(describing: warningAfterNetDown)), h2=\(heightAfterScrollbarUp), w2=\(String(describing: warningAfterScrollbarUp))"
            )
        }
        if let largeJumpFrame = makeScrolledDocumentFrame(scrollOffsetPx: 750, widthPx: 200, heightPx: 1000),
           let largeInitial = makeScrolledDocumentFrame(scrollOffsetPx: 0, widthPx: 200, heightPx: 1000) {
            var jumpStitcher = ScrollingImageStitcher(initialFrame: largeInitial, scaleFactor: 2.0)
            let jumpRes = jumpStitcher.appendFrame(largeJumpFrame)
            t.check(
                jumpRes == .appended(addedPixels: 750, totalPixelHeight: 1750),
                "ScrollingImageStitcher tolerates Page Down (~75% height) scroll jump",
                detail: "jumpRes=\(jumpRes)"
            )
            if let lostJumpFrame = makeScrolledDocumentFrame(scrollOffsetPx: 940, widthPx: 200, heightPx: 1000) {
                var lostStitcher = ScrollingImageStitcher(initialFrame: largeInitial, scaleFactor: 2.0)
                t.check(
                    lostStitcher.appendFrame(lostJumpFrame) == .skippedNoOverlap,
                    "ScrollingImageStitcher returns .skippedNoOverlap when scroll jump exceeds overlap window"
                )
            }
        }

        // Verify pressing 'L' in PixPinSelectionView over a hovered window starts ScrollingCaptureSessionController and finishes on Return
        let scrollController = ScreenCaptureOverlayController()
        var currentMockOffset = 48
        var currentMockCaptureCount = 0
        scrollController.liveRegionCaptureProvider = { _ in
            currentMockCaptureCount += 1
            let next = makeScrolledDocumentFrame(scrollOffsetPx: currentMockOffset)
            currentMockOffset += 48
            return next
        }
        var finalScrollResult: CaptureSelectionResult? = nil
        scrollController.installCaptureOverlays(
            descriptors: [(
                screenFrame: NSRect(x: 0, y: 0, width: 100, height: 80),
                cgImage: frame0,
                candidateWindowRects: [NSRect(x: 0, y: 0, width: 100, height: 80)],
                isInitialCursorScreen: true
            )],
            hideSystemCursor: false,
            completion: { res in
                finalScrollResult = res
            }
        )
        if let overlayView = scrollController.overlayWindows.first?.contentView as? PixPinSelectionView,
           let moveEv = NSEvent.mouseEvent(
               with: .mouseMoved, location: NSPoint(x: 50, y: 40), modifierFlags: [],
               timestamp: 0, windowNumber: 0, context: nil, eventNumber: 90, clickCount: 0, pressure: 0
           ),
           let lKey = NSEvent.keyEvent(
               with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
               context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37
           ) {
            overlayView.mouseMoved(with: moveEv)
             overlayView.keyDown(with: lKey)
             t.check(
                 scrollController.activeScrollingSession?.isActive == true &&
                 scrollController.overlayWindows.isEmpty &&
                 currentMockCaptureCount == 1,
                 "Pressing 'L' in capture overlay closes frozen overlay and seeds ScrollingCaptureSessionController from a fresh region capture"
             )
            scrollController.activeScrollingSession?.sampleNextFrameIfChanged()
            scrollController.activeScrollingSession?.finishCapture()
             t.check(
                 finalScrollResult?.isScrollingCapture == true &&
                 finalScrollResult?.croppedImage.size == NSSize(width: 100, height: 128) &&
                 currentMockCaptureCount == 3,
                 "Finishing ScrollingCaptureSessionController outputs stitched 2x Retina NSImage (100x128pt from three 100x80pt frames) and flushes final scrolled frame on finish",
                detail: "size=\(String(describing: finalScrollResult?.croppedImage.size))"
            )

            // Verify starting scrolling capture directly from a freshly captured Pin window (toolbar button / 'L' key on PinFloatingPanel)
            let daemonForScroll = PinDaemonApp()
            var pinScrollOffset = 240 // Simulate underlying page already scrolled before clicking L on the old Pin
            var pinScrollCaptureCount = 0
            daemonForScroll.captureController.liveRegionCaptureProvider = { _ in
                pinScrollCaptureCount += 1
                let next = makeScrolledDocumentFrame(scrollOffsetPx: pinScrollOffset)
                pinScrollOffset += 48
                return next
            }
            let initialPinCapture = CaptureSelectionResult(
                fullScreenCGImage: frame0,
                fullScreenFrame: NSRect(x: 0, y: 0, width: 100, height: 80),
                scaleFactor: 2.0,
                selectedScreenRect: NSRect(x: 0, y: 0, width: 100, height: 80),
                croppedImage: NSImage(cgImage: frame0, size: NSSize(width: 100, height: 80)),
                isScrollingCapture: false
            )
            daemonForScroll.createPinWindow(fromCapture: initialPinCapture)
            if let initialPanel = daemonForScroll.activePanels.values.first,
               let initialVM = initialPanel.viewModel {
                t.check(
                    initialVM.canAdjustCrop && initialVM.onStartScrollingCapture != nil,
                    "Freshly captured PinSessionViewModel exposes onStartScrollingCapture action while canAdjustCrop is true"
                )
                initialPanel.keyDown(with: lKey)
                t.check(
                    !initialPanel.isVisible &&
                    initialPanel.sharingType == NSWindow.SharingType.none &&
                    initialPanel.alphaValue == 0 &&
                    initialVM.toolbarPanel?.sharingType == NSWindow.SharingType.none &&
                    !initialVM.isClosed &&
                    daemonForScroll.captureController.activeScrollingSession?.isActive == true &&
                    pinScrollCaptureCount == 1,
                    "Pressing 'L' (or clicking scrolling capture toolbar button) on fresh Pin window sets sharingType=.none & alphaValue=0 before live capture so the 8 crop handle dots and blue border are excluded"
                )
                daemonForScroll.captureController.activeScrollingSession?.sampleNextFrameIfChanged()
                daemonForScroll.captureController.activeScrollingSession?.finishCapture()
                if let stitchedPanel = daemonForScroll.activePanels.values.first,
                   let stitchedVM = stitchedPanel.viewModel {
                    t.check(
                        initialVM.isClosed &&
                        stitchedVM.baseSize == NSSize(width: 100, height: 128) &&
                        pinScrollCaptureCount == 3,
                        "Finishing toolbar-initiated scrolling capture uses a fresh live initial frame, closes original Pin, and opens stitched Pin (128pt from three frames)",
                        detail: "baseSize=\(stitchedVM.baseSize)"
                    )
                    stitchedPanel.onClosePanel?()
                } else {
                    t.check(false, "Toolbar-initiated scrolling capture created final Pin window")
                }

                // Verify live capture provider failure sets warning and does not silently succeed with an unchanged frozen frame
                let failSession = ScrollingCaptureSessionController(
                    initialSelection: initialPinCapture,
                    initialCropCGImage: frame0,
                    captureRegionProvider: { _ in nil }
                )
                var failCompletedResult: CaptureSelectionResult? = initialPinCapture
                failSession.start { res in failCompletedResult = res }
                failSession.sampleNextFrameIfChanged()
                let sawCaptureFailureWarning = failSession.statusWarning == L10n.scrollingCaptureCaptureFailedWarning
                failSession.finishCapture()
                t.check(
                    sawCaptureFailureWarning && failCompletedResult == nil,
                    "ScrollingCaptureSessionController surfaces capture failure warning and returns nil on finish when no live frame succeeded"
                )

                // Verify cancelling scrolling capture started from an annotated Pin restores the original Pin + annotations
                let editedPinCapture = CaptureSelectionResult(
                    fullScreenCGImage: frame0,
                    fullScreenFrame: NSRect(x: 0, y: 0, width: 100, height: 80),
                    scaleFactor: 2.0,
                    selectedScreenRect: NSRect(x: 0, y: 0, width: 100, height: 80),
                    croppedImage: NSImage(cgImage: frame0, size: NSSize(width: 100, height: 80)),
                    isScrollingCapture: false
                )
                daemonForScroll.createPinWindow(fromCapture: editedPinCapture)
                if let editedPanel = daemonForScroll.activePanels.values.first,
                   let editedVM = editedPanel.viewModel {
                    editedVM.annotations.append(PinAnnotation(tool: .rect, color: .red, lineWidth: 3, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.7, y: 0.7)]))
                    editedVM.onStartScrollingCapture?()
                    let hiddenDuringSelect = !editedPanel.isVisible && editedPanel.sharingType == .none && !editedVM.isClosed
                    daemonForScroll.captureController.cancelActiveCapture(reason: "test cancel")
                    t.check(
                        hiddenDuringSelect && editedPanel.isVisible && editedPanel.sharingType == .readOnly && editedPanel.alphaValue == 1 && !editedVM.isClosed && editedVM.annotations.count == 1,
                        "Cancelling scrolling capture started from an annotated Pin restores the original Pin, its sharingType/alphaValue, and its annotations"
                    )
                    editedPanel.onClosePanel?()
                } else {
                    t.check(false, "Created annotated Pin window for cancel-restore test")
                }

                // Verify max-height stitched result (24,000pt @1x) scales below 0.08x to fit visible screen AND can zoom in and back out to fitted scale
                if let tallCG = makeScrolledDocumentFrame(scrollOffsetPx: 0, widthPx: 200, heightPx: 24000) {
                    let tallResult = CaptureSelectionResult(
                        fullScreenCGImage: tallCG,
                        fullScreenFrame: NSRect(x: 0, y: 0, width: 200, height: 24000),
                        scaleFactor: 1.0,
                        selectedScreenRect: NSRect(x: 0, y: 0, width: 200, height: 24000),
                        croppedImage: NSImage(cgImage: tallCG, size: NSSize(width: 200, height: 24000)),
                        isScrollingCapture: true
                    )
                    daemonForScroll.createPinWindow(fromCapture: tallResult)
                    if let tallPanel = daemonForScroll.activePanels.values.first,
                       let tallVM = tallPanel.viewModel {
                        let fittedScale = tallVM.scale
                        let visibleH = NSScreen.main?.visibleFrame.height ?? 1200
                        tallVM.updateZoom(delta: 0.15)
                        let zoomedInScale = tallVM.scale
                        tallVM.updateZoom(delta: -0.15)
                        let zoomedBackScale = tallVM.scale
                        t.check(
                            fittedScale < 0.08 && tallPanel.frame.height <= visibleH && zoomedInScale > fittedScale && abs(zoomedBackScale - fittedScale) < 0.0001,
                            "Max-height stitched Pin (24000pt) fits within visible screen below 0.08x and zooms back out to its fitted scale",
                            detail: "fitted=\(fittedScale), zoomedIn=\(zoomedInScale), zoomedBack=\(zoomedBackScale), panelH=\(tallPanel.frame.height), visibleH=\(visibleH)"
                        )
                        tallPanel.onClosePanel?()
                    } else {
                        t.check(false, "Created tall stitched Pin window")
                    }
                }

                // Verify wide scrolling capture (e.g. full visible width) scales down so panelFrame (including 32pt margin) fits within visible screen width
                if let wideCG = makeScrolledDocumentFrame(scrollOffsetPx: 0, widthPx: 4000, heightPx: 300) {
                    let wideResult = CaptureSelectionResult(
                        fullScreenCGImage: wideCG,
                        fullScreenFrame: NSRect(x: 0, y: 0, width: 4000, height: 300),
                        scaleFactor: 1.0,
                        selectedScreenRect: NSRect(x: 0, y: 0, width: 4000, height: 300),
                        croppedImage: NSImage(cgImage: wideCG, size: NSSize(width: 4000, height: 300)),
                        isScrollingCapture: true
                    )
                    daemonForScroll.createPinWindow(fromCapture: wideResult)
                    if let widePanel = daemonForScroll.activePanels.values.first {
                        let visibleW = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.width ?? 1440
                        t.check(
                            widePanel.frame.width <= visibleW + 1,
                            "Wide scrolling capture Pin scales initial width so panelFrame (including 32pt margins) fits within visible screen width",
                            detail: "panelW=\(widePanel.frame.width), visibleW=\(visibleW)"
                        )
                        widePanel.onClosePanel?()
                    } else {
                        t.check(false, "Created wide stitched Pin window")
                    }
                }
            } else {
                t.check(false, "Created initial Pin window for toolbar scrolling capture test")
            }
        } else {
            t.check(false, "Constructed mouseMoved and 'L' keyEvent for ScrollingCaptureSessionController test")
        }
        t.runAsync {
            await runAsyncScrollingCaptureTests(t, frame0: frame0, frame1: frame1, frame2: frame2)
        }
    } else {
        t.check(false, "Created synthetic scrolled document frames for ScrollingImageStitcher test")
    }

}
