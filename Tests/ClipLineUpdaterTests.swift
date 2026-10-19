import Darwin
import Foundation

@MainActor
func runClipLineUpdaterTests(_ t: TestHarness) {
    print("\n🔹 Suite 8: Explicit Updater (Offline, Isolated Fixtures)")

    let testRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipLine Updater Tests \(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: false)
    } catch {
        t.check(false, "Create isolated updater test directory", detail: "\(error)")
        return
    }
    defer { try? FileManager.default.removeItem(at: testRoot) }

    do {
        let fixture = try makeUpdaterFixture(in: testRoot, name: "install directory with spaces")
        let runner = FakeClipLineUpdateCommandRunner(targetURL: fixture.executableURL)
        let report = try ClipLineUpdater(context: fixture.context, commandRunner: runner).update()

        t.check(
            report.commit == "0123456789abcdef0123456789abcdef01234567" &&
                (try? Data(contentsOf: fixture.executableURL)) == Data("new-binary".utf8),
            "Successful update installs the built executable and reports the fetched commit"
        )

        let clone = runner.invocations.first { $0.executable.lastPathComponent == "git" && $0.arguments.contains("clone") }
        t.check(
            clone?.arguments.contains("https://github.com/howtospellpizza/ClipLine.git") == true &&
                clone?.arguments.contains("--branch") == true && clone?.arguments.contains("main") == true &&
                clone?.arguments.last?.contains("ClipLine Updater Tests") == true,
            "Update clones only official main into one safely quoted-by-argument temporary path"
        )

        let build = runner.invocations.first { $0.executable.lastPathComponent == "make" }
        let sign = runner.invocations.first { $0.executable.lastPathComponent == "codesign" && $0.arguments.contains("--sign") }
        let verify = runner.invocations.contains { $0.executable.lastPathComponent == "codesign" && $0.arguments.first == "--verify" }
        t.check(
            build?.currentDirectory?.path.contains("ClipLine Updater Tests") == true &&
                sign?.arguments.contains("-") == true &&
                sign?.arguments.last?.contains("install directory with spaces") == true && verify,
            "Build, ad-hoc signing, and staged signature verification use argument arrays and support spaced paths"
        )

        t.check(
            ClipLineUpdater.updateNotice.contains("GitHub") &&
                ClipLineUpdater.updateNotice.contains("screenshots") &&
                report.restartMessage.contains("No matching"),
            "Updater notice states network/privacy and no-daemon restart behavior"
        )
    } catch {
        t.check(false, "Successful isolated updater run", detail: "\(error)")
    }

    checkUpdaterFailure(
        t,
        in: testRoot,
        name: "clone failure",
        failure: .clone
    )
    checkUpdaterFailure(
        t,
        in: testRoot,
        name: "build failure",
        failure: .build
    )
    checkUpdaterFailure(
        t,
        in: testRoot,
        name: "signing failure",
        failure: .sign,
        signatureOutput: "Identifier=io.github.clipline\nAuthority=Developer ID Application: Test Identity (ABCDE12345)\n"
    )
    checkUpdaterFailure(
        t,
        in: testRoot,
        name: "signature validation failure",
        failure: .verify
    )

    do {
        let fixture = try makeUpdaterFixture(in: testRoot, name: "certificate signed install")
        let runner = FakeClipLineUpdateCommandRunner(targetURL: fixture.executableURL)
        let identity = "Developer ID Application: Test Identity (ABCDE12345)"
        runner.signatureResult = ClipLineUpdateCommandResult(
            status: 0,
            output: "Identifier=io.github.clipline\nAuthority=\(identity)\nTeamIdentifier=ABCDE12345\n"
        )
        runner.launchAgentResult = ClipLineUpdateCommandResult(
            status: 0,
            output: "program = \(fixture.executableURL.path)\npid = 321\n"
        )

        let report = try ClipLineUpdater(context: fixture.context, commandRunner: runner).update()
        let sign = runner.invocations.first { $0.executable.lastPathComponent == "codesign" && $0.arguments.contains("--sign") }
        let restartedAfterSwap = runner.targetWasNewWhenLaunchAgentRestarted

        t.check(
            sign?.arguments.contains(identity) == true &&
                sign?.arguments.contains("io.github.clipline") == true &&
                report.restartMessage.contains("existing matching LaunchAgent"),
            "Certificate-signed update preserves its identity and code identifier, then selects the matching existing LaunchAgent"
        )
        t.check(
            restartedAfterSwap && runner.invocations.contains(where: { $0.arguments == ["kickstart", "-k", "gui/\(fixture.context.userID)/io.github.clipline.daemon"] }) &&
                runner.killedPIDs.isEmpty && runner.launches.isEmpty,
            "Matching LaunchAgent is kicked only after atomic replacement; no other process is killed or launched"
        )
    } catch {
        t.check(false, "Certificate signing and LaunchAgent restart guard", detail: "\(error)")
    }

    do {
        let fixture = try makeUpdaterFixture(in: testRoot, name: "nonmatching service")
        let runner = FakeClipLineUpdateCommandRunner(targetURL: fixture.executableURL)
        runner.launchAgentResult = ClipLineUpdateCommandResult(
            status: 0,
            output: "program = /Applications/OtherApp/clipline\npid = 654\n"
        )
        _ = try ClipLineUpdater(context: fixture.context, commandRunner: runner).update()
        t.check(
            !runner.invocations.contains(where: { $0.arguments.first == "kickstart" }) &&
                runner.killedPIDs.isEmpty && runner.launches.isEmpty,
            "Updater does not restart a registered LaunchAgent that targets another executable"
        )
    } catch {
        t.check(false, "Nonmatching LaunchAgent restart guard", detail: "\(error)")
    }

    do {
        let fixture = try makeUpdaterFixture(in: testRoot, name: "same-path daemon", lockPID: 456)
        let runner = FakeClipLineUpdateCommandRunner(targetURL: fixture.executableURL)
        runner.processPath = fixture.executableURL.path
        runner.processCommand = fixture.executableURL.path
        let report = try ClipLineUpdater(context: fixture.context, commandRunner: runner).update()

        t.check(
            runner.killedPIDs == [456] && runner.launches.count == 1 &&
                runner.launches.first?.executable == fixture.executableURL &&
                runner.launches.first?.environment == fixture.context.environment &&
                report.restartMessage.contains("current environment"),
            "Only the lock-file PID at the exact executable path is restarted with the updater environment"
        )
    } catch {
        t.check(false, "Same-path daemon restart guard", detail: "\(error)")
    }

    do {
        let fixture = try makeUpdaterFixture(in: testRoot, name: "updater process", lockPID: 789, processID: 789)
        let runner = FakeClipLineUpdateCommandRunner(targetURL: fixture.executableURL)
        runner.processPath = fixture.executableURL.path
        runner.processCommand = "\(fixture.executableURL.path) --update"
        let report = try ClipLineUpdater(context: fixture.context, commandRunner: runner).update()

        t.check(
            runner.killedPIDs.isEmpty && runner.launches.isEmpty && !report.restartMessage.contains("Restarted the same-path"),
            "Updater never terminates or relaunches its own process"
        )
    } catch {
        t.check(false, "Updater self-process guard", detail: "\(error)")
    }

    do {
        let fixture = try makeUpdaterFixture(in: testRoot, name: "launch agent updater", processID: 987)
        let runner = FakeClipLineUpdateCommandRunner(targetURL: fixture.executableURL)
        runner.launchAgentResult = ClipLineUpdateCommandResult(
            status: 0,
            output: "program = \(fixture.executableURL.path)\npid = 987\n"
        )
        let report = try ClipLineUpdater(context: fixture.context, commandRunner: runner).update()
        t.check(
            !runner.invocations.contains(where: { $0.arguments.first == "kickstart" }) &&
                report.restartMessage.contains("updater is the registered LaunchAgent"),
            "Updater does not kickstart a LaunchAgent whose active PID is the updater itself"
        )
    } catch {
        t.check(false, "LaunchAgent self-process guard", detail: "\(error)")
    }

    do {
        let fixture = try makeUpdaterFixture(in: testRoot, name: "root guard", effectiveUserID: 0)
        let runner = FakeClipLineUpdateCommandRunner(targetURL: fixture.executableURL)
        let failed = (try? ClipLineUpdater(context: fixture.context, commandRunner: runner).update()) == nil
        t.check(
            failed && runner.invocations.isEmpty &&
                (try? Data(contentsOf: fixture.executableURL)) == Data("old-binary".utf8),
            "Root/sudo invocation is rejected before network access and preserves the installed binary"
        )
    } catch {
        t.check(false, "Root guard fixture", detail: "\(error)")
    }
}

