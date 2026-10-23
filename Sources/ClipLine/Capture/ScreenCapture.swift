import AppKit
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

// MARK: - Zero-Flicker In-Memory Screen Capture & Region Selector

@MainActor
final class ScreenCaptureOverlayController {
    private(set) var overlayWindows: [NSPanel] = []
    private var completion: ((CaptureSelectionResult?) -> Void)?
    private var isCursorHidden = false
    var preflightAccess: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var requestAccess: () -> Bool = { CGRequestScreenCaptureAccess() }
    var presentPermissionAlert: () -> Void = { ScreenCaptureOverlayController.presentScreenRecordingPermissionAlertIfNeeded() }

    private static let cgDisplayCreateImageFn: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(handle, "CGDisplayCreateImage") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?).self)
    }()

    @discardableResult
    func ensureScreenCaptureAccess(showAlertOnDenial: Bool) -> Bool {
        if preflightAccess() {
            return true
        }
        if requestAccess() || preflightAccess() {
            return true
        }
        if showAlertOnDenial {
            presentPermissionAlert()
        }
        return false
    }

    private func captureDisplayImage(for screen: NSScreen, displayIndex: Int) -> CGImage? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        if let fn = Self.cgDisplayCreateImageFn, let unmanaged = fn(displayID) {
            return unmanaged.takeRetainedValue()
        }
        let tempSnap = ClipboardHelper.uniqueTempFileURL(prefix: "clipline_snap_full_\(displayIndex)").path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-D", "\(displayIndex)", tempSnap]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            try? FileManager.default.removeItem(atPath: tempSnap)
            return nil
        }
        guard proc.terminationStatus == 0,
              let img = NSImage(contentsOfFile: tempSnap),
              let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let cg = bmp.cgImage else {
            try? FileManager.default.removeItem(atPath: tempSnap)
            return nil
        }
        try? FileManager.default.removeItem(atPath: tempSnap)
        return cg
    }

    func beginCapture(completion: @escaping (CaptureSelectionResult?) -> Void) {
        guard ensureScreenCaptureAccess(showAlertOnDenial: true) else {
            completion(nil)
            return
        }

        let allScreens = NSScreen.screens
        guard !allScreens.isEmpty else {
            completion(nil)
            return
        }

        let mouse = NSEvent.mouseLocation
        let initialScreen = allScreens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? allScreens[0]
        let crosshairConfig = CrosshairConfigurationStore().load()

        var descriptors: [(screenFrame: NSRect, cgImage: CGImage, candidateWindowRects: [NSRect], isInitialCursorScreen: Bool)] = []
        for (idx, screen) in allScreens.enumerated() {
            guard let cgScreenshot = captureDisplayImage(for: screen, displayIndex: idx + 1) else {
                continue
            }
            let candidateWindows = Self.detectVisibleWindowRectsInView(for: screen)
            descriptors.append((
                screenFrame: screen.frame,
                cgImage: cgScreenshot,
                candidateWindowRects: candidateWindows,
                isInitialCursorScreen: screen == initialScreen
            ))
        }

        guard descriptors.contains(where: { $0.isInitialCursorScreen }) else {
            Self.presentScreenRecordingPermissionAlertIfNeeded()
            completion(nil)
            return
        }

        installCaptureOverlays(
            descriptors: descriptors,
            crosshairConfig: crosshairConfig,
            hideSystemCursor: true,
            completion: completion
        )
    }

    func installCaptureOverlays(
        descriptors: [(screenFrame: NSRect, cgImage: CGImage, candidateWindowRects: [NSRect], isInitialCursorScreen: Bool)],
        crosshairConfig: CrosshairConfiguration = .defaults,
        hideSystemCursor: Bool = false,
        completion: @escaping (CaptureSelectionResult?) -> Void
    ) {
        guard descriptors.contains(where: { $0.isInitialCursorScreen }) else {
            presentPermissionAlert()
            completion(nil)
            return
        }

        var createdPanels: [(isInitial: Bool, panel: CaptureOverlayPanel, view: PixPinSelectionView)] = []
        for desc in descriptors {
            let frozenImage = NSImage(cgImage: desc.cgImage, size: desc.screenFrame.size)
            let scaleFactor = CGFloat(desc.cgImage.width) / max(1.0, desc.screenFrame.width)

            let panel = CaptureOverlayPanel(
                contentRect: desc.screenFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.acceptsMouseMovedEvents = true

            let view = PixPinSelectionView(
                frame: NSRect(origin: .zero, size: desc.screenFrame.size),
                screenOrigin: desc.screenFrame.origin,
                frozenImage: frozenImage,
                cgImage: desc.cgImage,
                scaleFactor: scaleFactor,
                candidateWindowRects: desc.candidateWindowRects,
                crosshairConfig: crosshairConfig,
                isCursorInsideScreen: desc.isInitialCursorScreen,
                onActivateScreen: { [weak self] activeView in
                    self?.activateOverlayView(activeView)
                },
                onFinish: { [weak self] result in
                    self?.finish(with: result)
                }
            )
            panel.contentView = view
            createdPanels.append((desc.isInitialCursorScreen, panel, view))
        }

        self.completion = completion
        self.overlayWindows = createdPanels.map { $0.panel }

        if hideSystemCursor && !isCursorHidden {
            NSCursor.hide()
            isCursorHidden = true
        }
        NSApp.activate(ignoringOtherApps: true)
        for item in createdPanels {
            item.view.display()
            item.panel.orderFrontRegardless()
        }
        if let initialItem = createdPanels.first(where: { $0.isInitial }) {
            initialItem.panel.makeKey()
            initialItem.panel.makeFirstResponder(initialItem.view)
        }
    }

    func activateOverlayView(_ activeView: PixPinSelectionView) {
        for panel in overlayWindows {
            guard let view = panel.contentView as? PixPinSelectionView else { continue }
            let isTarget = (view === activeView)
            if !isTarget {
                view.clearActiveDragIfNeeded()
            }
            if view.isCursorInsideScreen != isTarget {
                view.isCursorInsideScreen = isTarget
                view.needsDisplay = true
            }
            if isTarget {
                if !panel.isKeyWindow {
                    panel.makeKey()
                }
                panel.makeFirstResponder(view)
            }
        }
    }

    func finish(with result: CaptureSelectionResult?) {
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
        for panel in overlayWindows {
            panel.orderOut(nil)
        }
        overlayWindows.removeAll()
        let cb = completion
        completion = nil
        cb?(result)
    }

    nonisolated static func convertCGWindowBoundsToViewRect(
        cgBounds: CGRect,
        primaryScreenHeight: CGFloat,
        targetScreenFrame: NSRect
    ) -> NSRect? {
        let globalX = cgBounds.origin.x
        let globalY = primaryScreenHeight - cgBounds.origin.y - cgBounds.height
        let globalRect = NSRect(x: globalX, y: globalY, width: cgBounds.width, height: cgBounds.height)
        let clippedGlobal = globalRect.intersection(targetScreenFrame)
        guard !clippedGlobal.isEmpty, clippedGlobal.width >= 24, clippedGlobal.height >= 24 else {
            return nil
        }
        return NSRect(
            x: round(clippedGlobal.origin.x - targetScreenFrame.origin.x),
            y: round(clippedGlobal.origin.y - targetScreenFrame.origin.y),
            width: round(clippedGlobal.width),
            height: round(clippedGlobal.height)
        )
    }

    nonisolated static func shouldIncludeWindowForSnap(
        ownerPID: pid_t,
        ownPID: pid_t,
        ownerName: String?,
        layer: Int,
        alpha: Double,
        viewRect: NSRect,
        screenSize: NSSize
    ) -> Bool {
        if ownerPID == ownPID { return false }
        // Only snap normal application windows (layer 0) and floating utility panels (layer 1...8);
        // exclude Dock fullscreen backdrop (layer 20), menu bar, notification center, etc.
        guard layer >= 0 && layer <= 8 else { return false }
        guard alpha > 0.05 else { return false }
        let excludedOwners: Set<String> = [
            "Dock",
            "Window Server",
            "Control Center",
            "Notification Center",
            "Spotlight",
            "Wallpaper"
        ]
        if let name = ownerName, excludedOwners.contains(name) {
            return false
        }
        return viewRect.width >= 24 && viewRect.height >= 24
    }

    static func detectVisibleWindowRectsInView(for screen: NSScreen) -> [NSRect] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var rects: [NSRect] = []
        for entry in infoList {
            let ownerPID = (entry[kCGWindowOwnerPID as String] as? pid_t) ?? 0
            let ownerName = entry[kCGWindowOwnerName as String] as? String
            let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
            let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1.0
            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict),
                  let viewRect = convertCGWindowBoundsToViewRect(
                      cgBounds: cgBounds,
                      primaryScreenHeight: primaryHeight,
                      targetScreenFrame: screen.frame
                  ),
                  shouldIncludeWindowForSnap(
                      ownerPID: ownerPID,
                      ownPID: ownPID,
                      ownerName: ownerName,
                      layer: layer,
                      alpha: alpha,
                      viewRect: viewRect,
                      screenSize: screen.frame.size
                  ) else {
                continue
            }
            rects.append(viewRect)
        }
        return rects
    }

    private static var permissionHUDPanel: NSPanel?

    nonisolated static func currentExecutableFileURL() -> URL {
        if let execURL = Bundle.main.executableURL {
            return execURL.resolvingSymlinksInPath()
        }
        let arg0 = CommandLine.arguments.first ?? "~/.local/bin/clipline"
        let expanded = NSString(string: arg0).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
    }

    static func dismissScreenRecordingPermissionAlert() {
        permissionHUDPanel?.orderOut(nil)
        permissionHUDPanel = nil
    }

    static func relaunchCurrentDaemonProcess() {
        let executableURL = currentExecutableFileURL()
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = []
        proc.environment = ProcessInfo.processInfo.environment
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        SingleInstanceLock.releaseLockIfHeld()
        do {
            try proc.run()
            exit(0)
        } catch {
            _ = SingleInstanceLock.acquireOrNotifyExisting(notifyExisting: false)
        }
    }

    @discardableResult
    static func makeScreenRecordingPermissionPanel(
        onOpenSettings: (() -> Void)? = nil,
        onRevealBinary: (() -> Void)? = nil,
        onRelaunch: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) -> NSPanel {
        dismissScreenRecordingPermissionAlert()

        let openSettingsAction = onOpenSettings ?? {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        let revealBinaryAction = onRevealBinary ?? {
            let fileURL = currentExecutableFileURL()
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
        let relaunchAction = onRelaunch ?? {
            relaunchCurrentDaemonProcess()
        }
        let dismissAction = onDismiss ?? {
            dismissScreenRecordingPermissionAlert()
        }

        let cardWidth: CGFloat = 468
        let cardHeight: CGFloat = 198
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: round(visible.midX - cardWidth / 2),
            y: round(visible.midY - cardHeight / 2 + 80),
            width: cardWidth,
            height: cardHeight
        )

        let panel = PermissionNoticeHUDPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.onEscape = dismissAction

        let rootView = ScreenRecordingPermissionHUDView(
            onOpenSettings: {
                openSettingsAction()
            },
            onRevealBinary: {
                revealBinaryAction()
            },
            onRelaunch: {
                dismissAction()
                relaunchAction()
            },
            onClose: dismissAction
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = hosting
        permissionHUDPanel = panel
        return panel
    }

    static func presentScreenRecordingPermissionAlertIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = makeScreenRecordingPermissionPanel()
        panel.makeKeyAndOrderFront(nil)
    }
}

