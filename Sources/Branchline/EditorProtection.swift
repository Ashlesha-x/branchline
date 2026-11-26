import SwiftUI
import AppKit

/// One editor is presented at a time. The same decision guards sheet dismissal,
/// command-driven editor replacement, main-window close, and application quit.
@MainActor final class EditorProtection {
    static let shared = EditorProtection()
    private var owner: UUID?
    private var isResolving = false
    private var keyMonitor: Any?
    private var transientPopovers = Set<UUID>()
    func openedPopover(_ id: UUID) { transientPopovers.insert(id) }
    func closedPopover(_ id: UUID) { transientPopovers.remove(id) }
    private init() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return consumed ? nil : event
        }
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        guard owner != nil, !isResolving, NSApp.modalWindow == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let escape = event.keyCode == 53
        let quit = event.keyCode == 12 && modifiers == .command
        let closeWindow = event.keyCode == 13 && modifiers == .command
        if escape && !transientPopovers.isEmpty { return false }
        guard escape || quit || closeWindow else { return false }
        let window = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
        if resolve() {
            NotificationCenter.default.post(name: .editorWindowClosing, object: nil)
            if quit || closeWindow, let sheet = window?.attachedSheet { window?.endSheet(sheet) }
            if quit { NSApp.terminate(nil) }
            else if closeWindow { window?.performClose(nil) }
        }
        return true
    }
    func prepareForTermination() -> Bool {
        guard resolve() else { return false }
        NotificationCenter.default.post(name: .editorWindowClosing, object: nil)
        let window = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
        if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        return true
    }
    func quit() { if prepareForTermination() { NSApp.terminate(nil) } }
    private var hasChanges: () -> Bool = { false }
    private var save: (() throws -> Void)?
    private var checkpoint: () -> Void = {}
    private var discard: () -> Void = {}
    private var reportError: ((String) -> Void)?
    func update(owner: UUID, dirty: @escaping () -> Bool, save: @escaping () throws -> Void, reportError: @escaping (String) -> Void, discard: @escaping () -> Void = {}, checkpoint: @escaping () -> Void = {}) {
        self.owner = owner; self.hasChanges = dirty; self.save = save; self.reportError = reportError; self.discard = discard; self.checkpoint = checkpoint
    }
    func clear(owner: UUID) { if self.owner == owner { self.owner = nil; hasChanges = { false }; save = nil; reportError = nil; discard = {}; checkpoint = {} } }
    func resolve() -> Bool {
        checkpoint()
        guard !isResolving else { return false }
        guard let owner else { return true }
        guard hasChanges() else { clear(owner: owner); return true }
        isResolving = true
        defer { isResolving = false }
        let alert = NSAlert(); alert.messageText = "保存未完成的修改？"
        alert.informativeText = "可以保存后离开、放弃本次修改，或继续编辑。"
        alert.addButton(withTitle: "继续编辑").keyEquivalent = "\r"
        alert.addButton(withTitle: "保存并离开").keyEquivalent = "s"
        alert.addButton(withTitle: "放弃修改").hasDestructiveAction = true
        switch DialogPresentation.confirm(alert) {
        case .alertSecondButtonReturn:
            do { try save?(); clear(owner: owner); return true }
            catch { reportError?(error.localizedDescription); return false }
        case .alertThirdButtonReturn: discard(); clear(owner: owner); return true
        default: return false
        }
    }
}

struct MainWindowProtection: NSViewRepresentable {
    func makeNSView(context: Context) -> ProtectionView { ProtectionView() }
    func updateNSView(_ view: ProtectionView, context: Context) {}
    @MainActor final class ProtectionView: NSView, NSWindowDelegate {
        // NSObject's selector forwarding hooks are nonisolated. AppKit assigns
        // and calls the actual window delegate on the main thread.
        nonisolated(unsafe) private weak var previousDelegate: (any NSWindowDelegate)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.delegate !== self else { return }
            DialogPresentation.mainWindow = window
            previousDelegate = window.delegate; window.delegate = self
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard EditorProtection.shared.resolve() else { return false }
            NotificationCenter.default.post(name: .editorWindowClosing, object: nil)
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return previousDelegate?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previousDelegate?.responds(to: selector) == true { return previousDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}
extension Notification.Name { static let editorWindowClosing = Notification.Name("editorWindowClosing") }
