import AppKit
import Carbon
import ScreenCaptureKit

@main
enum Entry {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preview = PreviewView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
    private let capture = Capture()
    private let hotKeys = HotKeys()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var targetID: CGDirectDisplayID?
    private var cursorLocked = false
    private var flashOnChange = true
    private var lastSafeCursor: CGPoint?
    private var monitors: [Any] = []
    private var restartGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestPermissions()
        buildPanel()
        buildStatusItem()
        registerHotKeys()
        installCursorLock()

        capture.onFrame = { [weak self] surface in
            DispatchQueue.main.async {
                guard let self else { return }
                self.preview.show(surface)
                if self.flashOnChange { self.preview.flash() }
            }
        }
        capture.onStop = { [weak self] error in
            DispatchQueue.main.async { self?.preview.showMessage("Capture stopped: \(error.localizedDescription)") }
        }
        preview.onClick = { [weak self] fraction, button, count in
            guard let point = self?.targetPoint(for: fraction) else { return }
            Input.click(at: point, button: button, count: count)
        }
        preview.onScroll = { [weak self] fraction, dx, dy in
            guard let point = self?.targetPoint(for: fraction) else { return }
            Input.scroll(at: point, dx: dx, dy: dy)
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartCapture() }
        }
        restartCapture()
    }

    private func requestPermissions() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func buildPanel() {
        panel = NSPanel(contentRect: preview.frame,
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "ScreenPeek"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = preview
        if !panel.setFrameUsingName("ScreenPeekPanel"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 16, y: v.minY + 16))
        }
        panel.setFrameAutosaveName("ScreenPeekPanel")
        panel.orderFrontRegardless()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "ScreenPeek")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let arrowRight = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        let arrowLeft = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let hotKeyMask: NSEvent.ModifierFlags = [.control, .option, .command]

        addItem(menu, panel.isVisible ? "Hide Preview" : "Show Preview", #selector(togglePreview), "p", hotKeyMask)
        addItem(menu, "Send Front Window to Target Screen", #selector(sendFrontWindow), arrowRight, hotKeyMask)
        addItem(menu, "Bring Front Window to Main Screen", #selector(bringFrontWindowBack), arrowLeft, hotKeyMask)
        addItem(menu, "Keep Cursor Off Target Screen", #selector(toggleCursorLock), "l", hotKeyMask).state = cursorLocked ? .on : .off
        addItem(menu, "Flash Border When Screen Changes", #selector(toggleFlash), "", []).state = flashOnChange ? .on : .off
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Target Screen", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for id in Displays.active() {
            let item = addItem(menu, Displays.name(for: id), #selector(selectDisplay(_:)), "", [])
            item.tag = Int(id)
            item.state = id == targetID ? .on : .off
            item.indentationLevel = 1
        }
        menu.addItem(.separator())
        addItem(menu, "Quit ScreenPeek", #selector(NSApplication.terminate(_:)), "q", [.command]).target = NSApp
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ mask: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        item.target = self
        menu.addItem(item)
        return item
    }

    private func registerHotKeys() {
        hotKeys.register(keyCode: kVK_ANSI_P) { MainActor.assumeIsolated { [weak self] in self?.togglePreview() } }
        hotKeys.register(keyCode: kVK_RightArrow) { MainActor.assumeIsolated { [weak self] in self?.sendFrontWindow() } }
        hotKeys.register(keyCode: kVK_LeftArrow) { MainActor.assumeIsolated { [weak self] in self?.bringFrontWindowBack() } }
        hotKeys.register(keyCode: kVK_ANSI_L) { MainActor.assumeIsolated { [weak self] in self?.toggleCursorLock() } }
    }

    private func installCursorLock() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.enforceCursorLock() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in handler(event); return event }) {
            monitors.append(local)
        }
    }

    private func enforceCursorLock() {
        let location = Input.cursorLocation
        guard cursorLocked, !Input.isInjecting, let id = targetID, id != CGMainDisplayID() else {
            lastSafeCursor = nil
            return
        }
        if CGDisplayBounds(id).contains(location) {
            Input.warp(to: lastSafeCursor ?? CGDisplayBounds(CGMainDisplayID()).center)
        } else {
            lastSafeCursor = location
        }
    }

    private func targetPoint(for fraction: CGPoint) -> CGPoint? {
        guard let id = targetID else { return nil }
        let b = CGDisplayBounds(id)
        return CGPoint(x: b.minX + fraction.x * (b.width - 1), y: b.minY + fraction.y * (b.height - 1))
    }

    private func restartCapture() {
        let displays = Displays.active()
        if targetID == nil || !displays.contains(targetID!) {
            targetID = displays.first { $0 != CGMainDisplayID() }
        }
        restartGeneration += 1
        let generation = restartGeneration

        guard let id = targetID else {
            Task { await capture.stop() }
            preview.showMessage("No second screen connected.\nPick a target screen from the menu bar icon to test with this one.")
            panel.title = "ScreenPeek"
            return
        }

        let size = CGDisplayBounds(id).size
        preview.aspect = size
        panel.contentAspectRatio = size
        let width = panel.contentRect(forFrameRect: panel.frame).width
        panel.setContentSize(NSSize(width: width, height: width * size.height / size.width))
        panel.title = Displays.name(for: id)

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard generation == restartGeneration else { return }
                guard let display = content.displays.first(where: { $0.displayID == id }) else {
                    preview.showMessage("Screen not available for capture.")
                    return
                }
                try await capture.start(display: display)
            } catch {
                guard generation == restartGeneration else { return }
                preview.showMessage("Allow Screen Recording for ScreenPeek in System Settings → Privacy & Security, then relaunch.\n\n\(error.localizedDescription)")
            }
        }
    }

    @objc private func togglePreview() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc private func sendFrontWindow() {
        guard let id = targetID else { return NSSound.beep() }
        if !WindowMover.moveFrontWindow(to: Displays.visibleFrame(for: id)) { NSSound.beep() }
    }

    @objc private func bringFrontWindowBack() {
        if !WindowMover.moveFrontWindow(to: Displays.visibleFrame(for: CGMainDisplayID())) { NSSound.beep() }
    }

    @objc private func toggleCursorLock() {
        cursorLocked.toggle()
        lastSafeCursor = nil
        enforceCursorLock()
    }

    @objc private func toggleFlash() {
        flashOnChange.toggle()
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        targetID = CGDirectDisplayID(sender.tag)
        restartCapture()
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
