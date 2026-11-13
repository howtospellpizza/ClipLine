import AppKit
import Carbon
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
func runSuite6ShortcutSettingsTests(_ t: TestHarness, testPasteboard: NSPasteboard, testTempDirURL: URL) {
    // Suite 6: Editable Global Shortcuts, Safe Registration & Native Settings
    // -------------------------------------------------------------------------
    print("\n🔹 Suite 6: Editable Global Shortcuts & Transactional Registration")
    let shortcutSuiteName = "ClipLineShortcutTests_\(UUID().uuidString)"
    guard let shortcutDefaults = UserDefaults(suiteName: shortcutSuiteName) else {
        t.check(false, "Created isolated UserDefaults suite for shortcut tests")
        return
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
    let isolatedCrosshairStore = CrosshairConfigurationStore(defaults: shortcutDefaults)
    let recordingModel = ShortcutSettingsModel(store: shortcutStore, runtime: recordingRuntime, crosshairStore: isolatedCrosshairStore)
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
    let activationModel = ShortcutSettingsModel(store: shortcutStore, runtime: activationRuntime, crosshairStore: isolatedCrosshairStore)
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
    let failingModel = ShortcutSettingsModel(store: shortcutStore, runtime: failingRuntime, crosshairStore: isolatedCrosshairStore)
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
    let contestedModel = ShortcutSettingsModel(store: shortcutStore, runtime: contestedRuntime, crosshairStore: isolatedCrosshairStore)
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
    contestedModel.setCrosshairStyle(.dotRing)
    contestedModel.setCrosshairColor(.yellow)
    contestedModel.setShowLoupe(false)
    let customCrosshairBeforeFailedRestore = CrosshairConfiguration(style: .dotRing, color: .yellow, showLoupe: false)
    contestedModel.restoreDefaults()
    t.check(
        contestedRuntime.registeredActions == Set([.capture, .captureSecondary]) &&
        contestedModel.errorMessage?.contains("-9878") == true &&
        contestedModel.crosshairConfiguration == customCrosshairBeforeFailedRestore &&
        isolatedCrosshairStore.load() == customCrosshairBeforeFailedRestore,
        "Restore Defaults retries a missing unchanged shortcut, keeps a failed retry visible, and preserves crosshair settings when shortcut registration fails"
    )
    refuseClipboardRestore = false
    contestedModel.retryMissingRegistrationsIfNeeded()
    t.check(
        contestedRuntime.registeredActions.count == 3 && contestedModel.errorMessage == nil,
        "retryMissingRegistrationsIfNeeded recovers missing shortcuts without resetting crosshair settings once conflict resolves"
    )
    contestedModel.restoreDefaults()
    t.check(
        contestedRuntime.registeredActions.count == 3 && contestedModel.errorMessage == nil &&
        shortcutStore.load() == .defaults &&
        contestedModel.crosshairConfiguration == .defaults &&
        isolatedCrosshairStore.load() == .defaults,
        "Restore Defaults retries and atomically recovers shortcuts and crosshair settings once conflict resolves"
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
        crosshairStore: isolatedCrosshairStore,
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
    let lostKeyModel = ShortcutSettingsModel(store: shortcutStore, runtime: lostKeyRuntime, crosshairStore: isolatedCrosshairStore)
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
    let restoreModel = ShortcutSettingsModel(
        store: shortcutStore,
        runtime: restoreRuntime,
        crosshairStore: CrosshairConfigurationStore(defaults: shortcutDefaults)
    )
    restoreModel.setCrosshairStyle(.dotRing)
    restoreModel.setCrosshairColor(.yellow)
    restoreModel.setShowLoupe(false)
    t.check(
        CrosshairConfigurationStore(defaults: shortcutDefaults).load() == CrosshairConfiguration(style: .dotRing, color: .yellow, showLoupe: false),
        "Crosshair settings persist style, color, and loupe visibility in isolated UserDefaults"
    )
    restoreModel.restoreDefaults()
    t.check(
        restoreModel.configuration == .defaults && restoreRuntime.configuration == .defaults &&
        shortcutStore.load() == .defaults && restoredHotKeys.count == 3 &&
        restoreModel.crosshairConfiguration == .defaults &&
        CrosshairConfigurationStore(defaults: shortcutDefaults).load() == .defaults,
        "Restore Defaults atomically applies and persists all factory shortcuts and crosshair settings"
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

}
