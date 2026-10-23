import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class ShortcutSettingsModel: ObservableObject {
    @Published private(set) var configuration: ShortcutConfiguration
    @Published private(set) var crosshairConfiguration: CrosshairConfiguration
    @Published private(set) var recordingAction: ShortcutAction?
    @Published private(set) var errorMessage: String?

    private let store: ShortcutConfigurationStore
    private let crosshairStore: CrosshairConfigurationStore
    private let runtime: ShortcutRuntime

    init(
        store: ShortcutConfigurationStore,
        runtime: ShortcutRuntime,
        crosshairStore: CrosshairConfigurationStore? = nil,
        launchRegistrationFailures: [ShortcutRegistrationFailure] = []
    ) {
        self.store = store
        let resolvedCrosshairStore = crosshairStore ?? CrosshairConfigurationStore()
        self.crosshairStore = resolvedCrosshairStore
        self.runtime = runtime
        self.configuration = runtime.configuration
        self.crosshairConfiguration = resolvedCrosshairStore.load()
        self.errorMessage = launchRegistrationFailures.isEmpty
            ? nil
            : L10n.shortcutRuntimeMessage(
                ShortcutRuntimeError.launchRegistrationFailed(launchRegistrationFailures)
            )
    }

    func setCrosshairStyle(_ style: CrosshairStyle) {
        crosshairConfiguration.style = style
        crosshairStore.save(crosshairConfiguration)
    }

    func setCrosshairColor(_ color: CrosshairColorPreset) {
        crosshairConfiguration.color = color
        crosshairStore.save(crosshairConfiguration)
    }

    func setShowLoupe(_ show: Bool) {
        crosshairConfiguration.showLoupe = show
        crosshairStore.save(crosshairConfiguration)
    }

    @discardableResult
    func beginRecording(_ action: ShortcutAction) -> Bool {
        if let recordingAction { cancelRecording(recordingAction) }
        let allShortcutsRegistered = runtime.registeredActions.count == ShortcutAction.allCases.count
        do {
            try runtime.suspend()
            recordingAction = action
            if allShortcutsRegistered { errorMessage = nil }
            return true
        } catch {
            errorMessage = L10n.shortcutRuntimeMessage(error)
            return false
        }
    }

    func accept(_ binding: ShortcutBinding, for action: ShortcutAction) {
        guard recordingAction == action else { return }
        var candidate = configuration
        candidate.set(binding, for: action)

        do {
            try ShortcutValidator.validate(candidate)
            let data = try store.encodedData(for: candidate)
            try runtime.apply(candidate)
            store.write(data)
            configuration = candidate
            errorMessage = nil
        } catch let validation as ShortcutValidationError {
            errorMessage = L10n.shortcutValidationMessage(validation)
            restoreAfterFailure()
        } catch {
            errorMessage = L10n.shortcutRuntimeMessage(error)
            restoreAfterFailure()
        }
        recordingAction = nil
    }

    func showValidationError(_ error: ShortcutValidationError) {
        errorMessage = L10n.shortcutValidationMessage(error)
    }

    func cancelRecording(_ expectedAction: ShortcutAction? = nil) {
        guard let action = recordingAction,
              expectedAction == nil || expectedAction == action else { return }
        recordingAction = nil
        do {
            try runtime.resume()
            errorMessage = nil
        } catch {
            errorMessage = L10n.shortcutRuntimeMessage(error)
        }
    }

    func restoreDefaults() {
        if let recordingAction { cancelRecording(recordingAction) }
        do {
            let data = try store.encodedData(for: .defaults)
            try runtime.apply(.defaults)
            store.write(data)
            configuration = .defaults
            crosshairConfiguration = .defaults
            crosshairStore.save(.defaults)
            errorMessage = nil
        } catch {
            errorMessage = L10n.shortcutRuntimeMessage(error)
        }
    }

    private func restoreAfterFailure() {
        guard runtime.isSuspended else { return }
        do { try runtime.resume() }
        catch {
            errorMessage = (errorMessage ?? "") + "\n" + L10n.shortcutRuntimeMessage(error)
        }
    }
}