final class PermissionNoticeHUDPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

struct ScreenRecordingPermissionHUDView: View {
    let onOpenSettings: () -> Void
    let onRevealBinary: () -> Void
    let onRelaunch: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.16, green: 0.56, blue: 0.98),
                                    Color(red: 0.10, green: 0.38, blue: 0.84)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                        )

                    Image(systemName: "viewfinder.rectangular")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.alertScreenRecordingTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)

                    Text(L10n.alertScreenRecordingBody)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }

                Spacer(minLength: 4)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(L10n.alertCancelButton)
            }

            Divider()
                .opacity(0.45)

            HStack(spacing: 8) {
                Button(action: onRevealBinary) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(L10n.alertRevealBinaryButton)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.6)
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onRelaunch) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(L10n.alertRelaunchButton)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.6)
                    )
                }
                .buttonStyle(.plain)

                Button(action: onOpenSettings) {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(L10n.alertOpenSystemSettingsButton)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 456)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 4)
        .padding(6)
    }
}

final class CaptureOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension CrosshairColorPreset {
    var nsColor: NSColor {
        switch self {
        case .cyan: return NSColor(calibratedRed: 0.25, green: 0.85, blue: 1.0, alpha: 1.0)
        case .green: return NSColor(calibratedRed: 0.20, green: 0.92, blue: 0.45, alpha: 1.0)
        case .red: return NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.32, alpha: 1.0)
        case .yellow: return NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.18, alpha: 1.0)
        case .white: return NSColor(calibratedWhite: 1.0, alpha: 1.0)
        }
    }
}

