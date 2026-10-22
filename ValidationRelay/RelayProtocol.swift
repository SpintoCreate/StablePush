import Foundation
import CoreFoundation

// Payloads are used only to build protocol replies, never passed to the logger.
enum ProviderEnvelope {
    static func decode(_ text: String) -> [String: Any]? {
        guard let bytes = text.data(using: .utf8), bytes.count <= 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["command"] is String else { return nil }
        return object
    }

    static func requestID(_ value: Any?) -> Any? {
        if let text = value as? String, !text.isEmpty, text.utf8.count <= 256 { return text }
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite, number.doubleValue >= 0,
           number.doubleValue.rounded() == number.doubleValue { return number }
        return nil
    }
}

struct ReconnectBackoff {
    private(set) var seconds: Double = 2
    mutating func reset() { seconds = 2 }
    mutating func next(jitter: Double) -> Double {
        let delay = seconds * min(max(jitter, 0.8), 1.2)
        seconds = min(seconds * 2, 64)
        return delay
    }
}
