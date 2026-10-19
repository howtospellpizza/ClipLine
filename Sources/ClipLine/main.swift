import AppKit
import Carbon
import CoreGraphics
import CoreImage
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - Single-Instance Lock Helper

enum SingleInstanceLock {
    private static var lockFD: Int32 = -1

    static var lockFilePath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("ClipLine", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("clipline_daemon.lock").path
    }

    static func acquireOrNotifyExisting(path: String = lockFilePath, notifyExisting: Bool = true) -> Bool {
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            fputs("[ClipLine] Error: Unable to open lock file at \(path) (errno \(errno))\n", stderr)
            return false
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            let pidStr = "\(getpid())\n"
            _ = ftruncate(fd, 0)
            _ = pidStr.withCString { write(fd, $0, strlen($0)) }
            return true
        }
        close(fd)
        if notifyExisting {
            for channel in NotificationChannels.captureChannels {
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name(channel),
                    object: nil,
                    userInfo: ["mode": "interactive"],
                    deliverImmediately: true
                )
            }
        }
        return false
    }
}

enum NotificationChannels {
    static var translateChannels: [String] {
        var list = ["io.github.clipline.translate"]
        if let extra = ProcessInfo.processInfo.environment["CLIP_LINE_TRANSLATE_CHANNEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty, !list.contains(extra) {
            list.append(extra)
        }
        return list
    }

    static var captureChannels: [String] {
        var list = ["io.github.clipline.capture"]
        if let extra = ProcessInfo.processInfo.environment["CLIP_LINE_CAPTURE_CHANNEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty, !list.contains(extra) {
            list.append(extra)
        }
        return list
    }
}

// MARK: - Clipboard Helper (Multi-format PNG + TIFF + FileURL)

enum ClipboardHelper {
    static var tempDir: String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClipLine", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url.path
    }

    static func cleanupStaleTempFiles(olderThan ageSeconds: TimeInterval = 3600, in directoryPath: String = tempDir) {
        let dirURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-ageSeconds)
        for url in urls {
            let name = url.lastPathComponent
            guard (name.hasPrefix("ClipLine_") || name.hasPrefix("clipline_snap_")) && name.hasSuffix(".png") else {
                continue
            }
            if let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = vals.contentModificationDate,
               modDate < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func uniqueTempFileURL(prefix: String = "ClipLine", tempDir: String? = nil) -> URL {
        let dir = tempDir ?? Self.tempDir
        let ms = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
        let token = UUID().uuidString.prefix(8)
        return URL(fileURLWithPath: "\(dir)/\(prefix)_\(ms)_\(token).png")
    }

    static func copyImages(_ images: [NSImage], pasteboard: NSPasteboard = .general, tempDir: String? = nil) -> Bool {
        guard !images.isEmpty else { return false }
        let dir = tempDir ?? Self.tempDir
        cleanupStaleTempFiles(in: dir)

        let targetImage: NSImage
        let prefix: String
        if images.count == 1, let img = images.first {
            targetImage = img
            prefix = "ClipLine"
        } else {
            targetImage = stitchImagesGrid(images)
            prefix = "ClipLine_Stitched"
        }

        return writeSingleImageToPasteboard(targetImage, pasteboard: pasteboard, tempDir: dir, prefix: prefix)
    }

    @discardableResult
    private static func writeSingleImageToPasteboard(
        _ image: NSImage,
        pasteboard: NSPasteboard,
        tempDir: String,
        prefix: String = "ClipLine"
    ) -> Bool {
        guard let png = pngData(from: image) else {
            return false
        }

        let fileURL = uniqueTempFileURL(prefix: prefix, tempDir: tempDir)
        let wroteFile = (try? png.write(to: fileURL, options: .atomic)) != nil

        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        if wroteFile {
            item.setString(fileURL.absoluteString, forType: .fileURL)
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func stitchImagesGrid(_ images: [NSImage]) -> NSImage {
        guard images.count > 1 else { return images.first ?? NSImage() }
        let gap: CGFloat = 12
        let maxW = images.map { $0.size.width }.max() ?? 400
        let totalH = images.map { $0.size.height }.reduce(0, +) + gap * CGFloat(images.count - 1)

        let targetSize = NSSize(width: maxW, height: totalH)
        let result = NSImage(size: targetSize, flipped: true) { _ in
            var currentY: CGFloat = 0
            for img in images {
                let xOffset = (maxW - img.size.width) / 2
                img.draw(
                    in: NSRect(x: xOffset, y: currentY, width: img.size.width, height: img.size.height),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0,
                    respectFlipped: true,
                    hints: nil
                )
                currentY += img.size.height + gap
            }
            return true
        }
        return result
    }
}

// MARK: - Real Pixelation / Mosaic Helper (CoreImage CIPixellate)

enum MosaicRenderer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func createPixelatedImage(from image: NSImage, blockScale: CGFloat = 12.0) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgIn = bitmap.cgImage else { return nil }

        let ciInput = CIImage(cgImage: cgIn)
        let extent = ciInput.extent
        let pixelScale = max(8.0, blockScale * (CGFloat(cgIn.width) / max(1.0, image.size.width)))

        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ciInput.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: kCIInputCenterKey)
        filter.setValue(pixelScale, forKey: kCIInputScaleKey)

        guard let output = filter.outputImage?.cropped(to: extent),
              let cgOut = ciContext.createCGImage(output, from: extent) else { return nil }

        return NSImage(cgImage: cgOut, size: image.size)
    }
}

// MARK: - Capture Result (Full Screen Image + Selected Rect on Screen)

struct CaptureSelectionResult {
    let fullScreenCGImage: CGImage
    let fullScreenFrame: NSRect
    let scaleFactor: CGFloat
    let selectedScreenRect: NSRect
    let croppedImage: NSImage
}

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

// MARK: - Annotation Model & Stroke Size Preset

enum StrokePreset: String, CaseIterable, Identifiable {
    case thin = "细"
    case medium = "中"
    case thick = "粗"

    var id: String { rawValue }

    var strokeLineWidth: CGFloat {
        switch self {
        case .thin: return 2.0
        case .medium: return 4.0
        case .thick: return 7.5
        }
    }

    var mosaicBrushWidth: CGFloat {
        switch self {
        case .thin: return 14.0
        case .medium: return 24.0
        case .thick: return 40.0
        }
    }

    var textFontSize: CGFloat {
        switch self {
        case .thin: return 14.0
        case .medium: return 18.0
        case .thick: return 26.0
        }
    }

    var dotDiameter: CGFloat {
        switch self {
        case .thin: return 6.0
        case .medium: return 9.0
        case .thick: return 12.5
        }
    }
}

enum TextBackgroundStyle: String, CaseIterable, Identifiable {
    case transparent = "透明"
    case black = "黑底"
    case white = "白底"

    var id: String { rawValue }

    var fillNSColor: NSColor? {
        switch self {
        case .transparent:
            return nil
        case .black:
            return NSColor(calibratedWhite: 0.08, alpha: 0.90)
        case .white:
            return NSColor(calibratedWhite: 0.98, alpha: 0.94)
        }
    }
}

struct PinAnnotation: Identifiable {
    enum Tool: String, CaseIterable, Identifiable {
        case rect = "框选"
        case arrow = "箭头"
        case pen = "画笔"
        case mosaic = "马赛克"
        case text = "文字"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .rect: return "rectangle"
            case .arrow: return "arrow.up.right"
            case .pen: return "scribble"
            case .mosaic: return "checkerboard.rectangle"
            case .text: return "textformat"
            }
        }
    }

    let id = UUID()
    var tool: Tool
    var color: NSColor
    var lineWidth: CGFloat
    var points: [CGPoint]
    var text: String = ""
    var textBackgroundStyle: TextBackgroundStyle = .transparent
}

// MARK: - Skeuomorphic Clothesline Dock Manager

struct ClippedPinItem: Identifiable {
    let id: UUID
    let sessionVM: PinSessionViewModel
    var compositeImage: NSImage
    var isSelected: Bool = true
    let tiltAngle: Double
}

@MainActor
final class ClotheslineManager: ObservableObject {
    static let shared = ClotheslineManager()

    var pasteboardProvider: () -> NSPasteboard = { .general }
    var tempDirOverride: String? = nil

    @Published var items: [ClippedPinItem] = []
    @Published var toastMessage: String? = nil

    private(set) var dockPanel: NSPanel?

    var selectedItems: [ClippedPinItem] {
        items.filter(\.isSelected)
    }

    func clipToLine(vm: PinSessionViewModel) {
        vm.commitPendingText()
        guard let rendered = vm.renderCompositeImage() else {
            vm.showToast("图像合成失败，已拒绝导出")
            return
        }
        vm.hostingPanel?.orderOut(nil)
        vm.toolbarPanel?.orderOut(nil)

        let angles: [Double] = [-2.2, 1.8, -1.4, 2.1, -1.8, 1.3]
        let angle = angles[items.count % angles.count]

        if let idx = items.firstIndex(where: { $0.id == vm.id }) {
            items[idx].compositeImage = rendered
            items[idx].isSelected = true
        } else {
            items.append(
                ClippedPinItem(
                    id: vm.id,
                    sessionVM: vm,
                    compositeImage: rendered,
                    isSelected: true,
                    tiltAngle: angle
                )
            )
        }

        syncSelectedToClipboard(silent: true)
        updateDockVisibility()
        showToast("已夹上晾衣绳（当前选中 \(selectedItems.count) 张）")
    }

