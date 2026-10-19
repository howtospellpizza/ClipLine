import Darwin
import Foundation

struct ClipLineUpdateCommandResult {
    let status: Int32
    let output: String
}

protocol ClipLineUpdateCommandRunning {
    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?
    ) throws -> ClipLineUpdateCommandResult

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) throws
}

struct SystemClipLineUpdateCommandRunner: ClipLineUpdateCommandRunning {
    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?
    ) throws -> ClipLineUpdateCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ClipLineUpdateCommandResult(
            status: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self)
        )
    }

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

struct ClipLineUpdateContext {
    let executableURL: URL
    let temporaryDirectoryURL: URL
    let lockFileURL: URL
    let userID: uid_t
    let effectiveUserID: uid_t
    let processIdentifier: pid_t
    let environment: [String: String]

    static func current(executableURL: URL) -> ClipLineUpdateContext {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return ClipLineUpdateContext(
            executableURL: executableURL,
            temporaryDirectoryURL: fileManager.temporaryDirectory,
            lockFileURL: applicationSupport
                .appendingPathComponent("ClipLine", isDirectory: true)
                .appendingPathComponent("clipline_daemon.lock"),
            userID: getuid(),
            effectiveUserID: geteuid(),
            processIdentifier: getpid(),
            environment: ProcessInfo.processInfo.environment
        )
    }
}

struct ClipLineUpdateReport {
    let commit: String
    let restartMessage: String
}

enum ClipLineUpdateError: LocalizedError {
    case requiresLoggedInUser
    case invalidExecutablePath(String)
    case invalidExecutable(String)
    case executableNotOwned(String)
    case destinationNotWritable(String)
    case commandStartFailed(String, String)
    case commandFailed(String, Int32, String)
    case invalidCommit(String)
    case missingBuildArtifact(String)
    case signatureInspectionFailed(String)
    case certificateSigningFailed(String, String)
    case adHocSigningFailed(String)
    case stageFailed(String)
    case replacementFailed(String)
    case restartFailed(String)

    var errorDescription: String? {
        switch self {
        case .requiresLoggedInUser:
            return "Run `clipline --update` as the logged-in user, not under sudo or root."
        case .invalidExecutablePath(let path):
            return "Refusing to update \(path): invoke the user-installed `clipline` executable."
        case .invalidExecutable(let path):
            return "The invoking executable at \(path) is missing, non-executable, or not a regular file."
        case .executableNotOwned(let path):
            return "Refusing to replace \(path) because it is not owned by the current user."
        case .destinationNotWritable(let path):
            return "The install directory is not writable by the current user: \(path)."
        case .commandStartFailed(let name, let detail):
            return "Could not start \(name): \(detail)"
        case .commandFailed(let name, let status, let detail):
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return "\(name) failed with exit status \(status)\(suffix). The installed binary was left unchanged."
        case .invalidCommit(let value):
            return "Git returned an invalid commit ID: \(value)"
        case .missingBuildArtifact(let path):
            return "The build did not produce an executable at \(path). The installed binary was left unchanged."
        case .signatureInspectionFailed(let detail):
            return "Could not safely identify the installed code signature: \(detail). The installed binary was left unchanged."
        case .certificateSigningFailed(let identity, let detail):
            return "Could not reuse signing identity `\(identity)`. Install its matching certificate and private key in your login keychain, then retry. The installed binary was left unchanged. Details: \(detail)"
        case .adHocSigningFailed(let detail):
            return "Could not sign the staged executable with an ad-hoc signature: \(detail). The installed binary was left unchanged."
        case .stageFailed(let detail):
            return "Could not stage the update beside the installed executable: \(detail). The installed binary was left unchanged."
        case .replacementFailed(let detail):
            return "Could not atomically replace the installed executable: \(detail). The installed binary was left unchanged."
        case .restartFailed(let detail):
            return detail
        }
    }
}

struct ClipLineUpdater {
    static let officialRepositoryURL = "https://github.com/howtospellpizza/ClipLine.git"
    static let sshRepositoryURL = "git@github.com:howtospellpizza/ClipLine.git"
    static let updateNotice = "This contacts GitHub to download public source; ClipLine does not upload screenshots, clipboard contents, or preferences. Save active pins before updating because restarting the daemon can discard them."

    private static let git = URL(fileURLWithPath: "/usr/bin/git")
    private static let make = URL(fileURLWithPath: "/usr/bin/make")
    private static let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
    private static let launchctl = URL(fileURLWithPath: "/bin/launchctl")
    private static let ps = URL(fileURLWithPath: "/bin/ps")
    private static let kill = URL(fileURLWithPath: "/bin/kill")
    private static let launchAgentLabel = "io.github.clipline.daemon"

    private let context: ClipLineUpdateContext
    private let commandRunner: any ClipLineUpdateCommandRunning
    private let fileManager: FileManager

