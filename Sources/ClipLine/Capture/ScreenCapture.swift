import AppKit
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

// MARK: - Zero-Flicker In-Memory Screen Capture & Region Selector

@MainActor
final class ScreenCaptureOverlayController {
    private var overlayWindow: NSPanel?
    private var completion: ((CaptureSelectionResult?) -> Void)?
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

    func beginCapture(completion: @escaping (CaptureSelectionResult?) -> Void) {
        guard ensureScreenCaptureAccess(showAlertOnDenial: true) else {
            completion(nil)
            return
        }

        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            completion(nil)
            return
        }

        let cgScreenshot: CGImage
        if let fn = Self.cgDisplayCreateImageFn, let unmanaged = fn(displayID) {
            cgScreenshot = unmanaged.takeRetainedValue()
        } else {
            let displayIndex = (NSScreen.screens.firstIndex(of: screen) ?? 0) + 1
            let tempSnap = ClipboardHelper.uniqueTempFileURL(prefix: "clipline_snap_full").path
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-x", "-D", "\(displayIndex)", tempSnap]
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                try? FileManager.default.removeItem(atPath: tempSnap)
                completion(nil)
                return
            }
            guard proc.terminationStatus == 0,
                  let img = NSImage(contentsOfFile: tempSnap),
                  let tiff = img.tiffRepresentation,
                  let bmp = NSBitmapImageRep(data: tiff),
                  let cg = bmp.cgImage else {
                try? FileManager.default.removeItem(atPath: tempSnap)
                Self.presentScreenRecordingPermissionAlertIfNeeded()
                completion(nil)
                return
            }
            try? FileManager.default.removeItem(atPath: tempSnap)
            cgScreenshot = cg
        }

        let frozenImage = NSImage(cgImage: cgScreenshot, size: screen.frame.size)
        let scaleFactor = CGFloat(cgScreenshot.width) / screen.frame.width
        let candidateWindows = Self.detectVisibleWindowRectsInView(for: screen)
        self.completion = completion

        let panel = CaptureOverlayPanel(
            contentRect: screen.frame,
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

        let view = PixPinSelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            screenOrigin: screen.frame.origin,
            frozenImage: frozenImage,
            cgImage: cgScreenshot,
            scaleFactor: scaleFactor,
            candidateWindowRects: candidateWindows,
            onFinish: { [weak self] result in
                self?.finish(with: result)
            }
        )
        panel.contentView = view
        self.overlayWindow = panel

        view.display()
        NSCursor.hide()
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(view)
    }

    private func finish(with result: CaptureSelectionResult?) {
        NSCursor.unhide()
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
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
            "WindowManager",
            "Window Server",
            "Control Center",
            "Notification Center",
            "Spotlight",
            "Wallpaper"
        ]
        if let name = ownerName, excludedOwners.contains(name) {
            return false
        }
        // Skip full-screen desktop/backdrop windows that cover >=98% of the screen
        if viewRect.width >= screenSize.width * 0.98 && viewRect.height >= screenSize.height * 0.98 {
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

final class PixPinSelectionView: NSView {
    private let screenOrigin: NSPoint
    private let frozenImage: NSImage
    private let cgImage: CGImage
    private let scaleFactor: CGFloat
    let candidateWindowRects: [NSRect]
    private let onFinish: (CaptureSelectionResult?) -> Void

    private var mousePos: NSPoint = .zero
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
        onFinish: @escaping (CaptureSelectionResult?) -> Void
    ) {
        self.screenOrigin = screenOrigin
        self.frozenImage = frozenImage
        self.cgImage = cgImage
        self.scaleFactor = scaleFactor
        self.candidateWindowRects = candidateWindowRects
        self.onFinish = onFinish
        super.init(frame: frame)
        let mouseInScreen = NSEvent.mouseLocation
        self.mousePos = NSPoint(x: mouseInScreen.x - screenOrigin.x, y: mouseInScreen.y - screenOrigin.y)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

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
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        mousePos = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        startDragPos = pt
        currentDragPos = pt
        mousePos = pt
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        currentDragPos = pt
        mousePos = pt
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let s = startDragPos, let e = currentDragPos else {
            onFinish(nil)
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
        if rect.isEmpty || rect.width < 24 || rect.height < 24 {
            startDragPos = nil
            currentDragPos = nil
            needsDisplay = true
            return
        }
        guard let cropped = Self.cropImage(cgImage: cgImage, viewHeight: bounds.height, scaleFactor: scaleFactor, rect: rect) else {
            onFinish(nil)
            return
        }
        let globalRect = NSRect(
            x: screenOrigin.x + rect.origin.x,
            y: screenOrigin.y + rect.origin.y,
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

    override func rightMouseDown(with event: NSEvent) {
        onFinish(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
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
        } else {
            if let hoveredWin = hoveredWindowRect(at: mousePos), hoveredWin.width > 1, hoveredWin.height > 1 {
                drawHighlightedRegion(hoveredWin, showCornerHandles: false, in: ctx)
            }
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.42).cgColor)
            ctx.setLineWidth(0.8)
            ctx.move(to: CGPoint(x: 0, y: mousePos.y))
            ctx.addLine(to: CGPoint(x: bounds.width, y: mousePos.y))
            ctx.move(to: CGPoint(x: mousePos.x, y: 0))
            ctx.addLine(to: CGPoint(x: mousePos.x, y: bounds.height))
            ctx.strokePath()
            ctx.restoreGState()
        }

        drawCrosshairAndLoupe(in: ctx)
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
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(3.0)
        ctx.move(to: CGPoint(x: mousePos.x - 10, y: mousePos.y))
        ctx.addLine(to: CGPoint(x: mousePos.x + 10, y: mousePos.y))
        ctx.move(to: CGPoint(x: mousePos.x, y: mousePos.y - 10))
        ctx.addLine(to: CGPoint(x: mousePos.x, y: mousePos.y + 10))
        ctx.strokePath()

        ctx.setStrokeColor(NSColor(calibratedRed: 0.25, green: 0.85, blue: 1.0, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: mousePos.x - 10, y: mousePos.y))
        ctx.addLine(to: CGPoint(x: mousePos.x + 10, y: mousePos.y))
        ctx.move(to: CGPoint(x: mousePos.x, y: mousePos.y - 10))
        ctx.addLine(to: CGPoint(x: mousePos.x, y: mousePos.y + 10))
        ctx.strokePath()

        let loupeSize: CGFloat = 96
        var lx = mousePos.x + 20
        var ly = mousePos.y - loupeSize - 20
        if lx + loupeSize > bounds.width - 10 { lx = mousePos.x - loupeSize - 20 }
        if ly < 10 { ly = mousePos.y + 20 }

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

        ctx.setStrokeColor(NSColor(calibratedRed: 0.25, green: 0.85, blue: 1.0, alpha: 0.85).cgColor)
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
        ctx.restoreGState()
    }
}