    func restoreToCanvas(_ item: ClippedPinItem) {
        items.removeAll { $0.id == item.id }
        updateDockVisibility()
        if let panel = item.sessionVM.hostingPanel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            item.sessionVM.updateToolbarPanelPosition()
        }
    }

    func toggleSelection(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].isSelected.toggle()
        if !selectedItems.isEmpty {
            syncSelectedToClipboard(silent: true)
        }
    }

    func toggleSelectAll() {
        let allSelected = items.allSatisfy(\.isSelected)
        let newState = !allSelected
        for i in items.indices {
            items[i].isSelected = newState
        }
        if newState {
            syncSelectedToClipboard(silent: false)
        } else {
            showToast("已取消全选")
        }
    }

    func syncSelectedToClipboard(silent: Bool = false) {
        let chosen = selectedItems
        guard !chosen.isEmpty else {
            if !silent {
                showToast("请先勾选要复制的照片")
            }
            return
        }
        let ok = ClipboardHelper.copyImages(chosen.map(\.compositeImage), pasteboard: pasteboardProvider(), tempDir: tempDirOverride)
        if !silent {
            showToast(ok ? "已复制 \(chosen.count) 张照片到剪贴板" : "复制失败，未能写入剪贴板")
        }
    }

    func saveSelectedToFolder() {
        let chosen = selectedItems
        guard !chosen.isEmpty else {
            showToast("请先勾选要保存的照片")
            return
        }

        if chosen.count == 1, let single = chosen.first {
            single.sessionVM.saveToFile()
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.prompt = "保存这 \(chosen.count) 张图片"
        openPanel.level = .screenSaver

        if openPanel.runModal() == .OK, let dirURL = openPanel.url {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH.mm.ss.SSS"
            let stamp = formatter.string(from: Date())
            var savedCount = 0
            for (i, item) in chosen.enumerated() {
                if let png = ClipboardHelper.pngData(from: item.compositeImage) {
                    let fileURL = dirURL.appendingPathComponent("ClipLine_\(stamp)_\(i + 1).png")
                    if (try? png.write(to: fileURL, options: .atomic)) != nil {
                        savedCount += 1
                    }
                }
            }
            if savedCount == chosen.count {
                showToast("已保存 \(savedCount) 张图片")
            } else if savedCount > 0 {
                showToast("已保存 \(savedCount)/\(chosen.count) 张图片（部分写入失败）")
            } else {
                showToast("保存失败，请检查目录权限")
            }
        }
    }

    func removeItem(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }) {
            item.sessionVM.hostingPanel?.onClosePanel?()
        }
        items.removeAll { $0.id == id }
        updateDockVisibility()
    }

    func clearAll() {
        for item in items {
            item.sessionVM.hostingPanel?.onClosePanel?()
        }
        items.removeAll()
        updateDockVisibility()
    }

    func showToast(_ msg: String) {
        toastMessage = msg
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if self.toastMessage == msg {
                self.toastMessage = nil
            }
        }
    }

    func updateDockVisibility() {
        if items.isEmpty {
            dockPanel?.orderOut(nil)
            return
        }

        if dockPanel == nil {
            createDockPanel()
        }

        guard let panel = dockPanel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let width = min(max(CGFloat(items.count) * 124 + 210, 400), visible.width - 40)
        let height: CGFloat = 148
        let origin = CGPoint(
            x: visible.midX - width / 2,
            y: visible.maxY - height + 4
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()
    }

    private func createDockPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 148),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let rootView = ClotheslineBarView(manager: self)
        panel.contentView = NSHostingView(rootView: rootView)
        self.dockPanel = panel
    }
}

// MARK: - Skeuomorphic Clothesline & Wooden Peg UI

struct WoodenClothespinView: View {
    var isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isSelected
                            ? [Color(red: 0.88, green: 0.68, blue: 0.42), Color(red: 0.72, green: 0.50, blue: 0.26)]
                            : [Color(red: 0.55, green: 0.52, blue: 0.48), Color(red: 0.40, green: 0.38, blue: 0.35)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 9, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5)
                        .stroke(Color.black.opacity(0.35), lineWidth: 0.6)
                )

            RoundedRectangle(cornerRadius: 1)
                .fill(Color(white: 0.82))
                .frame(width: 11, height: 4)
                .offset(y: 1)
                .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 2, x: 1, y: 2)
    }
}

struct ClotheslineRopeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: 8, y: 12)
        let end = CGPoint(x: rect.width - 8, y: 12)
        let control = CGPoint(x: rect.width / 2, y: 21)
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }
}

struct ClotheslineBarView: View {
    @ObservedObject var manager: ClotheslineManager