@MainActor
struct ShortcutSettingsView: View {
    @ObservedObject var model: ShortcutSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.shortcutSettingsHeading)
                .font(.title2)
                .fontWeight(.semibold)
            Text(L10n.shortcutSettingsHelp)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                shortcutRow(.capture)
                shortcutRow(.captureSecondary)
                shortcutRow(.clipboard)
            }

            Divider()
                .padding(.vertical, 2)

            Text(L10n.crosshairSectionHeading)
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(L10n.crosshairStyleLabel)
                        .frame(width: 112, alignment: .leading)
                    HStack(spacing: 6) {
                        ForEach(CrosshairStyle.allCases) { style in
                            let selected = model.crosshairConfiguration.style == style
                            Button {
                                model.setCrosshairStyle(style)
                            } label: {
                                Text(L10n.crosshairStyleName(style))
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .frame(height: 26)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(selected ? Color.accentColor : Color.primary.opacity(0.08))
                                    )
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Text(L10n.crosshairColorLabel)
                        .frame(width: 112, alignment: .leading)
                    HStack(spacing: 8) {
                        ForEach(CrosshairColorPreset.allCases) { preset in
                            let selected = model.crosshairConfiguration.color == preset
                            Button {
                                model.setCrosshairColor(preset)
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(swatchColor(for: preset))
                                        .frame(width: 12, height: 12)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.8)
                                        )
                                    Text(L10n.crosshairColorName(preset))
                                        .font(.system(size: 11.5, weight: .medium))
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 25)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.4)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Toggle(
                    L10n.crosshairShowLoupeLabel,
                    isOn: Binding(
                        get: { model.crosshairConfiguration.showLoupe },
                        set: { model.setShowLoupe($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.callout)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            HStack {
                Spacer()
                Button(L10n.shortcutRestoreDefaults) {
                    model.restoreDefaults()
                }
            }
        }
        .padding(22)
        .frame(width: 460, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func swatchColor(for preset: CrosshairColorPreset) -> Color {
        Color(nsColor: preset.nsColor)
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        HStack(spacing: 12) {
            Text(L10n.shortcutName(action))
                .frame(maxWidth: .infinity, alignment: .leading)
            ShortcutRecorderRepresentable(model: model, action: action)
                .frame(width: 156, height: 30)
        }
        .padding(.vertical, 2)
    }
}

@MainActor
private struct ShortcutRecorderRepresentable: NSViewRepresentable {
    @ObservedObject var model: ShortcutSettingsModel
    let action: ShortcutAction

    func makeNSView(context: Context) -> ShortcutRecordingButton {
        let button = ShortcutRecordingButton(title: "", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.focusRingType = .exterior
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: ShortcutRecordingButton, context: Context) {
        let binding = model.configuration.binding(for: action)
        let isRecording = model.recordingAction == action
        button.configure(
            idleTitle: binding.displayString,
            recordingTitle: L10n.shortcutRecordingTitle,
            recording: isRecording,
            accessibilityLabel: L10n.shortcutButtonLabel(action, binding: binding),
            accessibilityValue: isRecording ? L10n.shortcutRecordingAccessibilityValue : binding.displayString,
            accessibilityHelp: L10n.shortcutSettingsHelp
        )
        button.onBeginRecording = { [weak button] in
            guard model.beginRecording(action) else { return false }
            button?.setRecording(true)
            return true
        }
        button.onCaptured = { [weak button] binding in
            button?.setRecording(false)
            model.accept(binding, for: action)
        }
        button.onCancelled = { model.cancelRecording(action) }
        button.onInvalid = { model.showValidationError($0) }
    }
}

@MainActor
final class ShortcutRecordingButton: NSButton {
    var onBeginRecording: (() -> Bool)?
    var onCaptured: ((ShortcutBinding) -> Void)?
    var onCancelled: (() -> Void)?
    var onInvalid: ((ShortcutValidationError) -> Void)?

    private var idleTitle = ""
    private var recordingTitle = ""
    private var isRecording = false
    private var recordingAccessibilityValue = ""

    override var acceptsFirstResponder: Bool { true }

    func configure(
        idleTitle: String,
        recordingTitle: String,
        recording: Bool,
        accessibilityLabel: String,
        accessibilityValue: String,
        accessibilityHelp: String
    ) {
        self.idleTitle = idleTitle
        self.recordingTitle = recordingTitle
        self.recordingAccessibilityValue = accessibilityValue
        self.isRecording = recording
        title = recording ? recordingTitle : idleTitle
        target = self
        action = #selector(activateFromControl(_:))
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(accessibilityValue)
        setAccessibilityHelp(accessibilityHelp)
    }

    func setRecording(_ recording: Bool) {
        isRecording = recording
        title = recording ? recordingTitle : idleTitle
        setAccessibilityValue(recording ? recordingAccessibilityValue : idleTitle)
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            finishRecording()
            return
        }
        super.mouseDown(with: event)
    }

    @objc private func activateFromControl(_ sender: Any?) {
        if isRecording {
            finishRecording()
            return
        }
        guard onBeginRecording?() == true else { return }
        setRecording(true)
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        return handleRecordingEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        _ = handleRecordingEvent(event)
    }

    override func resignFirstResponder() -> Bool {
        let wasRecording = isRecording
        let didResign = super.resignFirstResponder()
        if didResign && wasRecording { finishRecording() }
        return didResign
    }

    @discardableResult
    func handleRecordingEvent(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == UInt16(kVK_Escape) {
            finishRecording()
            window?.makeFirstResponder(nil)
            return true
        }
        if event.keyCode == UInt16(kVK_Tab) {
            let modifiers = carbonModifiers(from: flags)
            if modifiers == 0 || modifiers == UInt32(shiftKey) {
                finishRecording()
                if modifiers == 0 {
                    window?.selectNextKeyView(self)
                } else {
                    window?.selectPreviousKeyView(self)
                }
                return true
            }
        }

        let binding = ShortcutBinding(
            keyCode: event.keyCode,
            carbonModifiers: carbonModifiers(from: flags)
        )
        do {
            try ShortcutValidator.validate(binding)
        } catch let error as ShortcutValidationError {
            onInvalid?(error)
            return true
        } catch {
            return true
        }

        setRecording(false)
        onCaptured?(binding)
        window?.makeFirstResponder(nil)
        return true
    }

    private func finishRecording() {
        guard isRecording else { return }
        setRecording(false)
        onCancelled?()
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}

@MainActor
final class ShortcutSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: ShortcutSettingsModel
    private var settingsHostingView: NSHostingView<ShortcutSettingsView>?
    private var errorObservation: AnyCancellable?

    init(model: ShortcutSettingsModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 342),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = L10n.shortcutWindowTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hostingView = NSHostingView(rootView: ShortcutSettingsView(model: model))
        settingsHostingView = hostingView
        window.contentView = hostingView
        resizeWindowToFitContent()
        errorObservation = model.$errorMessage.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeWindowToFitContent() }
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func show() {
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        model.cancelRecording()
    }

    func windowDidResignKey(_ notification: Notification) {
        model.cancelRecording()
    }

    private func resizeWindowToFitContent() {
        guard let window, let settingsHostingView else { return }
        settingsHostingView.layoutSubtreeIfNeeded()
        let height = max(342, ceil(settingsHostingView.fittingSize.height))
        window.setContentSize(NSSize(width: 460, height: height))
    }
}
