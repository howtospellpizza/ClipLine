import Carbon
import Foundation

enum ShortcutAction: String, CaseIterable, Codable, Hashable {
    case capture
    case captureSecondary = "capture-secondary"
    case clipboard

    var carbonID: UInt32 {
        switch self {
        case .capture: return 1
        case .clipboard: return 2
        case .captureSecondary: return 3
        }
    }

    static func from(carbonID: UInt32) -> ShortcutAction? {
        allCases.first { $0.carbonID == carbonID }
    }
}

struct ShortcutBinding: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let carbonModifiers: UInt32

    var displayString: String {
        var prefix = ""
        if carbonModifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if carbonModifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        if carbonModifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        return prefix + (Self.keyLabels[keyCode] ?? "Key \(keyCode)")
    }

    static let keyLabels: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        64: "F17", 79: "F18", 80: "F19", 90: "F20", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
        111: "F12", 113: "F15", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

struct ShortcutConfiguration: Codable, Equatable {
    var capture: ShortcutBinding
    var captureSecondary: ShortcutBinding
    var clipboard: ShortcutBinding

    static let defaults = ShortcutConfiguration(
        capture: ShortcutBinding(keyCode: UInt16(kVK_ANSI_X), carbonModifiers: UInt32(controlKey)),
        captureSecondary: ShortcutBinding(keyCode: UInt16(kVK_ANSI_X), carbonModifiers: UInt32(cmdKey | shiftKey)),
        clipboard: ShortcutBinding(keyCode: UInt16(kVK_ANSI_V), carbonModifiers: UInt32(controlKey | cmdKey))
    )

    func binding(for action: ShortcutAction) -> ShortcutBinding {
        switch action {
        case .capture: return capture
        case .captureSecondary: return captureSecondary
        case .clipboard: return clipboard
        }
    }

    mutating func set(_ binding: ShortcutBinding, for action: ShortcutAction) {
        switch action {
        case .capture: capture = binding
        case .captureSecondary: captureSecondary = binding
        case .clipboard: clipboard = binding
        }
    }

    func cliJSON() throws -> String {
        try ShortcutValidator.validate(self)
        var entries: [String: ShortcutCLIEntry] = [:]
        for action in ShortcutAction.allCases {
            let binding = binding(for: action)
            entries[action.rawValue] = ShortcutCLIEntry(
                keyCode: binding.keyCode,
                carbonModifiers: binding.carbonModifiers,
                shortcut: binding.displayString
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(entries), as: UTF8.self)
    }
}

private struct ShortcutCLIEntry: Encodable {
    let keyCode: UInt16
    let carbonModifiers: UInt32
    let shortcut: String
}

enum ShortcutValidationError: Error, Equatable {
    case unsupportedModifiers
    case requiredModifier
    case unsupportedKeyCode(UInt16)
    case reservedShortcut
    case duplicate(ShortcutAction, ShortcutAction)
}

enum ShortcutValidator {
    private static let allowedModifiers = UInt32(controlKey | optionKey | cmdKey | shiftKey)
    private static let requiredModifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let screenshotKeyCodes: Set<UInt16> = [20, 21, 23]
    private static let navigationKeyCodes: Set<UInt16> = [48, 49, 51, 53, 123, 124, 125, 126]
    private static let commandOnlyReservedKeyCodes: Set<UInt16> = [
        0, 1, 3, 4, 6, 7, 8, 9, 12, 13, 17, 31, 35, 43, 45, 46, 47, 50
    ]

    static func validate(_ configuration: ShortcutConfiguration) throws {
        var bindings: [ShortcutBinding: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            let binding = configuration.binding(for: action)
            try validate(binding)
            if let previous = bindings[binding] {
                throw ShortcutValidationError.duplicate(previous, action)
            }
            bindings[binding] = action
        }
    }

    static func validate(_ binding: ShortcutBinding) throws {
        guard binding.carbonModifiers & ~allowedModifiers == 0 else {
            throw ShortcutValidationError.unsupportedModifiers
        }
        guard binding.carbonModifiers & requiredModifiers != 0 else {
            throw ShortcutValidationError.requiredModifier
        }
        guard ShortcutBinding.keyLabels[binding.keyCode] != nil else {
            throw ShortcutValidationError.unsupportedKeyCode(binding.keyCode)
        }
        guard !isReserved(binding) else {
            throw ShortcutValidationError.reservedShortcut
        }
    }

