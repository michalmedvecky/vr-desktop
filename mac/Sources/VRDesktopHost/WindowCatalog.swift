import Foundation
import ScreenCaptureKit
import AppKit

/// Lists shareable on-screen windows via ScreenCaptureKit.
final class WindowCatalog {
    private(set) var windows: [UInt32: SCWindow] = [:]

    /// Refreshes the window list. Filters out tiny, off-screen, untitled and own windows.
    func refresh() async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var map: [UInt32: SCWindow] = [:]
        var list: [WindowInfo] = []
        for w in content.windows {
            guard w.windowLayer == 0,
                  w.frame.width >= 120, w.frame.height >= 80,
                  let app = w.owningApplication,
                  app.processID != ownPID else { continue }
            let title = w.title ?? ""
            // Skip system chrome (menu bar items, Dock, etc.)
            if ["Window Server", "Dock", "Control Center", "Notification Center"].contains(app.applicationName) { continue }
            map[w.windowID] = w
            list.append(WindowInfo(id: w.windowID,
                                   title: title.isEmpty ? app.applicationName : title,
                                   app: app.applicationName,
                                   width: Double(w.frame.width),
                                   height: Double(w.frame.height)))
        }
        windows = map
        return list.sorted { ($0.app, $0.title) < ($1.app, $1.title) }
    }

    func window(_ id: UInt32) -> SCWindow? { windows[id] }

    /// Current window bounds in global display coordinates (points, origin top-left of main display).
    /// Uses CGWindowList so the value is fresh even if the window was moved after refresh().
    static func currentBounds(of id: UInt32) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
              let first = info.first,
              let bounds = first[kCGWindowBounds as String] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as! CFDictionary)
    }

    static func ownerPID(of id: UInt32) -> pid_t? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
              let pid = info.first?[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
        return pid_t(pid.int32Value)
    }
}