    init(
        context: ClipLineUpdateContext,
        commandRunner: any ClipLineUpdateCommandRunning = SystemClipLineUpdateCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.context = context
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    static func currentExecutableURL() throws -> URL {
        var bufferSize: UInt32 = 1024
        while true {
            var buffer = [CChar](repeating: 0, count: Int(bufferSize))
            let result = buffer.withUnsafeMutableBufferPointer { pointer in
                _NSGetExecutablePath(pointer.baseAddress!, &bufferSize)
            }
            guard result == 0 else {
                guard bufferSize > buffer.count else {
                    throw ClipLineUpdateError.invalidExecutablePath("the current process path could not be resolved")
                }
                continue
            }
            return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
        }
    }

    func update() throws -> ClipLineUpdateReport {
        guard context.effectiveUserID != 0 else {
            throw ClipLineUpdateError.requiresLoggedInUser
        }
        let targetURL = context.executableURL.standardizedFileURL.resolvingSymlinksInPath()
        let targetAttributes = try validateTarget(targetURL)
        let restartPlan = prepareRestartPlan(for: targetURL)

        let updateDirectory = context.temporaryDirectoryURL
            .appendingPathComponent("ClipLine-update-\(UUID().uuidString)", isDirectory: true)
        let checkoutURL = updateDirectory.appendingPathComponent("checkout", isDirectory: true)
        do {
            try fileManager.createDirectory(at: updateDirectory, withIntermediateDirectories: false)
        } catch {
            throw ClipLineUpdateError.stageFailed(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: updateDirectory) }

        try cloneOfficialRepository(to: checkoutURL)

        let commitOutput = try runRequired(
            Self.git,
            arguments: ["rev-parse", "--verify", "HEAD"],
            currentDirectory: checkoutURL,
            name: "git rev-parse"
        )
        let commit = commitOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFullCommitID(commit) else {
            throw ClipLineUpdateError.invalidCommit(commit)
        }

        _ = try runRequired(Self.make, arguments: ["build"], currentDirectory: checkoutURL, name: "make build")
        let builtURL = checkoutURL.appendingPathComponent("build/clipline")
        guard fileManager.isExecutableFile(atPath: builtURL.path),
              let builtAttributes = try? fileManager.attributesOfItem(atPath: builtURL.path),
              builtAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw ClipLineUpdateError.missingBuildArtifact(builtURL.path)
        }

        let signature = try inspectSignature(of: targetURL)
        let stageURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".clipline-update-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: stageURL) }

        do {
            try fileManager.copyItem(at: builtURL, to: stageURL)
            let mode = (targetAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: stageURL.path)
        } catch {
            throw ClipLineUpdateError.stageFailed(error.localizedDescription)
        }

        try sign(stageURL, using: signature)
        let verifyResult = try run(Self.codesign, arguments: ["--verify", "--strict", "--verbose=2", stageURL.path])
        guard verifyResult.status == 0 else {
            throw ClipLineUpdateError.signatureInspectionFailed(
                "the staged signature did not validate: \(summarize(verifyResult.output))"
            )
        }
        if let requirement = signature.designatedRequirement {
            let drVerifyResult = try run(Self.codesign, arguments: ["--verify", "-R=\(requirement)", stageURL.path])
            guard drVerifyResult.status == 0 else {
                throw ClipLineUpdateError.signatureInspectionFailed(
                    "the staged signature did not match the existing designated requirement: \(summarize(drVerifyResult.output))"
                )
            }
        }

        let renameStatus = stageURL.path.withCString { source in
            targetURL.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameStatus == 0 else {
            throw ClipLineUpdateError.replacementFailed(String(cString: strerror(errno)))
        }

        return ClipLineUpdateReport(
            commit: commit,
            restartMessage: try restart(restartPlan, executableURL: targetURL)
        )
    }

    private func validateTarget(_ targetURL: URL) throws -> [FileAttributeKey: Any] {
        let invokedName = context.executableURL.lastPathComponent
        guard invokedName == "clipline" || targetURL.lastPathComponent == "clipline" else {
            throw ClipLineUpdateError.invalidExecutablePath(context.executableURL.path)
        }
        guard fileManager.isExecutableFile(atPath: targetURL.path),
              let attributes = try? fileManager.attributesOfItem(atPath: targetURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ClipLineUpdateError.invalidExecutable(targetURL.path)
        }
        guard let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
              ownerID == context.userID else {
            throw ClipLineUpdateError.executableNotOwned(targetURL.path)
        }
        let parentURL = targetURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parentURL.path) else {
            throw ClipLineUpdateError.destinationNotWritable(parentURL.path)
        }
        return attributes
    }

