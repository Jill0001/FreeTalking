import AppKit
import ApplicationServices

/// Reads the insertion point exposed by the focused app, without changing focus.
enum RecordingIndicatorPlacement {
    static var locationSource = "unavailable"

    static func caretRect() -> CGRect? {
        locationSource = "accessibility unavailable"
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        locationSource = "focused element unavailable in \(app.bundleIdentifier ?? "unknown")"
        guard let focused = attribute(kAXFocusedUIElementAttribute, on: application),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        let role = attribute(kAXRoleAttribute, on: element) as? String ?? "unknown"
        let appName = app.bundleIdentifier ?? "unknown"
        if let selection = attribute(kAXSelectedTextRangeAttribute, on: element),
           CFGetTypeID(selection) == AXValueGetTypeID() {
            let selectedValue = selection as! AXValue
            var range = CFRange()
            if AXValueGetType(selectedValue) == .cfRange,
               AXValueGetValue(selectedValue, .cfRange, &range), range.location >= 0 {
                if let rect = rangeBounds(CFRange(location: range.location, length: 0), on: element) {
                    locationSource = "caret in \(appName) (\(role))"
                    return rect
                }
                if range.length > 0, let rect = rangeBounds(range, on: element) {
                    locationSource = "selection in \(appName) (\(role))"
                    return rect
                }
                // Some editors expose character bounds but reject an empty range.
                if let rect = rangeBounds(CFRange(location: range.location, length: 1), on: element) {
                    locationSource = "next character in \(appName) (\(role))"
                    return rect
                }
                if range.location > 0,
                   let rect = rangeBounds(CFRange(location: range.location - 1, length: 1), on: element) {
                    locationSource = "previous character in \(appName) (\(role))"
                    return rect
                }
            }
        }
        // The focused input remains a useful visual anchor when caret bounds are absent.
        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
           let position = attribute(kAXPositionAttribute, on: element),
           let size = attribute(kAXSizeAttribute, on: element),
           CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            let p = position as! AXValue
            let z = size as! AXValue
            if AXValueGetType(p) == .cgPoint, AXValueGetType(z) == .cgSize,
               AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(z, .cgSize, &dimensions),
               let rect = screenRect(CGRect(origin: point, size: dimensions)) {
                locationSource = "input field; caret bounds unavailable in \(appName) (\(role))"
                return rect
            }
        }
        locationSource = "input bounds unavailable in \(appName) (\(role))"
        return nil
    }

    private static func rangeBounds(_ requested: CFRange, on element: AXUIElement) -> CGRect? {
        var range = requested
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                        parameter, &result) == .success,
              let result = result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let bounds = result as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(bounds) == .cgRect, AXValueGetValue(bounds, .cgRect, &rect) else { return nil }
        return screenRect(rect)
    }

    private static func screenRect(_ bounds: CGRect) -> CGRect? {
        var rect = bounds
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.width >= 0, rect.height.isFinite, rect.height > 0,
              let primary = NSScreen.screens.first else { return nil }
        rect.origin.y = primary.frame.maxY - rect.maxY
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect.insetBy(dx: -1, dy: -1)) }) else { return nil }
        return rect
    }

    static func origin(near caret: CGRect, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let gap: CGFloat = 8
        var y = caret.minY - panelSize.height - gap
        if y < visibleFrame.minY + gap { y = caret.maxY + gap }
        let x = min(max(caret.minX, visibleFrame.minX + gap), visibleFrame.maxX - panelSize.width - gap)
        y = min(max(y, visibleFrame.minY + gap), visibleFrame.maxY - panelSize.height - gap)
        return CGPoint(x: x, y: y)
    }

    private static func attribute(_ name: String, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