    private static func isReserved(_ binding: ShortcutBinding) -> Bool {
        let keyCode = binding.keyCode
        let modifiers = binding.carbonModifiers
        let command = modifiers & UInt32(cmdKey) != 0
        let control = modifiers & UInt32(controlKey) != 0
        let shift = modifiers & UInt32(shiftKey) != 0

        // Protect common app/system navigation and macOS screenshot shortcuts; this is not exhaustive.
        if navigationKeyCodes.contains(keyCode) { return true }
        if modifiers == UInt32(cmdKey) && commandOnlyReservedKeyCodes.contains(keyCode) { return true }
        if modifiers == UInt32(cmdKey | shiftKey) && keyCode == UInt16(kVK_ANSI_Q) { return true }
        if command && shift && screenshotKeyCodes.contains(keyCode) { return true }
        if control && [123, 124, 125, 126].contains(keyCode) { return true }
        return false
    }
}

struct ShortcutConfigurationStore {
    static let suiteName = "io.github.clipline"
    static let key = "GlobalShortcuts.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> ShortcutConfiguration {
        guard let data = defaults.data(forKey: Self.key),
              let configuration = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data),
              (try? ShortcutValidator.validate(configuration)) != nil else {
            return .defaults
        }
        return configuration
    }

    func encodedData(for configuration: ShortcutConfiguration) throws -> Data {
        try ShortcutValidator.validate(configuration)
        return try JSONEncoder().encode(configuration)
    }

    func write(_ data: Data) {
        defaults.set(data, forKey: Self.key)
    }

    func save(_ configuration: ShortcutConfiguration) throws {
        write(try encodedData(for: configuration))
    }
}

struct ShortcutRegistrationFailure: Equatable {
    let action: ShortcutAction
    let status: Int32
}

enum ShortcutRuntimeError: Error, Equatable {
    case launchRegistrationFailed([ShortcutRegistrationFailure])
    case validationFailed(ShortcutValidationError, restorationFailures: [ShortcutRegistrationFailure])
    case unregisterFailed(ShortcutAction, status: Int32, rollbackFailures: [ShortcutRegistrationFailure])
    case registrationFailed(ShortcutAction, status: Int32, rollbackFailures: [ShortcutRegistrationFailure])
    case restorationFailed([ShortcutRegistrationFailure])
}

@MainActor
final class ShortcutRuntime {
    typealias Register = (ShortcutAction, ShortcutBinding) -> Int32
    typealias Unregister = (ShortcutAction) -> Int32

    private(set) var configuration: ShortcutConfiguration
    private(set) var registeredActions: Set<ShortcutAction> = []
    private(set) var isSuspended = false
    private let registerHotKey: Register
    private let unregisterHotKey: Unregister

    init(configuration: ShortcutConfiguration, register: @escaping Register, unregister: @escaping Unregister) {
        self.configuration = configuration
        self.registerHotKey = register
        self.unregisterHotKey = unregister
    }

    func registerAtLaunch() -> [ShortcutRegistrationFailure] {
        var failures: [ShortcutRegistrationFailure] = []
        for action in ShortcutAction.allCases {
            let status = register(action, configuration.binding(for: action))
            if status != noErr { failures.append(.init(action: action, status: status)) }
        }
        return failures
    }

    func suspend() throws {
        guard !isSuspended else { return }
        let previous = registeredActions

        for action in ShortcutAction.allCases where previous.contains(action) {
            let status = unregister(action)
            guard status == noErr else {
                let rollback = restore(previous: Set(ShortcutAction.allCases), using: configuration)
                throw ShortcutRuntimeError.unregisterFailed(action, status: status, rollbackFailures: rollback)
            }
        }

        isSuspended = true
    }

    func resume() throws {
        guard isSuspended else { return }
        let failures = restore(previous: Set(ShortcutAction.allCases), using: configuration)
        isSuspended = false
        if !failures.isEmpty { throw ShortcutRuntimeError.restorationFailed(failures) }
    }