final class PixPinSelectionView: NSView {
    private let screenOrigin: NSPoint
    private let frozenImage: NSImage
    private let cgImage: CGImage
    private let scaleFactor: CGFloat
    let candidateWindowRects: [NSRect]
    var crosshairConfig: CrosshairConfiguration
    var isCursorInsideScreen: Bool
    private let onActivateScreen: ((PixPinSelectionView) -> Void)?
    var pasteboardProvider: () -> NSPasteboard = { ClotheslineManager.shared.pasteboardProvider() }
    private let onFinish: (CaptureSelectionResult?) -> Void

    private(set) var mousePos: NSPoint = .zero
    private var startDragPos: NSPoint? = nil
    private var currentDragPos: NSPoint? = nil
    private var trackingArea: NSTrackingArea?

    init(
        frame: NSRect,
        screenOrigin: NSPoint,
        frozenImage: NSImage,
        cgImage: CGImage,
        scaleFactor: CGFloat,
        candidateWindowRects: [NSRect] = [],
        crosshairConfig: CrosshairConfiguration = CrosshairConfigurationStore().load(),
        isCursorInsideScreen: Bool = true,
        onActivateScreen: ((PixPinSelectionView) -> Void)? = nil,
        onFinish: @escaping (CaptureSelectionResult?) -> Void
    ) {
        self.screenOrigin = screenOrigin
        self.frozenImage = frozenImage
        self.cgImage = cgImage
        self.scaleFactor = scaleFactor
        self.candidateWindowRects = candidateWindowRects
        self.crosshairConfig = crosshairConfig
        self.isCursorInsideScreen = isCursorInsideScreen
        self.onActivateScreen = onActivateScreen
        self.onFinish = onFinish
        super.init(frame: frame)
        let mouseInScreen = NSEvent.mouseLocation
        self.mousePos = NSPoint(x: mouseInScreen.x - screenOrigin.x, y: mouseInScreen.y - screenOrigin.y)
    }

