import AppKit
import Carbon
import Foundation
import SwiftUI

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