    func apply(_ candidate: ShortcutConfiguration) throws {
        do {
            try ShortcutValidator.validate(candidate)
        } catch let validation as ShortcutValidationError {
            var restorationFailures: [ShortcutRegistrationFailure] = []
            if isSuspended {
                do { try resume() }
                catch let error as ShortcutRuntimeError {
                    restorationFailures = Self.failures(in: error)
                }
            }
            throw ShortcutRuntimeError.validationFailed(validation, restorationFailures: restorationFailures)
        }

        let oldConfiguration = configuration
        let changed = Set(ShortcutAction.allCases.filter {
            oldConfiguration.binding(for: $0) != candidate.binding(for: $0)
        })
        if changed.isEmpty {
            if isSuspended { try resume() }
            else {
                let failures = restore(previous: Set(ShortcutAction.allCases), using: configuration)
                if !failures.isEmpty { throw ShortcutRuntimeError.restorationFailed(failures) }
            }
            return
        }

        if isSuspended {
            try applyWhileSuspended(candidate, old: oldConfiguration)
        } else {
            try applyWhileActive(candidate, changed: changed, old: oldConfiguration)
        }
    }

    private func applyWhileSuspended(
        _ candidate: ShortcutConfiguration,
        old: ShortcutConfiguration
    ) throws {
        var installed: Set<ShortcutAction> = []

        for action in ShortcutAction.allCases {
            let status = register(action, candidate.binding(for: action))
            guard status == noErr else {
                let cleanup = unregister(installed)
                let restoration = restore(previous: Set(ShortcutAction.allCases), using: old)
                isSuspended = false
                throw ShortcutRuntimeError.registrationFailed(
                    action,
                    status: status,
                    rollbackFailures: cleanup + restoration
                )
            }
            installed.insert(action)
        }

        configuration = candidate
        isSuspended = false
    }

    private func applyWhileActive(
        _ candidate: ShortcutConfiguration,
        changed: Set<ShortcutAction>,
        old: ShortcutConfiguration
    ) throws {
        let oldActive = registeredActions.intersection(changed)

        for action in ShortcutAction.allCases where oldActive.contains(action) {
            let status = unregister(action)
            guard status == noErr else {
                let rollback = restore(previous: Set(ShortcutAction.allCases), using: old)
                throw ShortcutRuntimeError.unregisterFailed(action, status: status, rollbackFailures: rollback)
            }
        }

        let actionsToRegister = changed.union(Set(ShortcutAction.allCases).subtracting(registeredActions))
        var installed: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases where actionsToRegister.contains(action) {
            let status = register(action, candidate.binding(for: action))
            guard status == noErr else {
                let cleanup = unregister(installed)
                let restoration = restore(previous: Set(ShortcutAction.allCases), using: old)
                throw ShortcutRuntimeError.registrationFailed(
                    action,
                    status: status,
                    rollbackFailures: cleanup + restoration
                )
            }
            installed.insert(action)
        }

        configuration = candidate
    }

    private func register(_ action: ShortcutAction, _ binding: ShortcutBinding) -> Int32 {
        let status = registerHotKey(action, binding)
        if status == noErr { registeredActions.insert(action) }
        return status
    }

    private func unregister(_ action: ShortcutAction) -> Int32 {
        let status = unregisterHotKey(action)
        if status == noErr { registeredActions.remove(action) }
        return status
    }

    private func unregister(_ actions: Set<ShortcutAction>) -> [ShortcutRegistrationFailure] {
        var failures: [ShortcutRegistrationFailure] = []
        for action in ShortcutAction.allCases.reversed() where actions.contains(action) {
            let status = unregister(action)
            if status != noErr { failures.append(.init(action: action, status: status)) }
        }
        return failures
    }

    private func restore(
        previous actions: Set<ShortcutAction>,
        using configuration: ShortcutConfiguration
    ) -> [ShortcutRegistrationFailure] {
        var failures: [ShortcutRegistrationFailure] = []
        for action in ShortcutAction.allCases where actions.contains(action) && !registeredActions.contains(action) {
            let status = register(action, configuration.binding(for: action))
            if status != noErr { failures.append(.init(action: action, status: status)) }
        }
        return failures
    }

    private static func failures(in error: ShortcutRuntimeError) -> [ShortcutRegistrationFailure] {
        switch error {
        case .launchRegistrationFailed(let failures): return failures
        case .validationFailed(_, let failures): return failures
        case .unregisterFailed(_, _, let failures), .registrationFailed(_, _, let failures): return failures
        case .restorationFailed(let failures): return failures
        }
    }
}