    var body: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                ClotheslineRopeShape()
                    .stroke(Color.black.opacity(0.35), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .offset(y: 2)

                ClotheslineRopeShape()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.76, green: 0.62, blue: 0.44),
                                Color(red: 0.62, green: 0.48, blue: 0.32),
                                Color(red: 0.76, green: 0.62, blue: 0.44)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 3.0, lineCap: .round, dash: [6, 1.5])
                    )

                HStack {
                    Circle()
                        .fill(RadialGradient(colors: [.white, .gray, .black], center: .topLeading, startRadius: 1, endRadius: 6))
                        .frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    Spacer()
                    Circle()
                        .fill(RadialGradient(colors: [.white, .gray, .black], center: .topLeading, startRadius: 1, endRadius: 6))
                        .frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                }
                .padding(.horizontal, 4)
                .offset(y: 8)
            }
            .frame(height: 28)

            HStack(alignment: .top, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(manager.items) { item in
                            HangingPhotoView(
                                item: item,
                                onSingleTap: { manager.toggleSelection(item.id) },
                                onDoubleTap: { manager.restoreToCanvas(item) },
                                onDelete: { manager.removeItem(item.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }

                VStack(spacing: 5) {
                    WoodenClothespinView(isSelected: true)
                        .offset(y: 2)
                        .zIndex(2)

                    VStack(spacing: 5) {
                        Button(action: { manager.syncSelectedToClipboard(silent: false) }) {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.on.doc.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("复制 (\(manager.selectedItems.count))")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(manager.selectedItems.isEmpty ? Color.gray.opacity(0.4) : Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(manager.selectedItems.isEmpty)

                        HStack(spacing: 6) {
                            Button(action: { manager.toggleSelectAll() }) {
                                Text(manager.items.allSatisfy(\.isSelected) ? "全不选" : "全选")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.primary.opacity(0.85))
                            }
                            .buttonStyle(.plain)

                            Text("·").foregroundColor(.secondary)

                            Button(action: { manager.saveSelectedToFolder() }) {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(.primary.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help("保存选中")

                            Text("·").foregroundColor(.secondary)

                            Button(action: { manager.clearAll() }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.red.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help("收起晾衣绳")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
                }
                .padding(.trailing, 14)
            }

            if let toast = manager.toastMessage {
                Text(toast)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.78))
                    .clipShape(Capsule())
                    .offset(y: 114)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct HangingPhotoView: View {
    let item: ClippedPinItem
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: -6) {
            WoodenClothespinView(isSelected: item.isSelected)
                .zIndex(3)

            ZStack(alignment: .topTrailing) {
                Image(nsImage: item.compositeImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 90, height: 64)
                    .clipped()
                    .padding(4)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(
                                item.isSelected ? Color.accentColor : Color.black.opacity(0.2),
                                lineWidth: item.isSelected ? 2.2 : 0.8
                            )
                    )
                    .opacity(item.isSelected ? 1.0 : 0.55)
                    .scaleEffect(item.isSelected ? 1.0 : 0.94)
                    .shadow(color: .black.opacity(0.38), radius: 5, x: 0, y: 4)

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.black.opacity(0.65))
                        .background(Circle().fill(Color.white))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
            .rotationEffect(.degrees(item.tiltAngle), anchor: .top)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onDoubleTap)
            .onTapGesture(count: 1, perform: onSingleTap)
            .onDrag {
                if let png = ClipboardHelper.pngData(from: item.compositeImage) {
                    let tempURL = ClipboardHelper.uniqueTempFileURL(
                        prefix: "ClipLine_Drag_\(item.id.uuidString.prefix(6))",
                        tempDir: ClotheslineManager.shared.tempDirOverride
                    )
                    try? png.write(to: tempURL)
                    if let provider = NSItemProvider(contentsOf: tempURL) {
                        return provider
                    }
                }
                return NSItemProvider(object: item.compositeImage)
            }
        }
        .help("单击：选中/取消 · 双击：取下继续标注 · 按住可直接拖拽到聊天框")
    }
}

// MARK: - Directional Resize Cursors (incl. Diagonal NE-SW and NW-SE)

enum DirectionalCursor {
    static let northSouth: NSCursor = makeResizeCursor(angleDegrees: 90)
    static let eastWest: NSCursor = makeResizeCursor(angleDegrees: 0)
    static let northWestSouthEast: NSCursor = makeResizeCursor(angleDegrees: -45)
    static let northEastSouthWest: NSCursor = makeResizeCursor(angleDegrees: 45)

    private static func makeResizeCursor(angleDegrees: CGFloat) -> NSCursor {
        let size = NSSize(width: 22, height: 22)
        let img = NSImage(size: size)
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: angleDegrees * .pi / 180.0)

            let path = CGMutablePath()
            let L: CGFloat = 8.5   // half-length to tip
            let H: CGFloat = 4.2   // arrowhead wing width
            let B: CGFloat = 4.0   // arrowhead base X
            let S: CGFloat = 1.35  // shaft half-thickness

            path.move(to: CGPoint(x: -L, y: 0))
            path.addLine(to: CGPoint(x: -B, y: H))
            path.addLine(to: CGPoint(x: -B, y: S))
            path.addLine(to: CGPoint(x: B, y: S))
            path.addLine(to: CGPoint(x: B, y: H))
            path.addLine(to: CGPoint(x: L, y: 0))
            path.addLine(to: CGPoint(x: B, y: -H))
            path.addLine(to: CGPoint(x: B, y: -S))
            path.addLine(to: CGPoint(x: -B, y: -S))
            path.addLine(to: CGPoint(x: -B, y: -H))
            path.closeSubpath()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2.4)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        img.unlockFocus()
        return NSCursor(image: img, hotSpot: NSPoint(x: 11, y: 11))
    }
}

// MARK: - Pin Window ViewModel (Dual-Panel Architecture: Image Canvas Panel + Detached Toolbar Panel)

@MainActor
final class PinSessionViewModel: ObservableObject {
    enum ResizeHandle: CaseIterable {
        case topLeft, topCenter, topRight
        case middleLeft, middleRight
        case bottomLeft, bottomCenter, bottomRight

        var cursor: NSCursor {
            switch self {
            case .topCenter, .bottomCenter:
                return DirectionalCursor.northSouth
            case .middleLeft, .middleRight:
                return DirectionalCursor.eastWest
            case .topLeft, .bottomRight:
                return DirectionalCursor.northWestSouthEast
            case .topRight, .bottomLeft:
                return DirectionalCursor.northEastSouthWest
            }
        }
    }

    let id = UUID()
    @Published var baseImage: NSImage
    @Published var pixelatedBaseImage: NSImage?
    @Published var baseSize: NSSize

    let fullScreenCGImage: CGImage?
    let fullScreenFrame: NSRect?
    let captureScaleFactor: CGFloat
    @Published var cropScreenRect: NSRect?
    @Published var hasMovedWindow: Bool = false

    @Published var annotations: [PinAnnotation] = []
    @Published var currentDragPoints: [CGPoint] = []
    @Published var activeTool: PinAnnotation.Tool? = nil {
        didSet {
            if activeTool == .mosaic && pixelatedBaseImage == nil {
                regeneratePixelatedImage()
            }
            updateToolbarPanelPosition()
            hostingPanel?.canvasView?.window?.invalidateCursorRects(for: hostingPanel!.canvasView!)
        }
    }
    @Published var selectedColor: Color = .red {
        didSet {
            hostingPanel?.canvasView?.applyStyleChangeToSelectionOrField(updateColor: true, updatePreset: false, updateBackground: false)
        }
    }
    @Published var strokePreset: StrokePreset = .medium {
        didSet {
            hostingPanel?.canvasView?.applyStyleChangeToSelectionOrField(updateColor: false, updatePreset: true, updateBackground: false)
        }
    }
    @Published var textBackgroundStyle: TextBackgroundStyle = .transparent {
        didSet {
            hostingPanel?.canvasView?.applyStyleChangeToSelectionOrField(updateColor: false, updatePreset: false, updateBackground: true)
            updateToolbarPanelPosition()
        }
    }
    @Published var selectedTextAnnotationID: UUID? = nil
    @Published var scale: CGFloat = 1.0
    @Published var windowOpacity: Double = 1.0
    @Published var showToolbar: Bool = true {
        didSet {
            updateToolbarPanelPosition()
        }
    }
    @Published var toastMessage: String? = nil
    @Published var isPerformingOCR: Bool = false
    @Published var isClosed: Bool = false
    var activeOCRTask: Task<Void, Never>? = nil

    // Option to force pixelation failure in tests to verify fail-closed solid redaction block
    var forceMosaicFallbackForTesting: Bool = false
    @Published var pendingTextNormalizedPos: CGPoint? = nil
    @Published var pendingTextString: String = ""
    var editingExistingTextAnnotationID: UUID? = nil
    var editingOriginalAnnotationSnapshot: PinAnnotation? = nil

    weak var hostingPanel: PinFloatingPanel?
    weak var toolbarPanel: NSPanel?

    /// Exact margin around the image inside `hostingPanel` so 8 resize handles sit comfortably inside the window
    static let canvasMargin: CGFloat = 16

    var currentToolLineWidth: CGFloat {
        guard let tool = activeTool else { return strokePreset.strokeLineWidth }
        switch tool {
        case .mosaic:
            return strokePreset.mosaicBrushWidth
        case .text:
            return strokePreset.textFontSize
        case .rect, .arrow, .pen:
            return strokePreset.strokeLineWidth
        }
    }

    init(
        image: NSImage,
        fullScreenCGImage: CGImage? = nil,
        fullScreenFrame: NSRect? = nil,
        captureScaleFactor: CGFloat = 2.0,
        cropScreenRect: NSRect? = nil
    ) {
        self.baseImage = image
        self.baseSize = image.size
        self.fullScreenCGImage = fullScreenCGImage
        self.fullScreenFrame = fullScreenFrame
        self.captureScaleFactor = captureScaleFactor
        self.cropScreenRect = cropScreenRect
        self.pixelatedBaseImage = nil
    }

    func regeneratePixelatedImage() {
        self.pixelatedBaseImage = MosaicRenderer.createPixelatedImage(from: baseImage)
    }

    var canAdjustCrop: Bool {
        fullScreenCGImage != nil && fullScreenFrame != nil && cropScreenRect != nil && !hasMovedWindow && scale == 1.0 && annotations.isEmpty
    }

    /// Computes the exact frame of `hostingPanel` for a given `imageScreenRect`.
    /// Notice: NO `minPanelWidth`! The image panel is ALWAYS `image.width + 32` by `image.height + 32`!
    static func panelFrameForImageScreenRect(_ imageScreenRect: NSRect) -> NSRect {
        NSRect(
            x: round(imageScreenRect.minX - canvasMargin),
            y: round(imageScreenRect.minY - canvasMargin),
            width: round(imageScreenRect.width + canvasMargin * 2),
            height: round(imageScreenRect.height + canvasMargin * 2)
        )
    }

    /// Positions the detached toolbar panel cleanly below (or above if near screen bottom) the image panel.
    func updateToolbarPanelPosition() {
        guard let imgPanel = hostingPanel, let tbPanel = toolbarPanel else { return }
        if !showToolbar || !imgPanel.isVisible {
            tbPanel.orderOut(nil)
            return
        }

        if let contentView = tbPanel.contentView {
            contentView.layoutSubtreeIfNeeded()
            let fitting = contentView.fittingSize
            if fitting.width > 10 && fitting.height > 10 {
                tbPanel.setContentSize(fitting)
            }
        }

        let imgFrame = imgPanel.frame
        // Actual image screen rect inside imgPanel
        let imageMinX = imgFrame.minX + Self.canvasMargin
        let imageMinY = imgFrame.minY + Self.canvasMargin
        let imageMaxY = imgFrame.maxY - Self.canvasMargin

        let tbSize = tbPanel.frame.size
        let screen = imgPanel.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Align toolbar left with image left, clamped to screen visible bounds
        var tbX = round(imageMinX)
        if tbX + tbSize.width > visible.maxX - 8 {
            tbX = round(visible.maxX - tbSize.width - 8)
        }
        if tbX < visible.minX + 8 {
            tbX = round(visible.minX + 8)
        }

        // Place toolbar 12pt below the bottom border of the image (leaving plenty of room for bottom handles!)
        var tbY = round(imageMinY - tbSize.height - 12)
        if tbY < visible.minY + 6 {
            // If image is at the very bottom of the screen, place toolbar 12pt above the top border of the image
            tbY = round(imageMaxY + 12)
        }

        tbPanel.setFrameOrigin(NSPoint(x: tbX, y: tbY))
        if !tbPanel.isVisible {
            tbPanel.orderFrontRegardless()
        }
    }

    func applyResize(handle: ResizeHandle, startMouse: NSPoint, startCropRect: NSRect, currentMouse: NSPoint) {
        guard let cg = fullScreenCGImage,
              let screenFrame = fullScreenFrame,
              let panel = hostingPanel
        else { return }

        let dx = round(currentMouse.x - startMouse.x)
        let dy = round(currentMouse.y - startMouse.y)

        var newMinX = startCropRect.minX
        var newMaxX = startCropRect.maxX
        var newMinY = startCropRect.minY
        var newMaxY = startCropRect.maxY

        let minCropSize: CGFloat = 24.0
        switch handle {
        case .topLeft:
            newMinX = max(screenFrame.minX, min(startCropRect.minX + dx, startCropRect.maxX - minCropSize))
            newMaxY = min(screenFrame.maxY, max(startCropRect.maxY + dy, startCropRect.minY + minCropSize))
        case .topCenter:
            newMaxY = min(screenFrame.maxY, max(startCropRect.maxY + dy, startCropRect.minY + minCropSize))
        case .topRight:
            newMaxX = min(screenFrame.maxX, max(startCropRect.maxX + dx, startCropRect.minX + minCropSize))
            newMaxY = min(screenFrame.maxY, max(startCropRect.maxY + dy, startCropRect.minY + minCropSize))
        case .middleLeft:
            newMinX = max(screenFrame.minX, min(startCropRect.minX + dx, startCropRect.maxX - minCropSize))
        case .middleRight:
            newMaxX = min(screenFrame.maxX, max(startCropRect.maxX + dx, startCropRect.minX + minCropSize))
        case .bottomLeft:
            newMinX = max(screenFrame.minX, min(startCropRect.minX + dx, startCropRect.maxX - minCropSize))
            newMinY = max(screenFrame.minY, min(startCropRect.minY + dy, startCropRect.maxY - minCropSize))
        case .bottomCenter:
            newMinY = max(screenFrame.minY, min(startCropRect.minY + dy, startCropRect.maxY - minCropSize))
        case .bottomRight:
            newMaxX = min(screenFrame.maxX, max(startCropRect.maxX + dx, startCropRect.minX + minCropSize))
            newMinY = max(screenFrame.minY, min(startCropRect.minY + dy, startCropRect.maxY - minCropSize))
        }

        let rect = NSRect(x: newMinX, y: newMinY, width: newMaxX - newMinX, height: newMaxY - newMinY)
        if rect == self.cropScreenRect { return }

        let localRect = NSRect(
            x: rect.origin.x - screenFrame.origin.x,
            y: rect.origin.y - screenFrame.origin.y,
            width: rect.width,
            height: rect.height
        )

        guard let reCropped = PixPinSelectionView.cropImage(
            cgImage: cg,
            viewHeight: screenFrame.height,
            scaleFactor: captureScaleFactor,
            rect: localRect
        ) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.cropScreenRect = rect
        self.baseImage = reCropped
        self.baseSize = reCropped.size
        let panelFrame = Self.panelFrameForImageScreenRect(rect)
        panel.setFrame(panelFrame, display: true, animate: false)
        panel.canvasView?.needsDisplay = true
        updateToolbarPanelPosition()
        CATransaction.commit()
    }

    func finishResize() {
        if activeTool == .mosaic || pixelatedBaseImage != nil {
            regeneratePixelatedImage()
        }
        if let cv = hostingPanel?.canvasView {
            hostingPanel?.invalidateCursorRects(for: cv)
        }
    }

    func showToast(_ msg: String) {
        toastMessage = msg
        hostingPanel?.canvasView?.needsDisplay = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.toastMessage == msg {
                self.toastMessage = nil
                self.hostingPanel?.canvasView?.needsDisplay = true
            }
        }
    }

    func undo() {
        if !annotations.isEmpty {
            _ = annotations.popLast()
            hostingPanel?.canvasView?.needsDisplay = true
        }
    }

    func cancelPendingTextEditing() {
        let editID = editingExistingTextAnnotationID
        let snapshot = editingOriginalAnnotationSnapshot
        editingExistingTextAnnotationID = nil
        editingOriginalAnnotationSnapshot = nil
        pendingTextNormalizedPos = nil
        pendingTextString = ""
        if let tf = hostingPanel?.canvasView?.textField {
            tf.delegate = nil
            hostingPanel?.canvasView?.clearTextFieldReference()
            tf.removeFromSuperview()
        }
        if let editID = editID {
            if let snapshot = snapshot,
               let idx = annotations.firstIndex(where: { $0.id == editID && $0.tool == .text }) {
                annotations[idx] = snapshot
            }
            selectedTextAnnotationID = editID
        }
        if let cv = hostingPanel?.canvasView {
            cv.window?.invalidateCursorRects(for: cv)
            cv.needsDisplay = true
        }
    }

    func commitPendingText() {
        if let tf = hostingPanel?.canvasView?.textField {
            pendingTextString = tf.stringValue
            tf.delegate = nil
            hostingPanel?.canvasView?.clearTextFieldReference()
            tf.removeFromSuperview()
        }
        guard let pos = pendingTextNormalizedPos else {
            editingExistingTextAnnotationID = nil
            editingOriginalAnnotationSnapshot = nil
            return
        }
        let trimmed = pendingTextString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editID = editingExistingTextAnnotationID,
           let idx = annotations.firstIndex(where: { $0.id == editID && $0.tool == .text }) {
            if trimmed.isEmpty {
                annotations.remove(at: idx)
                selectedTextAnnotationID = nil
            } else {
                annotations[idx].color = NSColor(selectedColor)
                annotations[idx].lineWidth = strokePreset.textFontSize
                annotations[idx].points = [pos]
                annotations[idx].text = trimmed
                annotations[idx].textBackgroundStyle = textBackgroundStyle
                selectedTextAnnotationID = editID
            }
        } else if !trimmed.isEmpty {
            let newItem = PinAnnotation(
                tool: .text,
                color: NSColor(selectedColor),
                lineWidth: strokePreset.textFontSize,
                points: [pos],
                text: trimmed,
                textBackgroundStyle: textBackgroundStyle
            )
            annotations.append(newItem)
            selectedTextAnnotationID = newItem.id
        }
        editingExistingTextAnnotationID = nil
        editingOriginalAnnotationSnapshot = nil
        pendingTextNormalizedPos = nil
        pendingTextString = ""
        if let cv = hostingPanel?.canvasView {
            cv.window?.invalidateCursorRects(for: cv)
            cv.needsDisplay = true
        }
    }

    func renderCompositeImage() -> NSImage? {
        let targetSize = baseSize
        guard targetSize.width >= 1, targetSize.height >= 1 else { return nil }
        let result = NSImage(size: targetSize)
        result.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            result.unlockFocus()
            return nil
        }

        baseImage.draw(in: NSRect(origin: .zero, size: targetSize))

        ctx.saveGState()
        ctx.translateBy(x: 0, y: targetSize.height)
        ctx.scaleBy(x: 1.0, y: -1.0)

        for item in annotations {
            drawAnnotationInCGContext(item, ctx: ctx, size: targetSize)
        }

        ctx.restoreGState()
        result.unlockFocus()
        return result
    }

    func drawAnnotationInCGContext(_ item: PinAnnotation, ctx: CGContext, size: NSSize, scaleMultiplier: CGFloat = 1.0) {
        guard !item.points.isEmpty else { return }
        let pts = item.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        let lw = item.lineWidth * scaleMultiplier

        ctx.saveGState()
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setFillColor(item.color.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch item.tool {
        case .rect:
            guard pts.count >= 2 else { break }
            let rect = CGRect(
                x: min(pts[0].x, pts.last!.x),
                y: min(pts[0].y, pts.last!.y),
                width: abs(pts.last!.x - pts[0].x),
                height: abs(pts.last!.y - pts[0].y)
            )
            ctx.stroke(rect)

        case .arrow:
            guard pts.count >= 2 else { break }
            let start = pts[0]
            let end = pts.last!
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()

            let angle = atan2(end.y - start.y, end.x - start.x)
            let headLength: CGFloat = max(12.0, item.lineWidth * 3.4) * scaleMultiplier
            let arrowAngle: CGFloat = .pi / 6
            let p1 = CGPoint(
                x: end.x - headLength * cos(angle - arrowAngle),
                y: end.y - headLength * sin(angle - arrowAngle)
            )
            let p2 = CGPoint(
                x: end.x - headLength * cos(angle + arrowAngle),
                y: end.y - headLength * sin(angle + arrowAngle)
            )
            ctx.move(to: end)
            ctx.addLine(to: p1)
            ctx.addLine(to: p2)
            ctx.closePath()
            ctx.fillPath()

        case .pen:
            guard pts.count >= 2 else { break }
            ctx.move(to: pts[0])
            for p in pts.dropFirst() {
                ctx.addLine(to: p)
            }
            ctx.strokePath()

        case .mosaic:
            guard pts.count >= 2 else { break }
            let strokePath = CGMutablePath()
            strokePath.move(to: pts[0])
            for p in pts.dropFirst() {
                strokePath.addLine(to: p)
            }
            let strokedMaskPath = strokePath.copy(
                strokingWithWidth: lw,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 10
            )

            ctx.saveGState()
            ctx.addPath(strokedMaskPath)
            ctx.clip()

            let pixelated = forceMosaicFallbackForTesting ? nil : (pixelatedBaseImage ?? MosaicRenderer.createPixelatedImage(from: baseImage))
            if let pixImg = pixelated,
               let tiff = pixImg.tiffRepresentation,
               let bmp = NSBitmapImageRep(data: tiff),
               let cgPix = bmp.cgImage {
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1.0, y: -1.0)
                ctx.interpolationQuality = .none
                ctx.draw(cgPix, in: CGRect(origin: .zero, size: size))
            } else {
                // Fail-closed redaction: if pixelation cannot be produced, paint opaque dark blocks rather than leaving underlying pixels exposed
                ctx.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 1.0).cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            ctx.restoreGState()

        case .text:
            let pos = pts[0]
            let fontSize = max(12.0, item.lineWidth) * scaleMultiplier
            let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: item.color
            ]
            if item.textBackgroundStyle == .transparent {
                let textShadow = NSShadow()
                textShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
                textShadow.shadowBlurRadius = 2.0
                textShadow.shadowOffset = NSSize(width: 0, height: -1)
                attrs[.shadow] = textShadow
            }
            let textSize = (item.text as NSString).size(withAttributes: attrs)
            ctx.saveGState()
            // pos is the TOP-LEFT corner of the text glyph box in top-down coordinates.
            // Flipping Y at (pos.x, pos.y) puts y=0 at pos.y and y<0 downward (towards bottom of image).
            // So the text box occupies x: [0, textSize.width], y: [-textSize.height, 0].
            ctx.translateBy(x: pos.x, y: pos.y)
            ctx.scaleBy(x: 1.0, y: -1.0)
            if let bgFill = item.textBackgroundStyle.fillNSColor {
                let padX: CGFloat = 8.0 * scaleMultiplier
                let padY: CGFloat = 4.0 * scaleMultiplier
                let pillRect = CGRect(
                    x: -padX,
                    y: -textSize.height - padY,
                    width: textSize.width + padX * 2,
                    height: textSize.height + padY * 2
                )
                let radius: CGFloat = 6.0 * scaleMultiplier
                let path = CGPath(roundedRect: pillRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3.5, color: NSColor.black.withAlphaComponent(0.28).cgColor)
                ctx.addPath(path)
                ctx.setFillColor(bgFill.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }
            (item.text as NSString).draw(at: CGPoint(x: 0, y: -textSize.height), withAttributes: attrs)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    @discardableResult
    func copyToClipboard() -> Bool {
        commitPendingText()
        guard let img = renderCompositeImage() else {
            showToast("图像合成失败，已拒绝导出未合成原图")
            return false
        }
        let pboard = ClotheslineManager.shared.pasteboardProvider()
        guard ClipboardHelper.copyImages([img], pasteboard: pboard, tempDir: ClotheslineManager.shared.tempDirOverride) else {
            showToast("复制失败，未能写入剪贴板")
            return false
        }
        showToast("已复制到剪贴板")
        return true
    }

    func clipToClothesline() {
        ClotheslineManager.shared.clipToLine(vm: self)
    }

    func saveToFile() {
        commitPendingText()
        guard let img = renderCompositeImage() else {
            showToast("图像合成失败，无法保存")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        panel.nameFieldStringValue = "ClipLine_\(formatter.string(from: Date())).png"
        panel.level = .screenSaver

        if panel.runModal() == .OK, let url = panel.url {
            if let png = ClipboardHelper.pngData(from: img),
               (try? png.write(to: url, options: .atomic)) != nil {
                showToast("已保存图片")
            } else {
                showToast("保存失败，请检查文件权限")
            }
        }
    }

    private static var strictQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#/?;")
        return set
    }()

    static func encodeQueryValue(_ text: String) -> String? {
        text.addingPercentEncoding(withAllowedCharacters: strictQueryValueAllowed)
    }

    static func buildCustomTranslationURL(template: String, text: String) -> URL? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("{text}"), let encoded = encodeQueryValue(text) else { return nil }
        let urlStr = trimmed.replacingOccurrences(of: "{text}", with: encoded)
        guard let url = URL(string: urlStr),
              let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return nil }
            return url
        }
        if scheme == "http",
           let host = url.host?.lowercased(),
           host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return url
        }
        return nil
    }

    static func buildGoogleTranslateURL(text: String, targetLang: String = "zh-CN") -> URL? {
        var components = URLComponents(string: "https://translate.google.com/")
        components?.queryItems = [
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: targetLang),
            URLQueryItem(name: "text", value: text)
        ]
        return components?.url
    }

    private static var configuredDaemonName: String {
        let envName = ProcessInfo.processInfo.environment["CLIP_LINE_TRANSLATE_DAEMON"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return envName.isEmpty ? "fy-daemon" : envName
    }

    private static func isTranslationDaemonRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", configuredDaemonName]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func hasStoredWebTranslateConsent(for destinationHost: String, defaults: UserDefaults = .standard) -> Bool {
        let key = "ClipLineAllowWebTranslateFallback_\(destinationHost)"
        if defaults.bool(forKey: key) {
            return true
        }
        // Legacy global key is ONLY honored for the default Google Translate destination, never for custom hosts
        if destinationHost == "translate.google.com" && defaults.bool(forKey: "ClipLineAllowWebTranslateFallback") {
            return true
        }
        return false
    }

    private static func confirmWebTranslateIfNeeded(destinationHost: String = "translate.google.com") -> Bool {
        if hasStoredWebTranslateConsent(for: destinationHost) {
            return true
        }
        let key = "ClipLineAllowWebTranslateFallback_\(destinationHost)"
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "即将使用外部翻译服务打开识别文本"
        alert.informativeText = "当前未检测到本地翻译守护进程。是否允许将 OCR 识别到的文字通过默认浏览器发送到 \(destinationHost)？（后续将记住您的选择）"
        alert.addButton(withTitle: "允许并打开网页翻译")
        alert.addButton(withTitle: "仅复制文本，不打开网页")
        if alert.runModal() == .alertFirstButtonReturn {
            UserDefaults.standard.set(true, forKey: key)
            return true
        }
        return false
    }

    private func triggerSmartTranslation(for text: String, pasteboard: NSPasteboard) {
        if Self.isTranslationDaemonRunning() {
            showToast("已识别并唤起翻译")
            for channel in NotificationChannels.translateChannels {
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name(channel),
                    object: nil,
                    userInfo: ["text": text],
                    deliverImmediately: true
                )
            }
            return
        }

        // Fallback 1: Custom URL template via CLIP_LINE_TRANSLATE_URL (only HTTPS or localhost HTTP)
        let customTemplate = ProcessInfo.processInfo.environment["CLIP_LINE_TRANSLATE_URL"]
            ?? UserDefaults.standard.string(forKey: "TranslateURLTemplate")
        if let template = customTemplate,
           let url = Self.buildCustomTranslationURL(template: template, text: text) {
            let host = url.host ?? "custom-translate"
            let isLocal = (host == "localhost" || host == "127.0.0.1" || host == "::1")
            if !isLocal {
                guard Self.confirmWebTranslateIfNeeded(destinationHost: host) else {
                    showToast("OCR 文本已复制（已取消外部网页翻译）")
                    return
                }
            }
            showToast("已复制文本并打开自定义翻译")
            NSWorkspace.shared.open(url)
            return
        }

        // Fallback 2: macOS system Translation service if registered, else Google Translate web fallback (with first-time consent)
        if NSPerformService("Translate", pasteboard) {
            showToast("已唤起 macOS 系统翻译")
            return
        }

        guard Self.confirmWebTranslateIfNeeded(destinationHost: "translate.google.com") else {
            showToast("OCR 文本已复制（已取消网页翻译）")
            return
        }

        if let url = Self.buildGoogleTranslateURL(text: text) {
            showToast("已复制文本并打开网页翻译")
            NSWorkspace.shared.open(url)
        }
    }

    func cancelActiveOCR() {
        activeOCRTask?.cancel()
        activeOCRTask = nil
        isPerformingOCR = false
    }

    func applyOCRResult(_ recognized: String, andTranslate: Bool, expectedChangeCount: Int, pasteboard: NSPasteboard) {
        guard !isClosed else { return }
        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast("未识别到文字")
            return
        }
        guard pasteboard.changeCount == expectedChangeCount else {
            showToast("剪贴板已更新，未覆盖新内容")
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        if andTranslate {
            triggerSmartTranslation(for: trimmed, pasteboard: pasteboard)
        } else {
            showToast("OCR 文本已复制")
        }
    }

    func runOCR(andTranslate: Bool = false) {
        guard !isPerformingOCR, !isClosed else { return }
        commitPendingText()
        guard let composite = renderCompositeImage(),
              let tiff = composite.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage
        else {
            showToast("无法读取图像")
            return
        }

        let targetPasteboard = ClotheslineManager.shared.pasteboardProvider()
        let initialChangeCount = targetPasteboard.changeCount

        isPerformingOCR = true
        showToast(andTranslate ? "正在识别并翻译..." : "正在识别文字...")

        activeOCRTask = Task.detached { [weak self] in
            if Task.isCancelled { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self, !self.isClosed else { return }
                    self.isPerformingOCR = false
                    self.activeOCRTask = nil
                    self.showToast("OCR 识别出错")
                }
                return
            }

            if Task.isCancelled { return }
            let recognized = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            await MainActor.run { [weak self] in
                guard let self = self, !self.isClosed, !Task.isCancelled else { return }
                self.isPerformingOCR = false
                self.activeOCRTask = nil
                self.applyOCRResult(
                    recognized,
                    andTranslate: andTranslate,
                    expectedChangeCount: initialChangeCount,
                    pasteboard: targetPasteboard
                )
            }
        }
    }

    func updateZoom(delta: CGFloat) {
        let newScale = max(0.35, min(3.0, scale + delta))
        scale = newScale
        guard let panel = hostingPanel else { return }
        let newW = round(baseSize.width * newScale + Self.canvasMargin * 2)
        let newH = round(baseSize.height * newScale + Self.canvasMargin * 2)
        var frame = panel.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        frame.size = NSSize(width: newW, height: newH)
        frame.origin = CGPoint(x: round(center.x - frame.width / 2), y: round(center.y - frame.height / 2))
        panel.setFrame(frame, display: true)
        panel.canvasView?.needsDisplay = true
        updateToolbarPanelPosition()
    }
}

