// Based on JJTech0130/ValidationRelay (James Gill, 2024).
import Foundation

enum ValidationFailure: Error {
    case identityUnavailable, storage, timeout, network(Int), http(Int)
    case invalidResponse, appleRejected(Int), nac(String, Int32)

    // Closed vocabulary + numeric codes only. No server bodies or error descriptions.
    var diagnostic: String {
        switch self {
        case .identityUnavailable: return "version-info: protected identity unavailable"
        case .storage: return "pairing: secure storage unavailable"
        case .timeout: return "validation: Apple HTTPS request timed out"
        case .network(let code): return "validation: Apple HTTPS transport failed (code \(code))"
        case .http(let code): return "validation: Apple HTTP response (status \(code)); body omitted"
        case .invalidResponse: return "validation: unexpected Apple response schema; body omitted"
        case .appleRejected(let code): return "validation: Apple initialization rejected (status \(code)); stopped; body omitted"
        case .nac(let stage, let code): return "validation: NAC \(stage) failed (code \(code))"
        }
    }
}

private final class HTTPSOnly: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Do not permit HTTPS downgrade or cross-origin redirects.
    }
    // System default certificate validation. No trust challenge override.
}

private final class HTTPResult {
    private let lock = NSLock()
    private var value: Result<(Data, HTTPURLResponse), Error>?
    func set(_ newValue: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
    func get() -> Result<(Data, HTTPURLResponse), Error>? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// Only invoked on validation.serial. Both network and semaphore waits are bounded.
// No callbacks need the blocked queue or main thread to complete.
private func appleRequest(_ request: URLRequest) throws -> Data {
    precondition(!Thread.isMainThread)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 12
    config.urlCache = nil
    config.httpCookieStorage = nil
    let delegate = HTTPSOnly()
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let gate = DispatchSemaphore(value: 0)
    let result = HTTPResult()
    let task = session.dataTask(with: request) { data, response, error in
        defer { gate.signal() }
        if let error = error {
            result.set(.failure(ValidationFailure.network((error as NSError).code)))
        } else if let data = data, let response = response as? HTTPURLResponse {
            result.set(.success((data, response)))
        } else { result.set(.failure(ValidationFailure.invalidResponse)) }
    }
    task.resume()
    guard gate.wait(timeout: .now() + 13) == .success else {
        task.cancel()
        throw ValidationFailure.timeout
    }
    guard let completed = result.get() else { throw ValidationFailure.invalidResponse }
    let (data, response) = try completed.get()
    guard (200..<300).contains(response.statusCode) else {
        if (400..<500).contains(response.statusCode) {
            throw ValidationFailure.appleRejected(response.statusCode)
        }
        throw ValidationFailure.http(response.statusCode)
    }
    guard !data.isEmpty, data.count <= 1024 * 1024 else { throw ValidationFailure.invalidResponse }
    return data
}

func getCertificate() throws -> Data {
    // No fallback to the upstream plaintext URL if TLS or the endpoint fails.
    let request = URLRequest(url: URL(string: "https://static.ess.apple.com/identity/validation/cert-1.0.plist")!)
    let data = try appleRequest(request)
    guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
          let certificate = plist["cert"] as? Data, !certificate.isEmpty else {
        throw ValidationFailure.invalidResponse
    }
    return certificate
}

func initializeValidation(_ input: Data) throws -> Data {
    var request = URLRequest(url: URL(string: "https://identity.ess.apple.com/WebObjects/TDIdentityService.woa/wa/initializeValidation")!)
    request.httpMethod = "POST"
    request.httpBody = try PropertyListSerialization.data(fromPropertyList: ["session-info-request": input], format: .xml, options: 0)
    request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
    let data = try appleRequest(request)
    guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
        throw ValidationFailure.invalidResponse
    }
    if let status = plist["status"] as? NSNumber, status.intValue != 0 {
        throw ValidationFailure.appleRejected(status.intValue)
    }
    guard let session = plist["session-info"] as? Data, !session.isEmpty else {
        throw ValidationFailure.invalidResponse
    }
    return session
}

enum ValidationEvent: String {
    case certificateRequest = "validation.certificate: HTTPS request started"
    case certificateReceived = "validation.certificate: certificate received"
    case nacInitialize = "validation.nac: initializing private service"
    case appleInitialize = "validation.apple-initialize: HTTPS request started"
    case appleAccepted = "validation.apple-initialize: session-info received; not an activation result"
    case signing = "validation.nac: establishing key and signing"
}

func generateValidationData(report: (ValidationEvent) -> Void = { _ in }) throws -> Data {
    report(.certificateRequest)
    let certificate = try getCertificate()
    report(.certificateReceived)
    report(.nacInitialize)
    var context: UInt64 = 0
    var sessionRequest: NSData?
    var status = NACInit(certificate, &context, &sessionRequest)
    guard status == 0, let request = sessionRequest, request.length > 0 else {
        throw ValidationFailure.nac("initialize", status)
    }
    report(.appleInitialize)
    let response = try initializeValidation(request as Data)
    report(.appleAccepted)
    report(.signing)
    status = NACKeyEstablishment(context, response)
    guard status == 0 else { throw ValidationFailure.nac("key-establishment", status) }
    var signature: NSData?
    status = NACSign(context, Data(), &signature)
    guard status == 0, let data = signature, data.length > 0 else {
        throw ValidationFailure.nac("sign", status)
    }
    return data as Data
}
