import Foundation
import CoreGraphics

/// Messages on the WebRTC data channel "ctl" (both directions). See docs/PROTOCOL.md.
/// Every message is a JSON object. Control messages have a "type" field, input messages a "t" field.

struct WindowInfo: Equatable {
    let id: UInt32          // CGWindowID
    let title: String
    let app: String
    let width: Double       // points
    let height: Double      // points

    var json: [String: Any] { ["id": id, "title": title, "app": app, "width": width, "height": height] }
}

/// Mac -> Quest.
enum ServerMessage {
    case hello(name: String, version: Int, maxWindows: Int)
    case windows([WindowInfo])
    /// slots[i] is the window currently streamed in video transceiver i (0 = empty).
    case slots([UInt32])
    case error(String)

    func json() -> Data {
        let o: [String: Any]
        switch self {
        case let .hello(name, version, maxWindows):
            o = ["type": "hello", "name": name, "version": version, "maxWindows": maxWindows]
        case let .windows(list):
            o = ["type": "windows", "windows": list.map(\.json)]
        case let .slots(ids):
            o = ["type": "slots", "slots": ids]
        case let .error(msg):
            o = ["type": "error", "message": msg]
        }
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }
}

/// Quest -> Mac.
enum ClientMessage {
    case listWindows
    case select(windowIds: [UInt32])
    case input(InputMessage)

    static func parse(_ data: Data) -> ClientMessage? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let input = InputMessage.parse(o) { return .input(input) }
        switch o["type"] as? String {
        case "listWindows":
            return .listWindows
        case "select":
            let ids = (o["windowIds"] as? [NSNumber])?.map { $0.uint32Value } ?? []
            return .select(windowIds: ids)
        default:
            return nil
        }
    }
}

/// Input events. Coordinates are normalized to the window: (0,0) top-left, (1,1) bottom-right.
enum InputMessage {
    case mouse(window: UInt32, x: Double, y: Double, action: String, button: Int)   // action: move|down|up
    case scroll(window: UInt32, x: Double, y: Double, dx: Double, dy: Double)       // pixels
    case key(key: String, down: Bool, mods: [String])                              // named key / letter
    case text(String)                                                              // unicode text to type

    static func parse(_ o: [String: Any]) -> InputMessage? {
        guard let t = o["t"] as? String else { return nil }
        func d(_ k: String) -> Double { (o[k] as? NSNumber)?.doubleValue ?? 0 }
        let w = (o["w"] as? NSNumber)?.uint32Value ?? 0
        switch t {
        case "mouse":
            return .mouse(window: w, x: d("x"), y: d("y"), action: o["a"] as? String ?? "move", button: Int(d("b")))
        case "scroll":
            return .scroll(window: w, x: d("x"), y: d("y"), dx: d("dx"), dy: d("dy"))
        case "key":
            guard let k = o["key"] as? String else { return nil }
            return .key(key: k, down: o["down"] as? Bool ?? true, mods: o["mods"] as? [String] ?? [])
        case "text":
            guard let s = o["s"] as? String else { return nil }
            return .text(s)
        default:
            return nil
        }
    }
}
