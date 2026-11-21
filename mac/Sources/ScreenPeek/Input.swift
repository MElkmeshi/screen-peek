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

    private static func bringOwnerToFront(of point: CGPoint) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point)
            else { continue }
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let app = NSRunningApplication(processIdentifier: pid), !app.isActive
            else { return false }
            let axApp = AXUIElementCreateApplication(pid)
            return AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
        }
        return false
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
    @discardableResult
    static func moveFrontWindow(to frame: CGRect) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return false }
        let window = value as! AXUIElement
        setPoint(window, kAXPositionAttribute, frame.origin)
        setSize(window, frame.size)
        setPoint(window, kAXPositionAttribute, frame.origin)
        return true
    }

    private static func setPoint(_ window: AXUIElement, _ attribute: String, _ point: CGPoint) {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(window, attribute as CFString, value)
    }

    private static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
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
}
