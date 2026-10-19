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
    private let shortcutStore = ShortcutConfigurationStore(
        defaults: UserDefaults(suiteName: ShortcutConfigurationStore.suiteName)!
    )
    private var shortcutRuntime: ShortcutRuntime?
    private var shortcutSettingsModel: ShortcutSettingsModel?
    private var settingsWindowController: ShortcutSettingsWindowController?
    private var statusItem: NSStatusItem?
    private var hotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]
    private var hotKeyEventHandler: EventHandlerRef?
    private var handledSettingsRequestIDs: Set<String> = []
    private var isCapturing: Bool = false
    var openSettingsOnLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ClipboardHelper.cleanupStaleTempFiles()
        installGlobalHotKeyHandler()

        let runtime = ShortcutRuntime(
            configuration: shortcutStore.load(),
            register: { [weak self] action, binding in
                self?.registerGlobalHotKey(action, binding: binding) ?? OSStatus(paramErr)
            },
            unregister: { [weak self] action in
                self?.unregisterGlobalHotKey(action) ?? OSStatus(paramErr)
            }
        )
        shortcutRuntime = runtime
        let launchFailures = runtime.registerAtLaunch()
        for failure in launchFailures {
            fputs("[ClipLine] Warning: Failed to register \(failure.action.rawValue) hotkey (OSStatus \(failure.status))\n", stderr)
        }
        shortcutSettingsModel = ShortcutSettingsModel(
            store: shortcutStore,
            runtime: runtime,
            launchRegistrationFailures: launchFailures
        )
        setupStatusItem()

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
        for channel in NotificationChannels.settingsChannels {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(handleExternalSettingsRequest(_:)),
                name: NSNotification.Name(channel),
                object: nil
            )
        }
        if openSettingsOnLaunch { showShortcutSettings() }
    }

    @objc private func handleExternalCaptureTrigger(_ note: Notification) {
        let mode = (note.userInfo?["mode"] as? String) ?? "interactive"
        if mode == "clipboard" {
            pinFromClipboard()
        } else if mode == "interactive" {
            startInteractiveCapture()
        }
    }

    @objc private func handleExternalSettingsRequest(_ note: Notification) {
        guard let requestID = note.userInfo?["requestID"] as? String,
              let replyChannel = note.userInfo?["replyChannel"] as? String,
              replyChannel == NotificationChannels.settingsAcknowledgementChannel(for: requestID) else {
            showShortcutSettings()
            return
        }

        if handledSettingsRequestIDs.insert(requestID).inserted {
            showShortcutSettings()
        }
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(replyChannel),
            object: nil,
            userInfo: ["requestID": requestID],
            deliverImmediately: true
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        for action in Array(hotKeyRefs.keys) { _ = unregisterGlobalHotKey(action) }
        if let hotKeyEventHandler {
            RemoveEventHandler(hotKeyEventHandler)
            self.hotKeyEventHandler = nil
        }
        DistributedNotificationCenter.default().removeObserver(self)
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        localKeyMonitor = nil
    }

    private func installGlobalHotKeyHandler() {
        guard hotKeyEventHandler == nil else { return }
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
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard status == noErr, let action = ShortcutAction.from(carbonID: hkID.id) else {
                    return noErr
                }
                Task { @MainActor in daemon.handleGlobalShortcut(action) }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &hotKeyEventHandler
        )
        if handlerStatus != noErr {
            fputs("[ClipLine] Warning: InstallEventHandler failed with OSStatus \(handlerStatus)\n", stderr)
        }
    }

    private func registerGlobalHotKey(_ action: ShortcutAction, binding: ShortcutBinding) -> OSStatus {
        guard hotKeyRefs[action] == nil, hotKeyEventHandler != nil else { return OSStatus(paramErr) }
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x50583030 + action.carbonID),
            id: action.carbonID
        )
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            binding.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &hotKeyRef
        )
        if status == noErr, let hotKeyRef {
            hotKeyRefs[action] = hotKeyRef
        }
        return status
    }

    private func unregisterGlobalHotKey(_ action: ShortcutAction) -> OSStatus {
        guard let hotKeyRef = hotKeyRefs[action] else { return noErr }
        let status = UnregisterEventHotKey(hotKeyRef)
        if status == noErr { hotKeyRefs.removeValue(forKey: action) }
        return status
    }

    private func handleGlobalShortcut(_ action: ShortcutAction) {
        switch action {
        case .capture, .captureSecondary: startInteractiveCapture()
        case .clipboard: pinFromClipboard()
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "ClipLine")
            button.image?.isTemplate = true
            button.setAccessibilityLabel("ClipLine")
        }

        let menu = NSMenu()
        menu.addItem(menuItem(L10n.shortcutMenuCapture, action: #selector(menuCapture(_:))))
        menu.addItem(menuItem(L10n.shortcutMenuClipboard, action: #selector(menuClipboard(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem(L10n.shortcutMenuSettings, action: #selector(menuSettings(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem(L10n.shortcutMenuQuit, action: #selector(menuQuit(_:))))
        item.menu = menu
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuCapture(_ sender: Any?) {
        startInteractiveCapture()
    }

    @objc private func menuClipboard(_ sender: Any?) {
        pinFromClipboard()
    }

    @objc private func menuSettings(_ sender: Any?) {
        showShortcutSettings()
    }

    @objc private func menuQuit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func showShortcutSettings() {
        guard let shortcutSettingsModel else { return }
        if settingsWindowController == nil {
            settingsWindowController = ShortcutSettingsWindowController(model: shortcutSettingsModel)
        }
        settingsWindowController?.show()
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
