import Foundation

@main
struct ProtocolTests {
    static func main() throws {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: "ProtocolTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            count += 1
        }
        try expect(ProviderEnvelope.decode("{") == nil, "reject invalid JSON")
        try expect(ProviderEnvelope.decode("[]") == nil, "reject non-object")
        try expect(ProviderEnvelope.decode("{}") == nil, "require command")
        try expect(ProviderEnvelope.decode("{\"command\":42}") == nil, "require string command")
        try expect(ProviderEnvelope.decode(String(repeating: "x", count: 1024 * 1024 + 1)) == nil, "bound message size")
        let object = ProviderEnvelope.decode("{\"command\":\"get-version-info\",\"id\":17}")
        try expect(object != nil && ProviderEnvelope.requestID(object?["id"]) != nil, "accept existing numeric request ID")
        try expect(ProviderEnvelope.requestID("fixture-request") != nil, "preserve string request ID")
        try expect(ProviderEnvelope.requestID(nil) == nil, "reject missing request ID")
        try expect(ProviderEnvelope.requestID(NSNull()) == nil, "reject null ID")
        try expect(ProviderEnvelope.requestID(NSNumber(value: true)) == nil, "reject boolean ID")
        try expect(ProviderEnvelope.requestID(-1) == nil, "reject negative ID")
        try expect(ProviderEnvelope.requestID(1.5) == nil, "reject fractional ID")
        try expect(ProviderEnvelope.requestID("") == nil, "reject empty string ID")
        var backoff = ReconnectBackoff()
        var delays: [Double] = []
        for _ in 0..<8 { delays.append(backoff.next(jitter: 1)) }
        try expect(delays == [2,4,8,16,32,64,64,64], "bounded increasing reconnect delay")
        backoff.reset()
        try expect(backoff.next(jitter: 0) == 1.6, "jitter lower bound")
        backoff.reset()
        try expect(backoff.next(jitter: 2) == 2.4, "jitter upper bound")
        print("Protocol/backoff checks passed: \(count). Does not validate iOS runtime or registration.")
    }
}
