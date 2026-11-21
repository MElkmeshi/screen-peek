import AppKit
import ApplicationServices

enum Input {
    private(set) static var isInjecting = false
    private static var returnPoint: CGPoint?
    private static var returnWork: DispatchWorkItem?

    static var cursorLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    static func click(at point: CGPoint, button: CGMouseButton, count: Int) {
        beginInjection()
        if count == 1, bringOwnerToFront(of: point) { usleep(80_000) }
        warp(to: point)
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(15_000)
        let types: [CGEventType] = button == .right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for (index, type) in types.enumerated() {
            if index > 0 { usleep(40_000) }
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            event?.post(tap: .cghidEventTap)
        }
        scheduleReturn(after: 0.15)
    }

    static func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat) {
        beginInjection()
        warp(to: point)
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        event?.location = point
        event?.post(tap: .cghidEventTap)
        scheduleReturn(after: 0.3)
    }

    private static func bringOwnerToFront(of point: CGPoint) -> Bool {
        guard let hit = WindowMover.windowInfo(at: point), hit.layer == 0,
              let app = NSRunningApplication(processIdentifier: hit.pid), !app.isActive
        else { return false }
        return WindowMover.activate(pid: hit.pid)
    }

    private static func beginInjection() {
        returnWork?.cancel()
        if returnPoint == nil { returnPoint = cursorLocation }
        isInjecting = true
    }

    private static func scheduleReturn(after delay: TimeInterval) {
        let work = DispatchWorkItem {
            if let point = returnPoint { warp(to: point) }
            returnPoint = nil
            isInjecting = false
        }
        returnWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

enum WindowMover {
    struct Hit {
        let pid: pid_t
        let bounds: CGRect
        let layer: Int
    }

    static func frontWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID else { return nil }
        return element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
    }

    @discardableResult
    static func moveFrontWindow(to frame: CGRect) -> Bool {
        guard let window = frontWindow() else { return false }
        setFrame(window, frame)
        return true
    }

    @discardableResult
    static func centerFrontWindow(on display: CGDirectDisplayID? = nil) -> Bool {
        guard let window = frontWindow() else { return false }
        return center(window, on: display)
    }

    static func fixWindowsSpanningScreens() -> Int {
        var fixed = 0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            for window in elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) where !isMinimized(window) {
                guard let f = frame(of: window), Displays.spansMultiple(f), center(window) else { continue }
                fixed += 1
            }
        }
        return fixed
    }

    static func pullWindow(at point: CGPoint, to display: CGDirectDisplayID) -> Bool {
        guard let hit = windowInfo(at: point), hit.layer == 0 else { return false }
        let axApp = AXUIElementCreateApplication(hit.pid)
        let windows = elements(axApp, kAXWindowsAttribute)
        guard let window = windows.min(by: { distance(frame(of: $0), hit.bounds) < distance(frame(of: $1), hit.bounds) }),
              center(window, on: display)
        else { return false }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        activate(pid: hit.pid)
        return true
    }

    static func windowInfo(at point: CGPoint) -> Hit? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point)
            else { continue }
            return Hit(pid: pid, bounds: bounds, layer: info[kCGWindowLayer as String] as? Int ?? 0)
        }
        return nil
    }

    @discardableResult
    static func activate(pid: pid_t) -> Bool {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
    }

    @discardableResult
    static func center(_ window: AXUIElement, on display: CGDirectDisplayID? = nil) -> Bool {
        guard let f = frame(of: window), let id = display ?? Displays.best(for: f) else { return false }
        let area = Displays.visibleFrame(for: id)
        let size = CGSize(width: min(f.width, area.width), height: min(f.height, area.height))
        setFrame(window, CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))
        return true
    }

    private static var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let p = value(window, kAXPositionAttribute), AXValueGetValue(p, .cgPoint, &position),
              let s = value(window, kAXSizeAttribute), AXValueGetValue(s, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
    }

    private static func distance(_ a: CGRect?, _ b: CGRect) -> CGFloat {
        guard let a else { return .infinity }
        return abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        copy(element, attribute) as? [AXUIElement] ?? []
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        copy(window, kAXMinimizedAttribute) as? Bool ?? false
    }
}

enum Displays {
    static func active() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count))).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    static func id(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func name(for id: CGDirectDisplayID) -> String {
        let base = screen(for: id)?.localizedName ?? "Display \(id)"
        return id == CGMainDisplayID() ? "\(base) (main)" : base
    }

    static func visibleFrame(for id: CGDirectDisplayID) -> CGRect {
        guard let screen = screen(for: id) else { return CGDisplayBounds(id) }
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let f = screen.visibleFrame
        return CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height)
    }

    static func best(for frame: CGRect) -> CGDirectDisplayID? {
        active().max { area(CGDisplayBounds($0).intersection(frame)) < area(CGDisplayBounds($1).intersection(frame)) }
    }

    static func spansMultiple(_ frame: CGRect) -> Bool {
        active().filter {
            let overlap = CGDisplayBounds($0).intersection(frame)
            return !overlap.isNull && overlap.width >= 40 && overlap.height >= 40
        }.count >= 2
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
