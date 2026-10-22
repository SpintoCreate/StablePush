// Based on JJTech0130/ValidationRelay, Relay.swift (James Gill, 2024).
import Foundation
import Network
import Security
import SwiftUI

// Read actual, stable device properties. Never synthesize or substitute identity.
func getIdentifiers() throws -> [String: String] {
    var system = utsname()
    guard uname(&system) == 0, let build = buildNumber() else {
        throw ValidationFailure.identityUnavailable
    }
    let machineSize = MemoryLayout.size(ofValue: system.machine)
    let machine = withUnsafePointer(to: &system.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: machineSize) {
            String(cString: $0)
        }
    }
    guard let serial = MGCopyAnswer("SerialNumber" as CFString)?.takeRetainedValue() as? String,
          let udid = MGCopyAnswer("UniqueDeviceID" as CFString)?.takeRetainedValue() as? String,
          !serial.isEmpty, !udid.isEmpty else { throw ValidationFailure.identityUnavailable }
    return ["hardware_version": machine, "software_name": "iPhone OS",
            "software_version": UIDevice.current.systemVersion, "software_build_id": build,
            "unique_device_id": udid, "serial_number": serial]
}

private struct Pairing: Codable {
    let url: String
    let code: String
    let secret: String
}

private enum PairingStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.jjtech.experiments.ValidationRelay.pairing",
         kSecAttrAccount as String: "provider",
         kSecAttrAccessGroup as String: "TROLLTROLL.dev.jjtech.experiments.ValidationRelay"]
    }
    static func load() throws -> Pairing? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else {
            throw ValidationFailure.storage
        }
        return try JSONDecoder().decode(Pairing.self, from: bytes)
    }
    static func save(_ value: Pairing) throws {
        let bytes = try JSONEncoder().encode(value)
        let changes: [String: Any] = [kSecValueData as String: bytes,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            changes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ValidationFailure.storage }
        } else if status != errSecSuccess { throw ValidationFailure.storage }
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ValidationFailure.storage }
    }
}