// MARK: - Pure AppKit Native PinCanvasNSView (100% Exact Geometry, Native Cursor Rects, Zero SwiftUI Clipping)

/// Custom NSTextField whose entire frame can be dragged to reposition the inline text box before pressing Enter
final class DraggableInlineTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let PinCanvasNSView receive mouse events across the entire text field frame so dragging anywhere on the box moves it,
        // while keeping this field as the window's firstResponder for keyboard typing!
        return nil
    }
}

final class PinCanvasNSView: NSView, NSTextFieldDelegate {
    let vm: PinSessionViewModel
    private var trackingArea: NSTrackingArea?
    private var activeResizeHandle: PinSessionViewModel.ResizeHandle?
    private var resizeStartMouseScreen: NSPoint = .zero
    private var resizeStartCropRect: NSRect = .zero

    private var draggingTextAnnotationIndex: Int?
    private var textDragStartMouseView: NSPoint = .zero
    private var textDragStartNormalizedPos: CGPoint = .zero
    private var textDragDidMove: Bool = false

    private var isDraggingPendingField: Bool = false
    private var pendingDragStartMouseView: NSPoint = .zero
    private var pendingDragStartNormalizedPos: CGPoint = .zero

    private var isDraggingWindow: Bool = false
    private var windowDragStartMouseScreen: NSPoint = .zero
    private var windowDragStartOrigin: NSPoint = .zero

