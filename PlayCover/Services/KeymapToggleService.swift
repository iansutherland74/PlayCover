//
//  KeymapToggleService.swift
//  PlayCover
//
//  Toggles the per-app "Keymapping" setting and relaunches the app, for ANY imported app.
//  Exposed as a menu command (App Library > Toggle Keymapping & Relaunch) and as an optional
//  system-wide hotkey (Control + Option + Command + K) so it also works while a game has focus.
//

import AppKit
import Carbon.HIToolbox

extension PlayApp {
    /// Running instances of this app (launched through PlayCover's alias bundle).
    var runningInstances: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == info.bundleIdentifier && !$0.isTerminated
        }
    }

    /// Flip the keymapping setting. If the app is running, quit it and launch it again so
    /// PlayTools picks up the new value. If it is not running, only the setting is flipped.
    @MainActor
    func toggleKeymappingAndRelaunch() async {
        guard !isStarting else { return }

        let running = runningInstances
        // Re-read from disk: another PlayApp instance (e.g. the settings sheet) may have changed it
        settings.decode()
        settings.settings.keymapping.toggle()
        let enabled = settings.settings.keymapping
        Log.shared.log("Keymapping \(enabled ? "enabled" : "disabled") for \(info.bundleIdentifier)")

        let stateKey = enabled ? "keymapToggle.on" : "keymapToggle.off"
        NotifyService.shared.notify(name, String(format: NSLocalizedString(stateKey, comment: ""), name))

        guard !running.isEmpty else { return }

        running.forEach { $0.terminate() }
        // Wait up to ~5s for a graceful quit, then force it
        for _ in 0..<50 where !running.allSatisfy({ $0.isTerminated }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        // Let LaunchServices release the old process before opening the new one
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        isStarting = true
        await launch()
        isStarting = false
    }
}

@MainActor
final class KeymapToggleService {
    static let shared = KeymapToggleService()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// The app to act on: the frontmost imported app if one has focus (hotkey used in-game),
    /// otherwise the app currently selected in the App Library.
    func targetApp() -> PlayApp? {
        let apps = AppsVM.shared.apps
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier,
           let app = apps.first(where: { $0.info.bundleIdentifier == front.bundleIdentifier }) {
            return app
        }
        return AppsVM.shared.selectedApp
    }

    func toggleTarget() {
        guard let app = targetApp() else {
            Log.shared.log("Toggle keymapping: no app selected or running")
            return
        }
        Task { await app.toggleKeymappingAndRelaunch() }
    }

    /// Registers Control + Option + Command + K system-wide (no extra permissions required).
    func registerGlobalHotKey() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            Task { @MainActor in KeymapToggleService.shared.toggleTarget() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x504B4D54) /* 'PKMT' */, id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_K),
                            UInt32(controlKey | optionKey | cmdKey),
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