// All mutable connection/UI state is confined to the main queue. Private NAC work
// runs serially off the UI thread; callbacks from retired sockets are discarded.
final class RelayConnectionManager: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published var registrationCode = "None"
    @Published var connectionStatusMessage = "Disconnected"
    @Published var logItems = LogItems()
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var target: URL?
    private var pairing: Pairing?
    private var retry: DispatchWorkItem?
    private var deadline: DispatchWorkItem?
    private var heartbeat: Timer?
    private var backoff = ReconnectBackoff()
    private var active = false
    private var registered = false
    private var lastPong = Date()
    private var lastApplicationPing = Date()
    private var stableSince = Date()
    private var generation = UUID()
    private var validationBusy = false
    private var validationRequests = 0
    private let validationQueue = DispatchQueue(label: "validation.serial", qos: .userInitiated)
    private let pathMonitor = NWPathMonitor()
    private var pathAvailable = true

    override init() {
        super.init()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let wasAvailable = self.pathAvailable
                self.pathAvailable = path.status == .satisfied
                if !wasAvailable && self.pathAvailable && self.active && self.target != nil {
                    self.logItems.log("relay: network restored")
                    self.open()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "relay.path"))
    }

    func connect(_ url: URL) {
        disconnect()
        // Do not send pairing material to plaintext, user-info or URL-token endpoints.
        guard url.scheme?.lowercased() == "wss", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            connectionStatusMessage = "Use a wss:// relay URL without credentials or query parameters"
            logItems.log("relay: rejected insecure or invalid URL", isError: true)
            return
        }
        target = url
        do {
            pairing = try PairingStore.load()
            // Migrate all three legacy fields together; remove only after secure save.
            if pairing == nil {
                let defaults = UserDefaults.standard
                if let oldURL = defaults.string(forKey: "savedRegistrationURL"),
                   let code = defaults.string(forKey: "savedRegistrationCode"),
                   let secret = defaults.string(forKey: "savedRegistrationSecret"),
                   !oldURL.isEmpty, !code.isEmpty, !secret.isEmpty {
                    let previous = Pairing(url: oldURL, code: code, secret: secret)
                    try PairingStore.save(previous)
                    pairing = previous
                }
            }
            ["savedRegistrationURL", "savedRegistrationCode", "savedRegistrationSecret"].forEach {
                UserDefaults.standard.removeObject(forKey: $0)
            }
        } catch {
            halt("pairing: secure storage unavailable; unlock device and retry")
            return
        }
        backoff.reset()
        active = true
        open()
    }

    func disconnect() {
        active = false
        target = nil
        closeTransport()
        registrationCode = "None"
        connectionStatusMessage = "Disconnected"
    }

    func setForeground(_ foreground: Bool) {
        if foreground {
            active = true
            if target != nil { open() }
        } else {
            active = false
            closeTransport()
            connectionStatusMessage = "Paused in background; reopen for validation or renewal"
            logItems.log("renewal: provider paused; Android outcome not observable")
        }
    }

    func resetPairing() {
        disconnect()
        do {
            try PairingStore.clear()
            pairing = nil
            ["savedRegistrationURL", "savedRegistrationCode", "savedRegistrationSecret"].forEach {
                UserDefaults.standard.removeObject(forKey: $0)
            }
            logItems.log("pairing: cleared by user")
        } catch {
            connectionStatusMessage = "Could not clear secure pairing storage; unlock and retry"
            logItems.log("pairing: secure storage failure", isError: true)
        }
    }

    private func closeTransport() {
        generation = UUID()
        retry?.cancel(); retry = nil
        deadline?.cancel(); deadline = nil
        heartbeat?.invalidate(); heartbeat = nil
        registered = false
        let previous = socket
        socket = nil // Retire first so cancellation cannot schedule another reconnect.
        previous?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel(); session = nil
    }

    private func open() {
        guard active, let url = target else { return }
        closeTransport()
        guard pathAvailable else {
            connectionStatusMessage = "Waiting for network"
            return
        }
        logItems.log("relay: connecting with system TLS verification")
        connectionStatusMessage = "Connecting"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        // Do not impose a one-minute lifetime on a healthy upgraded WebSocket.
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        guard let session = session else { return }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 1024 * 1024
        socket = task
        task.resume()
        armDeadline(task, seconds: 20, event: "relay: connection deadline exceeded")
        receive(task)
    }

    private func armDeadline(_ task: URLSessionWebSocketTask, seconds: Double, event: String) {
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self, weak task] in
            guard let self = self, let task = task, self.socket === task else { return }
            self.reconnect(event)
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func reconnect(_ event: String) {
        guard active, target != nil else { return }
        // Reset only after a genuinely stable registered connection.
        if registered && Date().timeIntervalSince(stableSince) >= 60 { backoff.reset() }
        closeTransport()
        registrationCode = "None"
        logItems.log(event, isError: true)
        connectionStatusMessage = "Reconnecting; saved pairing retained"
        let wait = backoff.next(jitter: Double.random(in: 0.8...1.2))
        let work = DispatchWorkItem { [weak self] in self?.open() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func halt(_ event: String) {
        active = false
        target = nil // Do not retry an Apple rejection on foreground/network transitions.
        closeTransport()
        registrationCode = "None"
        connectionStatusMessage = event + "; switch Relay off/on after investigation"
        logItems.log(event, isError: true)
    }

    private func transportFailure(_ error: Error) {
        let code = (error as NSError).code
        let domain = (error as NSError).domain
        // Never print localizedDescription/userInfo: either can contain URLs or secrets.
        if domain == NSURLErrorDomain && [-1200, -1201, -1202, -1203, -1204, -1205, -1206].contains(code) {
            halt("relay: TLS verification failed (code \(code))")
        } else {
            reconnect("relay: transport failure (code \(code))")
        }
    }

    private func send(_ object: [String: Any], on task: URLSessionWebSocketTask) {
        guard socket === task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            halt("relay: response serialization failed")
            return
        }
        task.send(.string(text)) { [weak self, weak task] error in
            DispatchQueue.main.async {
                guard let self = self, let task = task, self.socket === task else { return }
                if let error = error { self.transportFailure(error) }
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            DispatchQueue.main.async {
                guard let self = self, let task = task, self.socket === task else { return }
                switch result {
                case .failure(let error): self.transportFailure(error)
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(text, on: task)
                    case .data: self.reconnect("relay: unexpected binary frame")
                    @unknown default: self.reconnect("relay: unsupported frame")
                    }
                    if self.socket === task { self.receive(task) }
                }
            }
        }
    }

    private func handle(_ text: String, on task: URLSessionWebSocketTask) {
        guard let object = ProviderEnvelope.decode(text),
              let command = object["command"] as? String else {
            reconnect("relay: malformed protocol envelope")
            return
        }
        if !registered, let data = object["data"] as? [String: Any],
           let code = data["code"] as? String, let secret = data["secret"] as? String,
           !code.isEmpty, !secret.isEmpty, let url = target {
            let record = Pairing(url: url.absoluteString, code: code, secret: secret)
            do { try PairingStore.save(record) } catch {
                halt("pairing: secure save failed; pairing not acknowledged locally")
                return
            }
            pairing = record
            registrationCode = code // Visible only in pairing UI, never in diagnostics.
            registered = true
            stableSince = Date()
            deadline?.cancel(); deadline = nil
            connectionStatusMessage = "Paired to relay; keep app foreground for requests"
            logItems.log("relay: pairing acknowledged and saved")
            logItems.log("apple-activation: performed by Android; response not visible to provider")
            return
        }
        if command == "pong" { return }
        if command == "ping" { send(["command": "pong"], on: task); return }
        guard registered else { reconnect("relay: expected pairing acknowledgement"); return }
        guard command == "get-version-info" || command == "get-validation-data" else {
            // Never echo/log arbitrary untrusted command strings or payloads.
            logItems.log("relay: unsupported command ignored", isError: true)
            return
        }
        guard let id = ProviderEnvelope.requestID(object["id"]) else {
            reconnect("relay: request ID missing or invalid")
            return
        }
        if command == "get-version-info" {
            logItems.log("version-info: request received")
            do {
                let identifiers = try getIdentifiers()
                send(["command": "response", "id": id, "data": ["versions": identifiers]], on: task)
                logItems.log("version-info: response queued; identity omitted from diagnostics")
            } catch { halt("version-info: protected identity unavailable; verify TrollStore entitlements") }
            return
        }
        guard !validationBusy else {
            // No wire error extension is defined; close rather than return fake validation.
            reconnect("validation: busy; overlapping request rejected")
            return
        }
        validationBusy = true
        validationRequests += 1
        logItems.log("validation: request started")
        if validationRequests > 1 {
            logItems.log("renewal: repeat validation request; purpose and Android outcome unknown")
        }
        let token = generation
        validationQueue.async { [weak self, weak task] in
            let result = Result {
                try generateValidationData { event in
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.generation == token else { return }
                        self.logItems.log(event.rawValue)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.validationBusy = false
                guard let task = task, self.generation == token, self.socket === task else { return }
                switch result {
                case .success(let data):
                    self.send(["command": "response", "id": id,
                               "data": ["data": data.base64EncodedString()]], on: task)
                    self.logItems.log("validation: generated; response queued")
                    self.logItems.log("renewal: validation delivery queued; registration success not observable")
                case .failure(let error):
                    let failure = error as? ValidationFailure ?? .invalidResponse
                    self.logItems.log(failure.diagnostic, isError: true)
                    // Fail closed for Apple rejection, NAC/access or protocol failures.
                    self.halt("validation: stopped; inspect redacted stage diagnostic")
                }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard socket === webSocketTask else { return }
        logItems.log("relay: TLS WebSocket connected")
        connectionStatusMessage = "Registering provider"
        var data: [String: String] = [:]
        if let pairing = pairing, pairing.url == target?.absoluteString {
            data = ["code": pairing.code, "secret": pairing.secret]
            logItems.log("pairing: resuming saved pairing")
        }
        send(["command": "register", "data": data], on: webSocketTask)
        armDeadline(webSocketTask, seconds: 15, event: "pairing: acknowledgement deadline exceeded")
        lastPong = Date()
        lastApplicationPing = Date.distantPast
        heartbeat = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self, weak webSocketTask] _ in
            guard let self = self, let task = webSocketTask, self.socket === task else { return }
            guard Date().timeIntervalSince(self.lastPong) < 70 else {
                self.reconnect("relay: heartbeat deadline exceeded")
                return
            }
            // Existing relayserver protocol uses application ping/pong as well.
            if self.registered && Date().timeIntervalSince(self.lastApplicationPing) >= 50 {
                self.send(["command": "ping"], on: task)
                self.lastApplicationPing = Date()
            }
            task.sendPing { [weak self, weak task] error in
                DispatchQueue.main.async {
                    guard let self = self, let task = task, self.socket === task else { return }
                    if let error = error { self.transportFailure(error) }
                    else { self.lastPong = Date() }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard socket === webSocketTask else { return }
        reconnect("relay: closed (code \(closeCode.rawValue))") // Never log close reason.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard socket === task else { return }
        if let error = error { transportFailure(error) }
        else { reconnect("relay: transport completed") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Do not move provider credentials to a different endpoint.
    }
    // No authentication challenge handler: URLSession performs normal system trust validation.
}