    private(set) var textField: NSTextField?

    init(frame: NSRect, vm: PinSessionViewModel) {
        self.vm = vm
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func clearTextFieldReference() {
        self.textField = nil
    }

    func syncActiveTextStyle() {
        let nsColor = NSColor(vm.selectedColor)
        let font = NSFont.systemFont(ofSize: vm.strokePreset.textFontSize * vm.scale, weight: .bold)
        if let tf = textField {
            tf.textColor = nsColor
            tf.font = font
            // Keep NSTextField layer completely borderless & transparent — background pill and selection dash are drawn cleanly by PinCanvasNSView!
            tf.layer?.backgroundColor = NSColor.clear.cgColor
            tf.layer?.borderWidth = 0
            tf.layer?.borderColor = NSColor.clear.cgColor
            if let editor = window?.fieldEditor(false, for: tf) as? NSTextView {
                editor.textColor = nsColor
                editor.font = font
                editor.insertionPointColor = nsColor
                editor.drawsBackground = false
                var typing = editor.typingAttributes
                typing[.foregroundColor] = nsColor
                typing[.font] = font
                editor.typingAttributes = typing
                if let storage = editor.textStorage, storage.length > 0 {
                    let fullRange = NSRange(location: 0, length: storage.length)
                    storage.addAttributes([.foregroundColor: nsColor, .font: font], range: fullRange)
                }
            }
            updateInlineTextFieldPosition()
        }
        needsDisplay = true
    }

    func applyStyleChangeToSelectionOrField(updateColor: Bool, updatePreset: Bool, updateBackground: Bool) {
        if textField != nil {
            syncActiveTextStyle()
            return
        }
        if let selID = vm.selectedTextAnnotationID,
           let idx = vm.annotations.firstIndex(where: { $0.id == selID && $0.tool == .text }) {
            if updateColor {
                vm.annotations[idx].color = NSColor(vm.selectedColor)
            }
            if updatePreset {
                vm.annotations[idx].lineWidth = vm.strokePreset.textFontSize
            }
            if updateBackground {
                vm.annotations[idx].textBackgroundStyle = vm.textBackgroundStyle
            }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        } else {
            needsDisplay = true
        }
    }

    func pendingFieldHitRect() -> NSRect? {
        guard let tf = textField else { return nil }
        return tf.frame.insetBy(dx: -8, dy: -6)
    }

    func updateInlineTextFieldPosition() {
        guard let tf = textField, let normPt = vm.pendingTextNormalizedPos else { return }
        let imgRect = imageRectInView
        let fontSize = vm.strokePreset.textFontSize * vm.scale
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let sampleStr = vm.pendingTextString.isEmpty ? "输入文字..." : vm.pendingTextString
        let measured = (sampleStr as NSString).size(withAttributes: [.font: font])
        let maxAvailW = max(56, imgRect.width - 4)
        let fieldW = min(maxAvailW, max(92, ceil(measured.width) + 22))
        let textH = max(measured.height, ("Ag" as NSString).size(withAttributes: [.font: font]).height)
        let fieldH: CGFloat = max(24, ceil(textH + 6))
        let padY = max(2, round((fieldH - textH) / 2.0))
        // Align tf so that the glyph top-left inside tf (tf.minX + 2, tf.maxY - padY) matches (rawX, rawY) within imgRect
        let rawX = imgRect.minX + normPt.x * imgRect.width - 2.0
        let rawY = imgRect.maxY - normPt.y * imgRect.height - fieldH + padY
        let minFieldX = imgRect.minX - 2.0
        let maxFieldX = max(minFieldX, imgRect.maxX - fieldW)
        let minFieldY = imgRect.minY
        let maxFieldY = max(minFieldY, imgRect.maxY - fieldH + padY)
        let clampedX = max(minFieldX, min(rawX, maxFieldX))
        let clampedY = max(minFieldY, min(rawY, maxFieldY))
        let actualNormX = max(0, min(1, (clampedX + 2.0 - imgRect.minX) / max(1, imgRect.width)))
        let actualNormY = max(0, min(1, (imgRect.maxY - (clampedY + fieldH - padY)) / max(1, imgRect.height)))
        vm.pendingTextNormalizedPos = CGPoint(x: actualNormX, y: actualNormY)
        tf.frame = NSRect(x: clampedX, y: clampedY, width: fieldW, height: fieldH)
        window?.invalidateCursorRects(for: self)
    }

    /// Bounding rect in view coordinates (bottom-left origin) for a committed `.text` annotation
    func textAnnotationHitRectInView(_ item: PinAnnotation) -> NSRect? {
        guard item.tool == .text, let normPt = item.points.first else { return nil }
        let imgRect = imageRectInView
        let fontSize = max(12.0, item.lineWidth) * vm.scale
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold)
        ]
        let textSize = (item.text as NSString).size(withAttributes: attrs)
        // In drawAnnotationInCGContext, normPt is the TOP-LEFT corner of the text box,
        // so in bottom-left view coordinates the text box spans:
        // x: [vx, vx + textSize.width], y: [vy - textSize.height, vy]
        let vx = imgRect.minX + normPt.x * imgRect.width
        let vy = imgRect.maxY - normPt.y * imgRect.height
        let padX: CGFloat = item.textBackgroundStyle == .transparent ? 8 : 10
        let padY: CGFloat = item.textBackgroundStyle == .transparent ? 6 : 8
        return NSRect(
            x: vx - padX,
            y: vy - textSize.height - padY,
            width: max(32, textSize.width + padX * 2),
            height: max(24, textSize.height + padY * 2)
        )
    }

    func hitTestTextAnnotationIndex(viewPoint: NSPoint) -> Int? {
        for idx in vm.annotations.indices.reversed() {
            let item = vm.annotations[idx]
            if let rect = textAnnotationHitRectInView(item), rect.contains(viewPoint) {
                return idx
            }
        }
        return nil
    }

    /// Exact rect of the displayed image in view coordinates (bottom-left origin)
    var imageRectInView: NSRect {
        let m = PinSessionViewModel.canvasMargin
        return NSRect(
            x: m,
            y: m,
            width: max(1, bounds.width - m * 2),
            height: max(1, bounds.height - m * 2)
        )
    }

    /// The 8 handle positions in view coordinates (bottom-left origin)
    func handlePointsInView() -> [(PinSessionViewModel.ResizeHandle, NSPoint)] {
        let r = imageRectInView
        return [
            (.topLeft, NSPoint(x: r.minX, y: r.maxY)),
            (.topCenter, NSPoint(x: r.midX, y: r.maxY)),
            (.topRight, NSPoint(x: r.maxX, y: r.maxY)),
            (.middleLeft, NSPoint(x: r.minX, y: r.midY)),
            (.middleRight, NSPoint(x: r.maxX, y: r.midY)),
            (.bottomLeft, NSPoint(x: r.minX, y: r.minY)),
            (.bottomCenter, NSPoint(x: r.midX, y: r.minY)),
            (.bottomRight, NSPoint(x: r.maxX, y: r.minY))
        ]
    }

    /// Hit-tests the 8 resize handles AND 4 border edges in view coordinates
    func hitTestResizeHandle(viewPoint: NSPoint) -> PinSessionViewModel.ResizeHandle? {
        guard vm.canAdjustCrop, vm.activeTool == nil else { return nil }

        // 1. Check the 8 handle dots with a generous 15pt radius
        let handleRadius: CGFloat = 15.0
        var bestHandle: PinSessionViewModel.ResizeHandle? = nil
        var bestDist: CGFloat = .greatestFiniteMagnitude

        for (handle, pt) in handlePointsInView() {
            let d = hypot(viewPoint.x - pt.x, viewPoint.y - pt.y)
            if d <= handleRadius && d < bestDist {
                bestDist = d
                bestHandle = handle
            }
        }
        if let found = bestHandle {
            return found
        }

        // 2. Also allow grabbing anywhere along the 4 edges (within 8pt of the border)
        let r = imageRectInView
        let edgeTol: CGFloat = 8.0
        let inX = viewPoint.x >= r.minX - edgeTol && viewPoint.x <= r.maxX + edgeTol
        let inY = viewPoint.y >= r.minY - edgeTol && viewPoint.y <= r.maxY + edgeTol

        if inX && abs(viewPoint.y - r.maxY) <= edgeTol { return .topCenter }
        if inX && abs(viewPoint.y - r.minY) <= edgeTol { return .bottomCenter }
        if inY && abs(viewPoint.x - r.minX) <= edgeTol { return .middleLeft }
        if inY && abs(viewPoint.x - r.maxX) <= edgeTol { return .middleRight }

        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for item in vm.annotations where item.tool == .text {
            if let rect = textAnnotationHitRectInView(item) {
                addCursorRect(rect, cursor: NSCursor.openHand)
            }
        }
        if let fieldRect = pendingFieldHitRect() {
            addCursorRect(fieldRect, cursor: NSCursor.openHand)
        }
        guard vm.canAdjustCrop, vm.activeTool == nil else { return }

        let r = imageRectInView
        // Edge cursor rects
        addCursorRect(NSRect(x: r.minX + 12, y: r.maxY - 7, width: max(0, r.width - 24), height: 14), cursor: DirectionalCursor.northSouth)
        addCursorRect(NSRect(x: r.minX + 12, y: r.minY - 7, width: max(0, r.width - 24), height: 14), cursor: DirectionalCursor.northSouth)
        addCursorRect(NSRect(x: r.minX - 7, y: r.minY + 12, width: 14, height: max(0, r.height - 24)), cursor: DirectionalCursor.eastWest)
        addCursorRect(NSRect(x: r.maxX - 7, y: r.minY + 12, width: 14, height: max(0, r.height - 24)), cursor: DirectionalCursor.eastWest)

        // 8 handle cursor rects (28x28 each, overrides edges at corners/midpoints)
        for (handle, pt) in handlePointsInView() {
            let hRect = NSRect(x: pt.x - 14, y: pt.y - 14, width: 28, height: 28)
            addCursorRect(hRect, cursor: handle.cursor)
        }
    }

    private func updateCursorForViewPoint(_ pt: NSPoint) {
        if let handle = activeResizeHandle {
            handle.cursor.set()
            return
        }
        if draggingTextAnnotationIndex != nil || isDraggingPendingField {
            NSCursor.closedHand.set()
            return
        }
        if let fieldRect = pendingFieldHitRect(), fieldRect.contains(pt) {
            NSCursor.openHand.set()
            return
        }
        if hitTestTextAnnotationIndex(viewPoint: pt) != nil {
            NSCursor.openHand.set()
            return
        }
        if let handle = hitTestResizeHandle(viewPoint: pt) {
            handle.cursor.set()
        } else if vm.activeTool != nil && imageRectInView.contains(pt) {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        updateCursorForViewPoint(pt)
    }

    override func cursorUpdate(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        updateCursorForViewPoint(pt)
    }

    override func mouseExited(with event: NSEvent) {
        if activeResizeHandle == nil {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let pt = convert(event.locationInWindow, from: nil)
        let screenPt = NSEvent.mouseLocation

        // 0. If an inline text field is currently open, touching/dragging ANYWHERE on the text box repositions it BEFORE pressing Enter
        if let fieldRect = pendingFieldHitRect(), fieldRect.contains(pt),
           let normPos = vm.pendingTextNormalizedPos {
            isDraggingPendingField = true
            pendingDragStartMouseView = pt
            pendingDragStartNormalizedPos = normPos
            NSCursor.closedHand.set()
            return
        }

        // 1. Check 8 resize handles & 4 borders first!
        if let handle = hitTestResizeHandle(viewPoint: pt),
           let cropRect = vm.cropScreenRect {
            activeResizeHandle = handle
            resizeStartMouseScreen = screenPt
            resizeStartCropRect = cropRect
            handle.cursor.set()
            return
        }

        let imgRect = imageRectInView
        guard imgRect.contains(pt) else { return }

        // 2. Check if clicking/dragging ANY existing text annotation (works regardless of activeTool!)
        if let initialHitIdx = hitTestTextAnnotationIndex(viewPoint: pt) {
            let clickedAnnotationID = vm.annotations[initialHitIdx].id
            vm.commitPendingText()
            guard let resolvedHitIdx = vm.annotations.firstIndex(where: { $0.id == clickedAnnotationID && $0.tool == .text }) else {
                needsDisplay = true
                return
            }
            let hitItem = vm.annotations[resolvedHitIdx]
            vm.selectedTextAnnotationID = hitItem.id
            if event.clickCount == 2 {
                // Double-click existing text annotation to re-edit in place (non-destructively until committed)
                vm.editingExistingTextAnnotationID = hitItem.id
                vm.editingOriginalAnnotationSnapshot = hitItem
                vm.selectedTextAnnotationID = nil
                vm.selectedColor = Color(nsColor: hitItem.color)
                if let matchedPreset = StrokePreset.allCases.min(by: { abs($0.textFontSize - hitItem.lineWidth) < abs($1.textFontSize - hitItem.lineWidth) }) {
                    vm.strokePreset = matchedPreset
                }
                vm.textBackgroundStyle = hitItem.textBackgroundStyle
                let normPt = hitItem.points.first ?? CGPoint(x: 0.5, y: 0.5)
                showInlineTextField(atNormalized: normPt, in: imgRect, initialText: hitItem.text)
                needsDisplay = true
                return
            }
            draggingTextAnnotationIndex = resolvedHitIdx
            textDragStartMouseView = pt
            textDragStartNormalizedPos = hitItem.points.first ?? .zero
            textDragDidMove = false
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }

        vm.selectedTextAnnotationID = nil

        // 3. If an annotation tool is active, start drawing or placing text
        if let tool = vm.activeTool {
            let nx = max(0, min(1, (pt.x - imgRect.minX) / imgRect.width))
            // Normalized Y is top-down (0 = top, 1 = bottom)
            let ny = max(0, min(1, (imgRect.maxY - pt.y) / imgRect.height))
            let normPt = CGPoint(x: nx, y: ny)

            if tool == .text {
                if textField != nil {
                    // Clicking outside while editing commits current text first without immediately opening a blank box
                    vm.commitPendingText()
                    return
                }
                showInlineTextField(atNormalized: normPt, in: imgRect)
                return
            }

            vm.currentDragPoints = [normPt, normPt]
            needsDisplay = true
            return
        }

        // 4. Otherwise, double-click toggles toolbar, single-drag moves the floating pin window
        if event.clickCount == 2 {
            vm.showToolbar.toggle()
            return
        }

        isDraggingWindow = true
        windowDragStartMouseScreen = screenPt
        windowDragStartOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let screenPt = NSEvent.mouseLocation

        if isDraggingPendingField {
            let pt = convert(event.locationInWindow, from: nil)
            let imgRect = imageRectInView
            let dxNorm = (pt.x - pendingDragStartMouseView.x) / max(1, imgRect.width)
            let dyNorm = (pendingDragStartMouseView.y - pt.y) / max(1, imgRect.height)
            let newX = max(0.0, min(0.95, pendingDragStartNormalizedPos.x + dxNorm))
            let newY = max(0.02, min(0.95, pendingDragStartNormalizedPos.y + dyNorm))
            vm.pendingTextNormalizedPos = CGPoint(x: newX, y: newY)
            updateInlineTextFieldPosition()
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }

        if let handle = activeResizeHandle {
            handle.cursor.set()
            vm.applyResize(
                handle: handle,
                startMouse: resizeStartMouseScreen,
                startCropRect: resizeStartCropRect,
                currentMouse: screenPt
            )
            return
        }

        if let textIdx = draggingTextAnnotationIndex,
           vm.annotations.indices.contains(textIdx) {
            let pt = convert(event.locationInWindow, from: nil)
            let imgRect = imageRectInView
            let dxNorm = (pt.x - textDragStartMouseView.x) / max(1, imgRect.width)
            let dyNorm = (textDragStartMouseView.y - pt.y) / max(1, imgRect.height)
            let newX = max(0.0, min(0.98, textDragStartNormalizedPos.x + dxNorm))
            let newY = max(0.02, min(0.98, textDragStartNormalizedPos.y + dyNorm))
            vm.annotations[textIdx].points = [CGPoint(x: newX, y: newY)]
            textDragDidMove = true
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }

        if let tool = vm.activeTool, tool != .text, !vm.currentDragPoints.isEmpty {
            let pt = convert(event.locationInWindow, from: nil)
            let imgRect = imageRectInView
            let nx = max(0, min(1, (pt.x - imgRect.minX) / imgRect.width))
            let ny = max(0, min(1, (imgRect.maxY - pt.y) / imgRect.height))
            let normPt = CGPoint(x: nx, y: ny)

            if tool == .rect || tool == .arrow {
                vm.currentDragPoints[vm.currentDragPoints.count - 1] = normPt
            } else {
                vm.currentDragPoints.append(normPt)
            }
            needsDisplay = true
            return
        }

        if isDraggingWindow, let win = window {
            let newOrigin = NSPoint(
                x: round(windowDragStartOrigin.x + (screenPt.x - windowDragStartMouseScreen.x)),
                y: round(windowDragStartOrigin.y + (screenPt.y - windowDragStartMouseScreen.y))
            )
            if newOrigin != windowDragStartOrigin {
                vm.hasMovedWindow = true
                needsDisplay = true
            }
            win.setFrameOrigin(newOrigin)
            vm.updateToolbarPanelPosition()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)

        if isDraggingPendingField {
            isDraggingPendingField = false
            window?.invalidateCursorRects(for: self)
            updateCursorForViewPoint(pt)
            return
        }

        if activeResizeHandle != nil {
            activeResizeHandle = nil
            vm.finishResize()
            updateCursorForViewPoint(pt)
            return
        }

        if draggingTextAnnotationIndex != nil {
            draggingTextAnnotationIndex = nil
            textDragDidMove = false
            window?.invalidateCursorRects(for: self)
            updateCursorForViewPoint(pt)
            return
        }

        if let tool = vm.activeTool, tool != .text, !vm.currentDragPoints.isEmpty {
            if vm.currentDragPoints.count >= 2 {
                vm.annotations.append(
                    PinAnnotation(
                        tool: tool,
                        color: NSColor(vm.selectedColor),
                        lineWidth: vm.currentToolLineWidth,
                        points: vm.currentDragPoints
                    )
                )
            }
            vm.currentDragPoints = []
            needsDisplay = true
            return
        }

        if isDraggingWindow {
            isDraggingWindow = false
            window?.invalidateCursorRects(for: self)
            updateCursorForViewPoint(pt)
        }
    }

    func showInlineTextField(atNormalized normPt: CGPoint, in imgRect: NSRect, initialText: String = "") {
        textField?.removeFromSuperview()
        vm.pendingTextNormalizedPos = normPt
        vm.pendingTextString = initialText

        let fontSize = vm.strokePreset.textFontSize * vm.scale
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let sampleStr = initialText.isEmpty ? "输入文字..." : initialText
        let measured = (sampleStr as NSString).size(withAttributes: [.font: font])
        let textH = max(measured.height, ("Ag" as NSString).size(withAttributes: [.font: font]).height)
        let maxAvailW = max(56, imgRect.width - 4)
        let fieldW = min(maxAvailW, max(92, ceil(measured.width) + 22))
        let fieldH: CGFloat = max(24, ceil(textH + 6))
        let padY = max(2, round((fieldH - textH) / 2.0))
        let rawX = imgRect.minX + normPt.x * imgRect.width - 2.0
        let rawY = imgRect.maxY - normPt.y * imgRect.height - fieldH + padY
        let minFieldX = imgRect.minX - 2.0
        let maxFieldX = max(minFieldX, imgRect.maxX - fieldW)
        let minFieldY = imgRect.minY
        let maxFieldY = max(minFieldY, imgRect.maxY - fieldH + padY)
        let clampedX = max(minFieldX, min(rawX, maxFieldX))
        let clampedY = max(minFieldY, min(rawY, maxFieldY))
        // Sync pendingTextNormalizedPos with any clamping so committing matches exact visual field position
        let actualNormX = max(0, min(1, (clampedX + 2.0 - imgRect.minX) / max(1, imgRect.width)))
        let actualNormY = max(0, min(1, (imgRect.maxY - (clampedY + fieldH - padY)) / max(1, imgRect.height)))
        vm.pendingTextNormalizedPos = CGPoint(x: actualNormX, y: actualNormY)

        let tf = DraggableInlineTextField(frame: NSRect(
            x: clampedX,
            y: clampedY,
            width: fieldW,
            height: fieldH
        ))
        tf.stringValue = initialText
        tf.font = font
        tf.textColor = NSColor(vm.selectedColor)
        tf.backgroundColor = .clear
        tf.drawsBackground = false
        tf.isBordered = false
        tf.focusRingType = .none
        tf.wantsLayer = true
        tf.layer?.backgroundColor = NSColor.clear.cgColor
        tf.layer?.borderWidth = 0
        tf.placeholderString = "输入文字..."
        tf.delegate = self
        addSubview(tf)
        window?.makeFirstResponder(tf)
        self.textField = tf
        syncActiveTextStyle()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            vm.cancelPendingTextEditing()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        vm.pendingTextString = tf.stringValue
        updateInlineTextFieldPosition()
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        vm.pendingTextString = tf.stringValue
        tf.removeFromSuperview()
        self.textField = nil
        vm.commitPendingText()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let imgRect = imageRectInView

        ctx.saveGState()
        ctx.setAlpha(CGFloat(vm.windowOpacity))

        // Subtle drop shadow around the image rect
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(imgRect)
        ctx.restoreGState()

        // 1. Draw base screenshot image
        vm.baseImage.draw(in: imgRect)

        // 2. Draw annotations clipped to imgRect (using top-left normalized coordinates)
        ctx.saveGState()
        ctx.clip(to: imgRect)
        ctx.translateBy(x: imgRect.minX, y: imgRect.maxY)
        ctx.scaleBy(x: 1.0, y: -1.0)

        for item in vm.annotations where item.id != vm.editingExistingTextAnnotationID {
            vm.drawAnnotationInCGContext(item, ctx: ctx, size: imgRect.size, scaleMultiplier: vm.scale)
        }
        if let tool = vm.activeTool, !vm.currentDragPoints.isEmpty {
            let temp = PinAnnotation(
                tool: tool,
                color: NSColor(vm.selectedColor),
                lineWidth: vm.currentToolLineWidth,
                points: vm.currentDragPoints
            )
            vm.drawAnnotationInCGContext(temp, ctx: ctx, size: imgRect.size, scaleMultiplier: vm.scale)
        }
        ctx.restoreGState()

        // 2b. Highlight selected committed text annotation OR active inline text field (using neutral system-blue dash, never text color!)
        let accent = NSColor(calibratedRed: 0.15, green: 0.62, blue: 1.0, alpha: 0.95)
        if let tf = textField {
            // If solid pill background is chosen (.black / .white), render the exact rounded pill behind the active text field
            if let bgFill = vm.textBackgroundStyle.fillNSColor {
                let pillRect = tf.frame.insetBy(dx: -4, dy: -1)
                let radius: CGFloat = 6.0 * vm.scale
                let pillPath = CGPath(roundedRect: pillRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3.5, color: NSColor.black.withAlphaComponent(0.28).cgColor)
                ctx.addPath(pillPath)
                ctx.setFillColor(bgFill.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }
            // Subtle neutral selection frame while editing
            let frameRect = tf.frame.insetBy(dx: -4, dy: -1)
            ctx.saveGState()
            ctx.setStrokeColor(accent.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            let dashPath = CGPath(roundedRect: frameRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.addPath(dashPath)
            ctx.strokePath()
            ctx.restoreGState()
        } else if let selID = vm.selectedTextAnnotationID,
                  let selItem = vm.annotations.first(where: { $0.id == selID && $0.tool == .text }),
                  let hitRect = textAnnotationHitRectInView(selItem) {
            ctx.saveGState()
            ctx.setStrokeColor(accent.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            let dashPath = CGPath(roundedRect: hitRect.insetBy(dx: 2, dy: 2), cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.addPath(dashPath)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 3. Draw crisp 4-sided accent border around imageRectInView (never clipped!)
        ctx.saveGState()
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(2.0)
        ctx.stroke(imgRect)
        ctx.restoreGState()

        // 4. Draw 8 resize handle circles when in crop-adjust mode
        if vm.canAdjustCrop && vm.activeTool == nil {
            for (_, pt) in handlePointsInView() {
                let dotRect = CGRect(x: pt.x - 5.0, y: pt.y - 5.0, width: 10.0, height: 10.0)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.5, color: NSColor.black.withAlphaComponent(0.45).cgColor)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: dotRect)
                ctx.restoreGState()

                ctx.saveGState()
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(2.2)
                ctx.strokeEllipse(in: dotRect)
                ctx.restoreGState()
            }
        }

        // 5. Draw Toast or Zoom badge if present
        if let toast = vm.toastMessage {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let sz = (toast as NSString).size(withAttributes: attrs)
            let bRect = CGRect(x: imgRect.minX + 8, y: imgRect.maxY - sz.height - 14, width: sz.width + 16, height: sz.height + 6)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: bRect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            (toast as NSString).draw(at: NSPoint(x: bRect.minX + 8, y: bRect.minY + 3), withAttributes: attrs)
        }

        ctx.restoreGState()
    }
}

// MARK: - Detached Floating Toolbar View (SwiftUI inside its own auto-sizing NSPanel)

struct PinToolbarView: View {
    @ObservedObject var vm: PinSessionViewModel
    var onClose: () -> Void

    private let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .white]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(PinAnnotation.Tool.allCases) { tool in
                Button(action: {
                    vm.commitPendingText()
                    vm.activeTool = (vm.activeTool == tool) ? nil : tool
                    vm.hostingPanel?.canvasView?.needsDisplay = true
                }) {
                    Image(systemName: tool.icon)
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(width: 26, height: 24)
                        .background(vm.activeTool == tool ? Color.accentColor : Color.clear)
                        .foregroundColor(vm.activeTool == tool ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tool.rawValue)
            }

            if vm.activeTool != nil {
                Divider().frame(height: 16)
                HStack(spacing: 4) {
                    ForEach(StrokePreset.allCases) { preset in
                        Button(action: {
                            vm.strokePreset = preset
                        }) {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(vm.strokePreset == preset ? Color.white : Color.primary.opacity(0.75))
                                    .frame(width: preset.dotDiameter, height: preset.dotDiameter)
                                Text(preset.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(vm.strokePreset == preset ? .white : .primary.opacity(0.85))
                            }
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(vm.strokePreset == preset ? Color.accentColor : Color.primary.opacity(0.08))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("粗细：\(preset.rawValue)")
                    }
                }

                if vm.activeTool != .mosaic {
                    Divider().frame(height: 16)
                    HStack(spacing: 5) {
                        ForEach(palette, id: \.self) { c in
                            Button(action: {
                                vm.selectedColor = c
                            }) {
                                Circle()
                                    .fill(c)
                                    .frame(width: 14, height: 14)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white, lineWidth: vm.selectedColor == c ? 2.2 : 0)
                                    )
                                    .frame(width: 20, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }

                if vm.activeTool == .text {
                    Divider().frame(height: 16)
                    HStack(spacing: 4) {
                        ForEach(TextBackgroundStyle.allCases) { bgStyle in
                            Button(action: {
                                vm.textBackgroundStyle = bgStyle
                            }) {
                                HStack(spacing: 3) {
                                    ZStack {
                                        if bgStyle == .transparent {
                                            RoundedRectangle(cornerRadius: 3)
                                                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                                                .foregroundColor(vm.textBackgroundStyle == bgStyle ? .white : .primary.opacity(0.75))
                                                .frame(width: 11, height: 11)
                                        } else {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(bgStyle == .black ? Color.black : Color.white)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .stroke(Color.gray.opacity(0.6), lineWidth: 1)
                                                )
                                                .frame(width: 11, height: 11)
                                        }
                                    }
                                    Text(bgStyle.rawValue)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(vm.textBackgroundStyle == bgStyle ? .white : .primary.opacity(0.85))
                                }
                                .padding(.horizontal, 6)
                                .frame(height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(vm.textBackgroundStyle == bgStyle ? Color.accentColor : Color.primary.opacity(0.08))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("文字背景：\(bgStyle.rawValue)")
                        }
                    }
                }
            }

            Divider().frame(height: 16)

            Button(action: { vm.undo() }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.annotations.isEmpty)
            .help("撤销 (Cmd+Z)")

            Button(action: { vm.runOCR(andTranslate: false) }) {
                HStack(spacing: 3) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 12, weight: .semibold))
                    Text("OCR")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("提取图中文字并复制 (O)")

            Button(action: { vm.runOCR(andTranslate: true) }) {
                HStack(spacing: 3) {
                    Image(systemName: "character.bubble.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("译")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(Color.accentColor.opacity(0.18))
                .foregroundColor(.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("识别图中文字并直接翻译 (T)")

            Button(action: { vm.saveToFile() }) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("保存为 PNG (Cmd+S)")

            Divider().frame(height: 16)

            Button(action: { vm.clipToClothesline() }) {
                HStack(spacing: 3) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 11.5, weight: .bold))
                    Text("夹起")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color(red: 0.78, green: 0.54, blue: 0.28))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("夹到顶部晾衣绳 (快捷键 P / Tab)")

            Button(action: {
                if vm.copyToClipboard() {
                    onClose()
                }
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11.5, weight: .bold))
                    Text("复制")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("复制并关闭 (↵ Enter / Cmd+C)")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭贴图 (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .fixedSize()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
        .padding(6)
    }
}

// MARK: - Detached Floating Toolbar Panel

final class PinToolbarPanel: NSPanel {
    weak var viewModel: PinSessionViewModel?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        if let hosting = viewModel?.hostingPanel {
            hosting.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Native Floating Pin NSPanel

final class PinFloatingPanel: NSPanel {
    var viewModel: PinSessionViewModel?
    var canvasView: PinCanvasNSView?
    var onClosePanel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onClosePanel?()
    }

    override func keyDown(with event: NSEvent) {
        guard let vm = viewModel else {
            super.keyDown(with: event)
            return
        }

        if vm.pendingTextNormalizedPos != nil {
            if event.keyCode == 53 {
                vm.cancelPendingTextEditing()
                return
            }
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 {
            onClosePanel?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if vm.copyToClipboard() {
                onClosePanel?()
            }
            return
        }
        if event.keyCode == 48 || chars == "p" {
            vm.clipToClothesline()
            return
        }
        if event.keyCode == 49 {
            vm.showToolbar.toggle()
            return
        }
        if flags.contains(.command) && chars == "z" {
            vm.undo()
            return
        }
        if flags.contains(.command) && chars == "c" {
            vm.copyToClipboard()
            return
        }
        if flags.contains(.command) && chars == "s" {
            vm.saveToFile()
            return
        }
        if chars == "o" {
            vm.runOCR(andTranslate: false)
            return
        }
        if chars == "t" {
            vm.runOCR(andTranslate: true)
            return
        }
        if chars == "=" || chars == "+" {
            vm.updateZoom(delta: 0.15)
            return
        }
        if chars == "-" {
            vm.updateZoom(delta: -0.15)
            return
        }

        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let vm = viewModel else { return }
        if event.modifierFlags.contains(.option) {
            let delta = Double(event.scrollingDeltaY) * 0.01
            vm.windowOpacity = max(0.25, min(1.0, vm.windowOpacity + delta))
            canvasView?.needsDisplay = true
        }
        // Unmodified two-finger scroll/swipe does NOT resize the pin window (use +/- keys to zoom if needed)
    }
}

// MARK: - App Daemon & Carbon Global HotKey (Ctrl+X / Cmd+Shift+X / Ctrl+Cmd+V)

@MainActor
final class PinDaemonApp: NSObject, NSApplicationDelegate {
    private(set) var activePanels: [UUID: PinFloatingPanel] = [:]
    private(set) var activeToolbars: [UUID: NSPanel] = [:]
    private var localKeyMonitor: Any?
    private let captureController = ScreenCaptureOverlayController()
    private var hotKeyRefCtrlX: EventHotKeyRef?
    private var hotKeyRefCmdShiftX: EventHotKeyRef?
    private var hotKeyRefCmdCtrlV: EventHotKeyRef?
    private var isCapturing: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ClipboardHelper.cleanupStaleTempFiles()
        registerGlobalHotKeys()

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { // Esc
                if self.isCapturing || NSApp.modalWindow != nil {
                    return event
                }
                if let keyPanel = NSApp.keyWindow as? PinFloatingPanel {
                    if keyPanel.viewModel?.pendingTextNormalizedPos != nil {
                        return event
                    }
                    keyPanel.onClosePanel?()
                    return nil
                }
                if let tbPanel = NSApp.keyWindow as? PinToolbarPanel {
                    tbPanel.onEscape?()
                    return nil
                }
            }
            return event
        }

        for channel in NotificationChannels.captureChannels {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(handleExternalCaptureTrigger(_:)),
                name: NSNotification.Name(channel),
                object: nil
            )
        }
    }

    @objc private func handleExternalCaptureTrigger(_ note: Notification) {
        let mode = (note.userInfo?["mode"] as? String) ?? "interactive"
        if mode == "clipboard" {
            pinFromClipboard()
        } else if mode == "interactive" {
            startInteractiveCapture()
        }
    }

    private func registerGlobalHotKeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData, let event = event else { return noErr }
                let daemon = Unmanaged<PinDaemonApp>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                Task { @MainActor in
                    if hkID.id == 1 || hkID.id == 3 {
                        daemon.startInteractiveCapture()
                    } else if hkID.id == 2 {
                        daemon.pinFromClipboard()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            nil
        )
        if handlerStatus != noErr {
            fputs("[ClipLine] Warning: InstallEventHandler failed with OSStatus \(handlerStatus)\n", stderr)
        }

        // Primary screenshot hotkey: Control + X
        let hkID1 = EventHotKeyID(signature: OSType(0x50583031), id: 1)
        let st1 = RegisterEventHotKey(
            UInt32(kVK_ANSI_X),
            UInt32(controlKey),
            hkID1,
            GetApplicationEventTarget(),
            0,
            &hotKeyRefCtrlX
        )
        if st1 != noErr {
            fputs("[ClipLine] Warning: Failed to register Control+X hotkey (OSStatus \(st1))\n", stderr)
        }

        // Pin from clipboard hotkey: Control + Command + V
        let hkID2 = EventHotKeyID(signature: OSType(0x50583032), id: 2)
        let st2 = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | controlKey),
            hkID2,
            GetApplicationEventTarget(),
            0,
            &hotKeyRefCmdCtrlV
        )
        if st2 != noErr {
            fputs("[ClipLine] Warning: Failed to register Control+Command+V hotkey (OSStatus \(st2))\n", stderr)
        }

        // Secondary screenshot hotkey: Command + Shift + X
        let hkID3 = EventHotKeyID(signature: OSType(0x50583033), id: 3)
        let st3 = RegisterEventHotKey(
            UInt32(kVK_ANSI_X),
            UInt32(cmdKey | shiftKey),
            hkID3,
            GetApplicationEventTarget(),
            0,
            &hotKeyRefCmdShiftX
        )
        if st3 != noErr {
            fputs("[ClipLine] Warning: Failed to register Command+Shift+X hotkey (OSStatus \(st3))\n", stderr)
        }
    }

    func startInteractiveCapture() {
        guard !isCapturing else { return }
        isCapturing = true

        captureController.beginCapture { [weak self] result in
            guard let self = self else { return }
            self.isCapturing = false
            if let res = result {
                self.createPinWindow(fromCapture: res)
            }
        }
    }

    func pinFromClipboard() {
        if let img = NSImage(pasteboard: NSPasteboard.general) {
            createPinWindow(with: img)
        }
    }

    func createPinWindow(fromCapture res: CaptureSelectionResult) {
        let vm = PinSessionViewModel(
            image: res.croppedImage,
            fullScreenCGImage: res.fullScreenCGImage,
            fullScreenFrame: res.fullScreenFrame,
            captureScaleFactor: res.scaleFactor,
            cropScreenRect: res.selectedScreenRect
        )
        let panelFrame = PinSessionViewModel.panelFrameForImageScreenRect(res.selectedScreenRect)
        presentPinPanel(vm: vm, frame: panelFrame)
    }

    func createPinWindow(with image: NSImage) {
        let vm = PinSessionViewModel(image: image)
        let mouse = NSEvent.mouseLocation
        let rect = NSRect(
            x: round(mouse.x - image.size.width / 2),
            y: round(mouse.y - image.size.height / 2),
            width: round(image.size.width),
            height: round(image.size.height)
        )
        let panelFrame = PinSessionViewModel.panelFrameForImageScreenRect(rect)
        presentPinPanel(vm: vm, frame: panelFrame)
    }

    func presentPinPanel(vm: PinSessionViewModel, frame: NSRect) {
        let id = vm.id

        // 1. Pure AppKit Image Canvas Panel (1:1 matched to image + 16pt margin)
        let panel = PinFloatingPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.viewModel = vm
        vm.hostingPanel = panel

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let canvas = PinCanvasNSView(frame: NSRect(origin: .zero, size: frame.size), vm: vm)
        canvas.autoresizingMask = [.width, .height]
        panel.contentView = canvas
        panel.canvasView = canvas

        // 2. Detached Auto-Sizing Toolbar Panel (never clips or collides with the image panel!)
        let tbPanel = PinToolbarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 48),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        tbPanel.isFloatingPanel = true
        tbPanel.level = .floating
        tbPanel.animationBehavior = .none
        tbPanel.backgroundColor = .clear
        tbPanel.isOpaque = false
        tbPanel.hasShadow = false
        tbPanel.hidesOnDeactivate = false
        tbPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        tbPanel.viewModel = vm
        vm.toolbarPanel = tbPanel

        let closeClosure: () -> Void = { [weak self, weak vm, weak panel, weak tbPanel] in
            vm?.isClosed = true
            vm?.cancelActiveOCR()
            tbPanel?.orderOut(nil)
            panel?.orderOut(nil)
            self?.activeToolbars.removeValue(forKey: id)
            self?.activePanels.removeValue(forKey: id)
        }
        panel.onClosePanel = closeClosure
        tbPanel.onEscape = closeClosure

        let tbView = PinToolbarView(vm: vm, onClose: closeClosure)
        let tbHosting = NSHostingView(rootView: tbView)
        tbPanel.contentView = tbHosting

        activePanels[id] = panel
        activeToolbars[id] = tbPanel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
        panel.invalidateCursorRects(for: canvas)
        vm.updateToolbarPanelPosition()
    }
}

#if CLIPLINE_TEST
MainActor.assumeIsolated {
    exit(runAllTests())
}
#else
let args = CommandLine.arguments
if args.count >= 2 {
    let arg = args[1]
    if arg == "-h" || arg == "--help" {
        print("""
        Usage: clipline [options]
          (no args)        Start ClipLine background daemon (or trigger capture if already running)
          -i, --capture    Trigger interactive region capture + Pin on screen (Shortcut: Ctrl + X / Cmd + Shift + X)
          -c, --clipboard  Pin current clipboard image on screen (Shortcut: Ctrl + Cmd + V)
          -h, --help       Show this help message
        """)
        exit(0)
    } else if arg == "-c" || arg == "--clipboard" {
        for channel in NotificationChannels.captureChannels {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name(channel),
                object: nil,
                userInfo: ["mode": "clipboard"],
                deliverImmediately: true
            )
        }
        exit(0)
    } else if arg == "-i" || arg == "--capture" {
        for channel in NotificationChannels.captureChannels {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name(channel),
                object: nil,
                userInfo: ["mode": "interactive"],
                deliverImmediately: true
            )
        }
        exit(0)
    }
}

MainActor.assumeIsolated {
    guard SingleInstanceLock.acquireOrNotifyExisting() else {
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = PinDaemonApp()
    app.delegate = delegate
    app.run()
}
#endif