    static func samplePixelHexColor(cgImage: CGImage, viewHeight: CGFloat, scaleFactor: CGFloat, viewPoint: NSPoint) -> (hex: String, color: NSColor)? {
        guard cgImage.width > 0, cgImage.height > 0 else { return nil }
        let px = max(0, min(cgImage.width - 1, Int((viewPoint.x * scaleFactor).rounded(.down))))
        let py = max(0, min(cgImage.height - 1, Int(((viewHeight - viewPoint.y) * scaleFactor).rounded(.down))))
        guard let onePixelCG = cgImage.cropping(to: CGRect(x: px, y: py, width: 1, height: 1)) else { return nil }
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(onePixelCG, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = pixel[0]
        let g = pixel[1]
        let b = pixel[2]
        let hex = String(format: "#%02X%02X%02X", r, g, b)
        let nsColor = NSColor(
            srgbRed: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
        return (hex, nsColor)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    func clearActiveDragIfNeeded() {
        if startDragPos != nil || currentDragPos != nil {
            startDragPos = nil
            currentDragPos = nil
            needsDisplay = true
        }
    }

    func hoveredWindowRect(at point: NSPoint) -> NSRect? {
        for rect in candidateWindowRects where rect.contains(point) {
            return rect.intersection(bounds)
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        mousePos = convert(event.locationInWindow, from: nil)
        isCursorInsideScreen = true
        onActivateScreen?(self)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        if startDragPos == nil {
            isCursorInsideScreen = false
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        mousePos = convert(event.locationInWindow, from: nil)
        if !isCursorInsideScreen {
            isCursorInsideScreen = true
            onActivateScreen?(self)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        isCursorInsideScreen = true
        onActivateScreen?(self)
        startDragPos = pt
        currentDragPos = pt
        mousePos = pt
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let clampedPt = NSPoint(
            x: max(bounds.minX, min(bounds.maxX, pt.x)),
            y: max(bounds.minY, min(bounds.maxY, pt.y))
        )
        currentDragPos = clampedPt
        mousePos = clampedPt
        needsDisplay = true
    }

    private func completeCapture(with rect: NSRect) {
        let clippedRect = rect.intersection(bounds)
        if clippedRect.isEmpty || clippedRect.width < 24 || clippedRect.height < 24 {
            startDragPos = nil
            currentDragPos = nil
            needsDisplay = true
            return
        }
        guard let cropped = Self.cropImage(cgImage: cgImage, viewHeight: bounds.height, scaleFactor: scaleFactor, rect: clippedRect) else {
            onFinish(nil)
            return
        }
        let globalRect = NSRect(
            x: screenOrigin.x + clippedRect.origin.x,
            y: screenOrigin.y + clippedRect.origin.y,
            width: cropped.size.width,
            height: cropped.size.height
        )
        let res = CaptureSelectionResult(
            fullScreenCGImage: cgImage,
            fullScreenFrame: NSRect(origin: screenOrigin, size: bounds.size),
            scaleFactor: scaleFactor,
            selectedScreenRect: globalRect,
            croppedImage: cropped
        )
        onFinish(res)
    }

    override func mouseUp(with event: NSEvent) {
        guard let s = startDragPos, let e = currentDragPos else {
            return
        }
        let rawEnd = convert(event.locationInWindow, from: nil)
        let inScreenBounds = rawEnd.x >= bounds.minX && rawEnd.x <= bounds.maxX && rawEnd.y >= bounds.minY && rawEnd.y <= bounds.maxY
        if !inScreenBounds {
            // Releasing a drag outside this display cancels the current drag rather than capturing a clipped edge strip or snapping a border window
            startDragPos = nil
            currentDragPos = nil
            isCursorInsideScreen = false
            needsDisplay = true
            return
        }
        let dragDistance = hypot(e.x - s.x, e.y - s.y)
        let rect: NSRect
        if dragDistance < 4.0, let snappedWindow = hoveredWindowRect(at: e),
           snappedWindow.width >= 24, snappedWindow.height >= 24 {
            rect = snappedWindow
        } else {
            rect = normalizedRect(from: s, to: e).intersection(bounds)
        }
        completeCapture(with: rect)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish(nil)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if event.keyCode == 53 { // Esc
            onFinish(nil)
        } else if !event.isARepeat && (event.keyCode == 49 || (event.keyCode == 0 && event.modifierFlags.contains(.command))) {
            // Space (49) or Cmd+A (0 with .command) captures the entire screen
            completeCapture(with: bounds)
        } else if !event.isARepeat && event.keyCode == 8 && flags.isEmpty {
            // Press 'C' while hovering to copy the center pixel's #HEX color and exit capture
            if let sampled = Self.samplePixelHexColor(cgImage: cgImage, viewHeight: bounds.height, scaleFactor: scaleFactor, viewPoint: mousePos) {
                let pb = pasteboardProvider()
                pb.clearContents()
                pb.setString(sampled.hex, forType: .string)
            }
            onFinish(nil)
        }
    }

    private func normalizedRect(from p1: NSPoint, to p2: NSPoint) -> NSRect {
        NSRect(
            x: round(min(p1.x, p2.x)),
            y: round(min(p1.y, p2.y)),
            width: round(abs(p2.x - p1.x)),
            height: round(abs(p2.y - p1.y))
        )
    }

    static func cropImage(cgImage: CGImage, viewHeight: CGFloat, scaleFactor: CGFloat, rect: NSRect) -> NSImage? {
        let pixelX = rect.origin.x * scaleFactor
        let pixelY = (viewHeight - rect.origin.y - rect.height) * scaleFactor
        let pixelW = rect.width * scaleFactor
        let pixelH = rect.height * scaleFactor

        let cropZone = CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH)
            .intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard !cropZone.isEmpty, let subCG = cgImage.cropping(to: cropZone) else { return nil }
        return NSImage(cgImage: subCG, size: NSSize(width: cropZone.width / scaleFactor, height: cropZone.height / scaleFactor))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        frozenImage.draw(in: bounds)

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.30).cgColor)
        ctx.fill(bounds)
        ctx.restoreGState()

        if let s = startDragPos, let e = currentDragPos, hypot(e.x - s.x, e.y - s.y) >= 4.0 {
            let sel = normalizedRect(from: s, to: e)
            if sel.width > 1 && sel.height > 1 {
                drawHighlightedRegion(sel, showCornerHandles: true, in: ctx)
            }
            drawCrosshairAndLoupe(in: ctx)
        } else if isCursorInsideScreen {
            if let hoveredWin = hoveredWindowRect(at: mousePos), hoveredWin.width > 1, hoveredWin.height > 1 {
                drawHighlightedRegion(hoveredWin, showCornerHandles: false, in: ctx)
            }
            if crosshairConfig.style == .full {
                ctx.saveGState()
                ctx.setStrokeColor(crosshairConfig.color.nsColor.withAlphaComponent(0.45).cgColor)
                ctx.setLineWidth(0.9)
                ctx.move(to: CGPoint(x: 0, y: mousePos.y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: mousePos.y))
                ctx.move(to: CGPoint(x: mousePos.x, y: 0))
                ctx.addLine(to: CGPoint(x: mousePos.x, y: bounds.height))
                ctx.strokePath()
                ctx.restoreGState()
            }
            drawCrosshairAndLoupe(in: ctx)
        }
    }

    private func drawHighlightedRegion(_ sel: NSRect, showCornerHandles: Bool, in ctx: CGContext) {
        frozenImage.draw(in: sel, from: sel, operation: .copy, fraction: 1.0)

        ctx.saveGState()
        ctx.setStrokeColor(NSColor(calibratedRed: 0.15, green: 0.65, blue: 1.0, alpha: 1.0).cgColor)
        ctx.setLineWidth(showCornerHandles ? 1.8 : 2.2)
        ctx.stroke(sel)

        if showCornerHandles {
            let corners = [
                NSPoint(x: sel.minX, y: sel.minY),
                NSPoint(x: sel.maxX, y: sel.minY),
                NSPoint(x: sel.minX, y: sel.maxY),
                NSPoint(x: sel.maxX, y: sel.maxY)
            ]
            ctx.setFillColor(NSColor.white.cgColor)
            for c in corners {
                let hRect = CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)
                ctx.fillEllipse(in: hRect)
                ctx.strokeEllipse(in: hRect)
            }
        }
        ctx.restoreGState()

        let dimStr = "\(Int(sel.width)) × \(Int(sel.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let strSize = dimStr.size(withAttributes: attrs)
        let badgeRect = CGRect(
            x: max(8, sel.minX),
            y: min(bounds.height - 28, sel.maxY + 6),
            width: strSize.width + 14,
            height: strSize.height + 6
        )
        ctx.saveGState()
        let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.addPath(badgePath)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        dimStr.draw(at: NSPoint(x: badgeRect.minX + 7, y: badgeRect.minY + 3), withAttributes: attrs)
    }

    private func drawCrosshairAndLoupe(in ctx: CGContext) {
        let primaryColor = crosshairConfig.color.nsColor

        ctx.saveGState()
        if crosshairConfig.style == .dotRing {
            let ringRadius: CGFloat = 9.0
            let ringRect = CGRect(
                x: mousePos.x - ringRadius,
                y: mousePos.y - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            )
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(3.0)
            ctx.strokeEllipse(in: ringRect)

            ctx.setStrokeColor(primaryColor.cgColor)
            ctx.setLineWidth(1.6)
            ctx.strokeEllipse(in: ringRect)

            let dotRect = CGRect(x: mousePos.x - 2.0, y: mousePos.y - 2.0, width: 4.0, height: 4.0)
            ctx.setFillColor(primaryColor.cgColor)
            ctx.fillEllipse(in: dotRect)
        } else {
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(3.0)
            ctx.move(to: CGPoint(x: mousePos.x - 10, y: mousePos.y))
            ctx.addLine(to: CGPoint(x: mousePos.x + 10, y: mousePos.y))
            ctx.move(to: CGPoint(x: mousePos.x, y: mousePos.y - 10))
            ctx.addLine(to: CGPoint(x: mousePos.x, y: mousePos.y + 10))
            ctx.strokePath()

            ctx.setStrokeColor(primaryColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: mousePos.x - 10, y: mousePos.y))
            ctx.addLine(to: CGPoint(x: mousePos.x + 10, y: mousePos.y))
            ctx.move(to: CGPoint(x: mousePos.x, y: mousePos.y - 10))
            ctx.addLine(to: CGPoint(x: mousePos.x, y: mousePos.y + 10))
            ctx.strokePath()
        }

        guard crosshairConfig.showLoupe else {
            ctx.restoreGState()
            return
        }

        let loupeSize: CGFloat = 96
        let badgeHeight: CGFloat = 24
        var lx = mousePos.x + 20
        var ly = mousePos.y - loupeSize - 20
        if lx + loupeSize > bounds.width - 10 { lx = mousePos.x - loupeSize - 20 }
        if ly - badgeHeight - 8 < 10 { ly = mousePos.y + 20 + badgeHeight + 6 }

        let loupeRect = CGRect(x: lx, y: ly, width: loupeSize, height: loupeSize)
        let sampleSpan: CGFloat = 24
        let srcRect = NSRect(
            x: mousePos.x - sampleSpan / 2,
            y: mousePos.y - sampleSpan / 2,
            width: sampleSpan,
            height: sampleSpan
        )

        ctx.saveGState()
        let clipPath = CGPath(ellipseIn: loupeRect, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(loupeRect)
        NSGraphicsContext.current?.imageInterpolation = .none
        frozenImage.draw(in: loupeRect, from: srcRect, operation: .sourceOver, fraction: 1.0)

        ctx.setStrokeColor(primaryColor.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: loupeRect.midX, y: loupeRect.minY))
        ctx.addLine(to: CGPoint(x: loupeRect.midX, y: loupeRect.maxY))
        ctx.move(to: CGPoint(x: loupeRect.minX, y: loupeRect.midY))
        ctx.addLine(to: CGPoint(x: loupeRect.maxX, y: loupeRect.midY))
        ctx.strokePath()
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2.0)
        ctx.strokeEllipse(in: loupeRect)

        if let sampled = Self.samplePixelHexColor(cgImage: cgImage, viewHeight: bounds.height, scaleFactor: scaleFactor, viewPoint: mousePos) {
            let pillWidth: CGFloat = 104
            let pillRect = CGRect(
                x: round(loupeRect.midX - pillWidth / 2),
                y: round(loupeRect.minY - badgeHeight - 6),
                width: pillWidth,
                height: badgeHeight
            )
            let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.saveGState()
            ctx.addPath(pillPath)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.84).cgColor)
            ctx.fillPath()
            ctx.addPath(pillPath)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
            ctx.setLineWidth(1.0)
            ctx.strokePath()

            let swatchRect = CGRect(x: pillRect.minX + 7, y: pillRect.midY - 5.5, width: 11, height: 11)
            let swatchPath = CGPath(roundedRect: swatchRect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
            ctx.addPath(swatchPath)
            ctx.setFillColor(sampled.color.cgColor)
            ctx.fillPath()
            ctx.addPath(swatchPath)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(0.8)
            ctx.strokePath()
            ctx.restoreGState()

            let hexText = "\(sampled.hex) · C" as NSString
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let textSize = hexText.size(withAttributes: textAttrs)
            hexText.draw(
                at: NSPoint(x: swatchRect.maxX + 6, y: pillRect.midY - textSize.height / 2),
                withAttributes: textAttrs
            )
        }
        ctx.restoreGState()
    }
}