@MainActor
private func checkUpdaterFailure(
    _ t: TestHarness,
    in directory: URL,
    name: String,
    failure: FakeClipLineUpdateCommandRunner.Failure,
    signatureOutput: String = "Identifier=io.github.clipline\nSignature=adhoc\n"
) {
    do {
        let fixture = try makeUpdaterFixture(in: directory, name: name)
        let runner = FakeClipLineUpdateCommandRunner(targetURL: fixture.executableURL)
        runner.failure = failure
        runner.signatureResult = ClipLineUpdateCommandResult(status: 0, output: signatureOutput)
        let failed = (try? ClipLineUpdater(context: fixture.context, commandRunner: runner).update()) == nil
        t.check(
            failed && (try? Data(contentsOf: fixture.executableURL)) == Data("old-binary".utf8),
            "\(name) leaves the previously installed binary unchanged"
        )
    } catch {
        t.check(false, "Create \(name) fixture", detail: "\(error)")
    }
}

private struct ClipLineUpdaterFixture {
    let executableURL: URL
    let context: ClipLineUpdateContext
}

private func makeUpdaterFixture(
    in directory: URL,
    name: String,
    lockPID: pid_t? = nil,
    processID: pid_t = 900,
    effectiveUserID: uid_t = 1
) throws -> ClipLineUpdaterFixture {
    let installDirectory = directory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
    let executableURL = installDirectory.appendingPathComponent("clipline")
    try Data("old-binary".utf8).write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    let attributes = try FileManager.default.attributesOfItem(atPath: executableURL.path)
    let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? getuid()
    let lockFileURL = installDirectory.appendingPathComponent("clipline_daemon.lock")
    if let lockPID {
        try Data("\(lockPID)\n".utf8).write(to: lockFileURL)
    }

    return ClipLineUpdaterFixture(
        executableURL: executableURL,
        context: ClipLineUpdateContext(
            executableURL: executableURL,
            temporaryDirectoryURL: directory,
            lockFileURL: lockFileURL,
            userID: ownerID,
            effectiveUserID: effectiveUserID,
            processIdentifier: processID,
            environment: ["CLIP_LINE_TRANSLATE_DAEMON": "test-translate-daemon", "PATH": "/usr/bin:/bin"]
        )
    )
}