    private func inspectSignature(of executableURL: URL) throws -> CodeSignature {
        let result = try run(Self.codesign, arguments: ["--display", "--verbose=4", executableURL.path])
        if result.status != 0 {
            if result.output.localizedCaseInsensitiveContains("code object is not signed at all") {
                return CodeSignature(identifier: "io.github.clipline", mode: .adHoc, designatedRequirement: nil)
            }
            throw ClipLineUpdateError.signatureInspectionFailed(summarize(result.output))
        }

        let lines = result.output.split(whereSeparator: \.isNewline).map(String.init)
        guard let identifier = value(after: "Identifier=", in: lines), !identifier.isEmpty else {
            throw ClipLineUpdateError.signatureInspectionFailed("the installed identifier is missing")
        }
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Signature=adhoc" }) {
            return CodeSignature(identifier: identifier, mode: .adHoc, designatedRequirement: nil)
        }
        if let identity = value(after: "Authority=", in: lines), !identity.isEmpty {
            let drResult = try? run(Self.codesign, arguments: ["-d", "-r-", executableURL.path])
            let requirement = drResult.flatMap { res -> String? in
                guard res.status == 0 else { return nil }
                return res.output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                    guard let range = line.range(of: "designated =>") else { return nil }
                    let expr = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    return expr.isEmpty ? nil : expr
                }.first
            }
            return CodeSignature(identifier: identifier, mode: .certificate(identity), designatedRequirement: requirement)
        }
        throw ClipLineUpdateError.signatureInspectionFailed("the signature is neither ad-hoc nor certificate-signed")
    }

    private func sign(_ executableURL: URL, using signature: CodeSignature) throws {
        let identity: String
        switch signature.mode {
        case .adHoc:
            identity = "-"
        case .certificate(let certificateIdentity):
            identity = certificateIdentity
        }
        let arguments = [
            "--force", "--sign", identity, "--identifier", signature.identifier,
            "--timestamp=none", executableURL.path
        ]

        let result: ClipLineUpdateCommandResult
        do {
            result = try commandRunner.run(
                executable: Self.codesign,
                arguments: arguments,
                currentDirectory: nil
            )
        } catch {
            try throwSigningFailure(signature.mode, detail: error.localizedDescription)
        }
        guard result.status == 0 else {
            try throwSigningFailure(signature.mode, detail: summarize(result.output))
        }
    }

    private func throwSigningFailure(_ mode: SigningMode, detail: String) throws -> Never {
        switch mode {
        case .adHoc:
            throw ClipLineUpdateError.adHocSigningFailed(detail)
        case .certificate(let identity):
            throw ClipLineUpdateError.certificateSigningFailed(identity, detail)
        }
    }

    private func prepareRestartPlan(for executableURL: URL) -> RestartPlan {
        let service = "gui/\(context.userID)/\(Self.launchAgentLabel)"
        if let result = try? commandRunner.run(
            executable: Self.launchctl,
            arguments: ["print", service],
            currentDirectory: nil
        ), result.status == 0, launchAgentTargets(result.output, executableURL: executableURL) {
            if launchAgentPID(result.output) == context.processIdentifier {
                return .manual("The updater is the registered LaunchAgent process; it was not terminated. Restart it after this command exits.")
            }
            return .launchAgent(service)
        }

        guard let pid = daemonPID(), pid != context.processIdentifier,
              processExecutablePath(pid) == executableURL.path,
              let commandLine = processCommandLine(pid), !commandLine.contains("--update") else {
            return .none
        }
        return .daemon(pid)
    }

    private func restart(_ plan: RestartPlan, executableURL: URL) throws -> String {
        switch plan {
        case .none:
            return "No matching running daemon or LaunchAgent was restarted."
        case .manual(let message):
            return message
        case .launchAgent(let service):
            do {
                let result = try commandRunner.run(
                    executable: Self.launchctl,
                    arguments: ["kickstart", "-k", service],
                    currentDirectory: nil
                )
                guard result.status == 0 else {
                    let detail = summarize(result.output)
                    throw ClipLineUpdateError.restartFailed(
                        "The update is installed, but the existing LaunchAgent could not be restarted. Run `launchctl kickstart -k \(service)` manually. \(detail)"
                    )
                }
                return "Restarted the existing matching LaunchAgent; no job was created."
            } catch let error as ClipLineUpdateError {
                throw error
            } catch {
                throw ClipLineUpdateError.restartFailed(
                    "The update is installed, but the existing LaunchAgent could not be restarted. Restart it manually after this command exits. \(error.localizedDescription)"
                )
            }
        case .daemon(let pid):
            guard pid != context.processIdentifier,
                  processExecutablePath(pid) == executableURL.path else {
                return "The same-path daemon exited during the update; it was not restarted."
            }
            do {
                let stop = try commandRunner.run(
                    executable: Self.kill,
                    arguments: ["-TERM", String(pid)],
                    currentDirectory: nil
                )
                if stop.status != 0, processExecutablePath(pid) == executableURL.path {
                    throw ClipLineUpdateError.restartFailed(
                        "The update is installed, but the same-path daemon could not be stopped. Restart it manually. \(summarize(stop.output))"
                    )
                }
            } catch let error as ClipLineUpdateError {
                throw error
            } catch {
                throw ClipLineUpdateError.restartFailed(
                    "The update is installed, but the same-path daemon could not be stopped. Restart it manually. \(error.localizedDescription)"
                )
            }

            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, processExecutablePath(pid) == executableURL.path {
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard processExecutablePath(pid) != executableURL.path else {
                throw ClipLineUpdateError.restartFailed(
                    "The update is installed, but the old daemon did not stop. Restart it manually after it exits."
                )
            }
            do {
                try commandRunner.launch(
                    executable: executableURL,
                    arguments: [],
                    environment: context.environment,
                    currentDirectory: nil
                )
                return "Restarted the same-path daemon with the updater's current environment; variables unique to the old process cannot be recovered."
            } catch {
                throw ClipLineUpdateError.restartFailed(
                    "The update is installed, but the daemon could not be restarted. Launch `\(executableURL.path)` manually. \(error.localizedDescription)"
                )
            }
        }
    }

    private func daemonPID() -> pid_t? {
        guard let contents = try? String(contentsOf: context.lockFileURL, encoding: .utf8),
              let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            return nil
        }
        return pid
    }

    private func processExecutablePath(_ pid: pid_t) -> String? {
        guard let result = try? commandRunner.run(
            executable: Self.ps,
            arguments: ["-p", String(pid), "-o", "comm="],
            currentDirectory: nil
        ), result.status == 0 else {
            return nil
        }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func processCommandLine(_ pid: pid_t) -> String? {
        guard let result = try? commandRunner.run(
            executable: Self.ps,
            arguments: ["-p", String(pid), "-o", "command="],
            currentDirectory: nil
        ), result.status == 0 else {
            return nil
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func launchAgentTargets(_ output: String, executableURL: URL) -> Bool {
        let program = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("program =") else { return nil }
            return unquoted(String(trimmed.dropFirst("program =".count)).trimmingCharacters(in: .whitespacesAndNewlines))
        }.first
        guard let program, program.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: program).standardizedFileURL.resolvingSymlinksInPath().path == executableURL.path
    }

    private func launchAgentPID(_ output: String) -> pid_t? {
        let value = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("pid =") else { return nil }
            return String(trimmed.dropFirst("pid =".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }.first
        guard let value else { return nil }
        return pid_t(value)
    }

    private func value(after prefix: String, in lines: [String]) -> String? {
        lines.first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> ClipLineUpdateCommandResult {
        do {
            return try commandRunner.run(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory
            )
        } catch {
            throw ClipLineUpdateError.commandStartFailed(executable.lastPathComponent, error.localizedDescription)
        }
    }

    private func runRequired(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        name: String
    ) throws -> String {
        let result = try run(executable, arguments: arguments, currentDirectory: currentDirectory)
        guard result.status == 0 else {
            throw ClipLineUpdateError.commandFailed(name, result.status, summarize(result.output))
        }
        return result.output
    }

    private func cloneOfficialRepository(to checkoutURL: URL) throws {
        let httpsArgs = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "http.connectTimeout=8",
            "clone", "--depth", "1", "--branch", "main",
            "--single-branch", "--no-tags", Self.officialRepositoryURL, checkoutURL.path
        ]
        let httpsResult = try run(Self.git, arguments: httpsArgs)
        if httpsResult.status == 0 {
            return
        }
        try? fileManager.removeItem(at: checkoutURL)
        let sshArgs = [
            "-c", "core.hooksPath=/dev/null",
            "clone", "--depth", "1", "--branch", "main",
            "--single-branch", "--no-tags", Self.sshRepositoryURL, checkoutURL.path
        ]
        let sshResult = try run(Self.git, arguments: sshArgs)
        guard sshResult.status == 0 else {
            throw ClipLineUpdateError.commandFailed(
                "git clone",
                httpsResult.status,
                summarize(httpsResult.output.isEmpty ? sshResult.output : httpsResult.output)
            )
        }
    }

    private func isFullCommitID(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
        }
    }

    private func summarize(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1200 else { return trimmed }
        return String(trimmed.prefix(1200)) + "…"
    }
}

private struct CodeSignature {
    let identifier: String
    let mode: SigningMode
    let designatedRequirement: String?
}

private enum SigningMode {
    case adHoc
    case certificate(String)
}

private enum RestartPlan {
    case none
    case manual(String)
    case launchAgent(String)
    case daemon(pid_t)
}
