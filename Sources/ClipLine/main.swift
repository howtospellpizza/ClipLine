import AppKit
import Foundation

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
