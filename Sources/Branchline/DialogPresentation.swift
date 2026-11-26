import AppKit

@MainActor enum DialogPresentation {
    static weak var mainWindow: NSWindow?
    private static var policyObservers: [NSObjectProtocol] = []
    private static weak var backgroundModal: NSWindow?

    static func install() {
        guard policyObservers.isEmpty else { return }
        let center = NotificationCenter.default
        policyObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow else { return }
                backgroundModal = window
                window.hidesOnDeactivate = true
                window.orderOut(nil)
            }
        })
        policyObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let window = backgroundModal, NSApp.modalWindow === window, !window.isVisible { window.makeKeyAndOrderFront(nil) }
                backgroundModal = nil
            }
        })
        policyObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard window.sheetParent != nil || NSApp.modalWindow === window else { return }
                window.hidesOnDeactivate = true
            }
        })
    }

    private static var owner: NSWindow? {
        if let key = NSApp.keyWindow, key.isVisible, key !== NSApp.modalWindow, !(key is NSSavePanel) {
            var root = key
            while let parent = root.sheetParent { root = parent }
            if root === mainWindow { return key }
        }
        return mainWindow?.isVisible == true ? mainWindow : nil
    }

    /// Keep synchronous confirmation decisions for editor dismissal and quit.
    /// Owning the panel and hiding it on deactivation prevents an accessory-app
    /// modal panel from remaining above the foreground application's windows.
    static func confirm(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let window = alert.window
        let parent = owner
        window.hidesOnDeactivate = true
        if let parent, parent !== window { parent.addChildWindow(window, ordered: .above) }
        defer { parent?.removeChildWindow(window) }
        return alert.runModal()
    }

    static func chooseFile(_ panel: NSSavePanel, fromEditor: Bool = false, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Bool {
        guard let parent = fromEditor ? owner : mainWindow, parent.isVisible, parent.attachedSheet == nil else { return false }
        panel.hidesOnDeactivate = true
        panel.beginSheetModal(for: parent) { response in
            // Allow AppKit to finish detaching the file sheet before presenting
            // a restore confirmation or changing the main-window content.
            Task { @MainActor in completion(response) }
        }
        return true
    }
}
