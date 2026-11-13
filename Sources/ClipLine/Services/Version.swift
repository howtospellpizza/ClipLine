import Foundation

enum ClipLineVersion {
    /// Single source of truth injected from root `VERSION` file at build time via `Makefile`,
    /// with a safe compile-time fallback when built directly via `swift build`.
    static let current: String = {
        let raw = ClipLineGeneratedBuildVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "0.2.0" : raw
    }()

    static var architectureTag: String {
        #if arch(arm64)
        return "arm64-apple-macosx"
        #elseif arch(x86_64)
        return "x86_64-apple-macosx"
        #else
        return "unknown-apple-macosx"
        #endif
    }

    static var cliBanner: String {
        "ClipLine \(current) (\(architectureTag))"
    }
}
