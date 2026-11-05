import AppKit

/// Runs the real launch/close/async-persistence path in a separate process. Success is a normal app exit;
/// a main-queue termination deadlock instead reaches the independent watchdog and exits with failure.
@MainActor enum WindowCloseBench {
    static func install() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            FileHandle.standardError.write(Data("window-close: app did not terminate within 10 seconds\n".utf8))
            exit(1)
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            // A desktop launch may show the window without granting this test process foreground focus.
            let candidate = MainActor.assumeIsolated {
                NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
            }
            guard let window = candidate else { return }
            timer.invalidate()
            MainActor.assumeIsolated {
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15),
                   NSApp.mainMenu?.performKeyEquivalent(with: event) != true {
                    FileHandle.standardError.write(Data("window-close: Refresh shortcut was not handled\n".utf8))
                    exit(1)
                }
                FileHandle.standardError.write(Data("window-close: closing player window\n".utf8))
                window.performClose(nil)
            }
        }
    }
}