private final class FakeClipLineUpdateCommandRunner: ClipLineUpdateCommandRunning {
    enum Failure: Equatable {
        case clone
        case build
        case sign
        case verify
    }

    struct Invocation {
        let executable: URL
        let arguments: [String]
        let currentDirectory: URL?
    }

    struct LaunchInvocation {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    private let targetURL: URL
    private let fileManager = FileManager.default

    var failure: Failure?
    var signatureResult = ClipLineUpdateCommandResult(
        status: 0,
        output: "Identifier=io.github.clipline\nSignature=adhoc\n"
    )
    var launchAgentResult = ClipLineUpdateCommandResult(status: 1, output: "service not found")
    var processPath: String?
    var processCommand: String?
    var killedPIDs: Set<pid_t> = []
    var invocations: [Invocation] = []
    var launches: [LaunchInvocation] = []
    var targetWasNewWhenLaunchAgentRestarted = false

    init(targetURL: URL) {
        self.targetURL = targetURL
    }

    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?
    ) throws -> ClipLineUpdateCommandResult {
        invocations.append(Invocation(executable: executable, arguments: arguments, currentDirectory: currentDirectory))
        switch executable.lastPathComponent {
        case "git":
            if arguments.contains("clone") {
                guard failure != .clone, let destination = arguments.last else {
                    return ClipLineUpdateCommandResult(status: 1, output: "simulated clone failure")
                }
                try fileManager.createDirectory(
                    at: URL(fileURLWithPath: destination, isDirectory: true),
                    withIntermediateDirectories: false
                )
                return ClipLineUpdateCommandResult(status: 0, output: "")
            }
            return ClipLineUpdateCommandResult(
                status: 0,
                output: "0123456789abcdef0123456789abcdef01234567\n"
            )
        case "make":
            guard failure != .build, let currentDirectory else {
                return ClipLineUpdateCommandResult(status: 1, output: "simulated build failure")
            }
            let buildDirectory = currentDirectory.appendingPathComponent("build", isDirectory: true)
            try fileManager.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
            let builtExecutable = buildDirectory.appendingPathComponent("clipline")
            try Data("new-binary".utf8).write(to: builtExecutable)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: builtExecutable.path)
            return ClipLineUpdateCommandResult(status: 0, output: "built")
        case "codesign":
            if arguments.first == "--display" { return signatureResult }
            if arguments.first == "-d", arguments.contains("-r-") {
                return ClipLineUpdateCommandResult(
                    status: 0,
                    output: "designated => identifier \"io.github.clipline\" and certificate leaf = H\"0123456789abcdef0123456789abcdef01234567\"\n"
                )
            }
            if arguments.contains("--sign"), failure == .sign {
                return ClipLineUpdateCommandResult(status: 1, output: "simulated signing failure")
            }
            if arguments.first == "--verify", failure == .verify {
                return ClipLineUpdateCommandResult(status: 1, output: "simulated signature failure")
            }
            return ClipLineUpdateCommandResult(status: 0, output: "verified")
        case "launchctl":
            if arguments.first == "print" { return launchAgentResult }
            if arguments.first == "kickstart" {
                targetWasNewWhenLaunchAgentRestarted = (try? Data(contentsOf: targetURL)) == Data("new-binary".utf8)
            }
            return ClipLineUpdateCommandResult(status: 0, output: "")
        case "ps":
            guard arguments.count >= 4, let pid = pid_t(arguments[1]), !killedPIDs.contains(pid) else {
                return ClipLineUpdateCommandResult(status: 1, output: "")
            }
            if arguments.last == "comm=", let processPath {
                return ClipLineUpdateCommandResult(status: 0, output: processPath + "\n")
            }
            if arguments.last == "command=", let processCommand {
                return ClipLineUpdateCommandResult(status: 0, output: processCommand + "\n")
            }
            return ClipLineUpdateCommandResult(status: 1, output: "")
        case "kill":
            if arguments.count == 2, let pid = pid_t(arguments[1]) { killedPIDs.insert(pid) }
            return ClipLineUpdateCommandResult(status: 0, output: "")
        default:
            return ClipLineUpdateCommandResult(status: 1, output: "unexpected command")
        }
    }

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) throws {
        launches.append(LaunchInvocation(executable: executable, arguments: arguments, environment: environment))
    }
}
