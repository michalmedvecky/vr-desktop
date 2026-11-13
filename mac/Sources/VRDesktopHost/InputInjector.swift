import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Replays mouse and keyboard events from the Quest into macOS windows using CGEvent.
/// Requires the Accessibility permission (System Settings > Privacy & Security > Accessibility).
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown: Set<Int> = []
    private var focusedWindow: UInt32 = 0

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func handle(_ msg: InputMessage) {
        switch msg {
        case let .mouse(w, x, y, action, button):
            mouse(window: w, x: x, y: y, action: action, button: button)
        case let .scroll(w, x, y, dx, dy):
            scroll(window: w, x: x, y: y, dx: dx, dy: dy)
        case let .key(key, down, mods):
            self.key(key, down: down, mods: mods)
        case let .text(s):
            typeText(s)
        }
    }

    // MARK: Mouse

    private func point(window: UInt32, x: Double, y: Double) -> CGPoint? {
        guard let b = WindowCatalog.currentBounds(of: window) else { return nil }
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        return CGPoint(x: b.minX + cx * b.width, y: b.minY + cy * b.height)
    }

    private func mouse(window: UInt32, x: Double, y: Double, action: String, button: Int) {
        guard let p = point(window: window, x: x, y: y) else { return }
        let btn: CGMouseButton = button == 1 ? .right : (button == 2 ? .center : .left)
        let type: CGEventType
        switch action {
        case "down":
            focus(window: window)
            buttonsDown.insert(button)
            type = btn == .left ? .leftMouseDown : (btn == .right ? .rightMouseDown : .otherMouseDown)
        case "up":
            buttonsDown.remove(button)
            type = btn == .left ? .leftMouseUp : (btn == .right ? .rightMouseUp : .otherMouseUp)
        default:
            if buttonsDown.contains(0) { type = .leftMouseDragged }
            else if buttonsDown.contains(1) { type = .rightMouseDragged }
            else { type = .mouseMoved }
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: btn) else { return }
        if action == "down" || action == "up" {
            e.setIntegerValueField(.mouseEventClickState, value: clickCount(action: action, at: p))
        }
        e.post(tap: .cghidEventTap)
    }

    // Double-click detection so that double clicks in VR work as on the Mac.
    private var lastDown: (time: TimeInterval, point: CGPoint, count: Int64) = (0, .zero, 0)
    private func clickCount(action: String, at p: CGPoint) -> Int64 {
        let now = ProcessInfo.processInfo.systemUptime
        if action == "down" {
            let close = hypot(p.x - lastDown.point.x, p.y - lastDown.point.y) < 6
            let count: Int64 = (close && now - lastDown.time < NSEvent.doubleClickInterval) ? lastDown.count + 1 : 1
            lastDown = (now, p, count)
            return count
        }
        return lastDown.count
    }

    private func scroll(window: UInt32, x: Double, y: Double, dx: Double, dy: Double) {
        guard let p = point(window: window, x: x, y: y) else { return }
        if focusedWindow != window { focus(window: window) }
        CGWarpMouseCursorPosition(p)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        e.location = p
        e.post(tap: .cghidEventTap)
    }

    // MARK: Focus

    /// Activates the owning app and raises the specific window (matched by frame via Accessibility).
    private func focus(window: UInt32) {
        focusedWindow = window
        guard let pid = WindowCatalog.ownerPID(of: window),
              let bounds = WindowCatalog.currentBounds(of: window) else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()

        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else { return }
        for w in axWindows {
            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            var pos = CGPoint.zero, size = CGSize.zero
            if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
               AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success {
                AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                if abs(pos.x - bounds.minX) < 2, abs(pos.y - bounds.minY) < 2,
                   abs(size.width - bounds.width) < 2, abs(size.height - bounds.height) < 2 {
                    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                    break
                }
            }
        }
    }

    // MARK: Keyboard

    private func flags(_ mods: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in mods {
            switch m.lowercased() {
            case "cmd", "command", "meta": f.insert(.maskCommand)
            case "shift": f.insert(.maskShift)
            case "alt", "option": f.insert(.maskAlternate)
            case "ctrl", "control": f.insert(.maskControl)
            default: break
            }
        }
        return f
    }

    private func key(_ name: String, down: Bool, mods: [String]) {
        guard let code = KeyMap.code(for: name) else {
            // Unknown name: type it as text on key down.
            if down, name.count == 1 { typeText(name) }
            return
        }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags(mods)
        e.post(tap: .cghidEventTap)
    }

    /// Types arbitrary Unicode text (works independently of the keyboard layout).
    private func typeText(_ s: String) {
        for chunk in s.chunked(20) {
            let utf16 = Array(chunk.utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                e.post(tap: .cghidEventTap)
            }
        }
    }
}

private extension String {
    func chunked(_ n: Int) -> [String] {
        var out: [String] = [], cur = ""
        for ch in self {
            cur.append(ch)
            if cur.utf16.count >= n { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// Key names used by the Quest client -> macOS virtual key codes (ANSI layout).
enum KeyMap {
    static func code(for name: String) -> CGKeyCode? {
        let n = name.lowercased()
        if let c = named[n] { return CGKeyCode(c) }
        return nil
    }

    private static let named: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
        "backspace": kVK_Delete, "delete": kVK_ForwardDelete, "escape": kVK_Escape,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "comma": kVK_ANSI_Comma,
        "period": kVK_ANSI_Period, "slash": kVK_ANSI_Slash, "semicolon": kVK_ANSI_Semicolon,
        "quote": kVK_ANSI_Quote, "leftbracket": kVK_ANSI_LeftBracket, "rightbracket": kVK_ANSI_RightBracket,
        "backslash": kVK_ANSI_Backslash, "grave": kVK_ANSI_Grave,
    ]
}
