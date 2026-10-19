import AppKit
import CoreGraphics
import Darwin
import Foundation

// MARK: - Zero-Flicker In-Memory Screen Capture & Region Selector

@MainActor
final class ScreenCaptureOverlayController {
    private var overlayWindow: NSPanel?
    private var completion: ((CaptureSelectionResult?) -> Void)?

    private static let cgDisplayCreateImageFn: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(handle, "CGDisplayCreateImage") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?).self)
    }()

    func beginCapture(completion: @escaping (CaptureSelectionResult?) -> Void) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            completion(nil)
            return
        }

        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
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

    static func presentScreenRecordingPermissionAlertIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要「屏幕录制」权限才能截图"
        alert.informativeText = "请前往「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」，勾选允许当前终端或 ClipLine 可执行程序后重试。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
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
        onFinish: @escaping (CaptureSelectionResult?) -> Void
    ) {
        self.screenOrigin = screenOrigin
        self.frozenImage = frozenImage
        self.cgImage = cgImage
        self.scaleFactor = scaleFactor
        self.onFinish = onFinish
        super.init(frame: frame)
        let mouseInScreen = NSEvent.mouseLocation
        self.mousePos = NSPoint(x: mouseInScreen.x - screenOrigin.x, y: mouseInScreen.y - screenOrigin.y)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

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
        let rect = normalizedRect(from: s, to: e).intersection(bounds)
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

        if let s = startDragPos, let e = currentDragPos {
            let sel = normalizedRect(from: s, to: e)
            if sel.width > 1 && sel.height > 1 {
                frozenImage.draw(in: sel, from: sel, operation: .copy, fraction: 1.0)

                ctx.saveGState()
                ctx.setStrokeColor(NSColor(calibratedRed: 0.15, green: 0.65, blue: 1.0, alpha: 1.0).cgColor)
                ctx.setLineWidth(1.8)
                ctx.stroke(sel)

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
        } else {
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
