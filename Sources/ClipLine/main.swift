import AppKit
import Foundation

#if CLIPLINE_TEST
MainActor.assumeIsolated {
    exit(runAllTests())
}
#else
@MainActor
private final class SettingsRequestAcknowledgement {
    var received = false
}

@MainActor
private func requestSettingsFromRunningDaemon() -> Bool {
    let center = DistributedNotificationCenter.default()
    let requestID = UUID().uuidString
    let replyChannel = NotificationChannels.settingsAcknowledgementChannel(for: requestID)
    let acknowledgement = SettingsRequestAcknowledgement()
    let observer = center.addObserver(
        forName: NSNotification.Name(replyChannel),
        object: nil,
        queue: .main
    ) { note in
        if note.userInfo?["requestID"] as? String == requestID {
            Task { @MainActor in acknowledgement.received = true }
        }
    }
    defer { center.removeObserver(observer) }

    return SettingsRequestRetry.send(
        maxAttempts: 3,
        post: {
            for channel in NotificationChannels.settingsChannels {
                center.postNotificationName(
                    NSNotification.Name(channel),
                    object: nil,
                    userInfo: ["requestID": requestID, "replyChannel": replyChannel],
                    deliverImmediately: true
                )
            }
        },
        waitForAcknowledgement: {
            let deadline = Date(timeIntervalSinceNow: 1)
            while !acknowledgement.received && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: deadline)
            }
            return acknowledgement.received
        }
    )
}

let args = CommandLine.arguments
if args.count >= 2 && args[1] == "--update" {
    print("[ClipLine] \(ClipLineUpdater.updateNotice)")
    do {
        let executableURL = try ClipLineUpdater.currentExecutableURL()
        let context = ClipLineUpdateContext.current(executableURL: executableURL)
        let report = try ClipLineUpdater(context: context).update()
        print("[ClipLine] Updated to commit \(report.commit).")
        print("[ClipLine] \(report.restartMessage)")
        exit(0)
    } catch {
        fputs("[ClipLine] Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

var startupSettingsRequested = false
var startupLockAcquired = false
if args.count >= 2 {
    let arg = args[1]
    if arg == "-h" || arg == "--help" {
        print("""
        Usage: clipline [options]
          (no args)        Start ClipLine background daemon (or trigger capture if already running)
          -i, --capture    Trigger interactive region capture + Pin on screen
          -c, --clipboard  Pin current clipboard image on screen
          --settings       Open keyboard shortcut settings (starts the daemon if needed)
          --shortcuts      Print current global shortcuts as JSON
          --update         Download, build, and install the latest official version
          -h, --help       Show this help message
        """)
        exit(0)
    } else if arg == "--shortcuts" {
        let defaults = UserDefaults(suiteName: ShortcutConfigurationStore.suiteName)!
        let configuration = ShortcutConfigurationStore(defaults: defaults).load()
        do {
            print(try configuration.cliJSON())
            exit(0)
        } catch {
            fputs("[ClipLine] Error: Unable to encode shortcut settings: \(error)\n", stderr)
            exit(1)
        }
    } else if arg == "--settings" {
        startupLockAcquired = MainActor.assumeIsolated {
            SingleInstanceLock.acquireOrNotifyExisting(notifyExisting: false)
        }
        if startupLockAcquired {
            startupSettingsRequested = true
        } else {
            let acknowledged = MainActor.assumeIsolated {
                requestSettingsFromRunningDaemon()
            }
            guard acknowledged else {
                fputs("[ClipLine] Error: Timed out waiting for the running daemon to open shortcut settings.\n", stderr)
                exit(1)
            }
            exit(0)
        }
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
    guard startupLockAcquired || SingleInstanceLock.acquireOrNotifyExisting() else {
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = PinDaemonApp()
    delegate.openSettingsOnLaunch = startupSettingsRequested
    app.delegate = delegate
    app.run()
}
#endif
