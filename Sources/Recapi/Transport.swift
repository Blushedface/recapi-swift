import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A failed call. `status` is nil when no HTTP response was received.
///
/// `code` is the API's error code (invalid_request, rate_limited,
/// quota_exceeded...) or a client one: network, timeout, invalid_response,
/// http_error, invalid_argument (a refused argument, nothing was sent).
public struct RecapiError: Error, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String
    public let status: Int?
    /// The Retry-After header in seconds, nil when absent or not seconds.
    public let retryAfter: Double?

    public init(code: String, message: String, status: Int? = nil, retryAfter: Double? = nil) {
        self.code = code
        self.message = message
        self.status = status
        self.retryAfter = retryAfter
    }

    static func invalid(_ message: String) -> RecapiError { RecapiError(code: "invalid_argument", message: message) }

    public var description: String {
        status.map { "recapi: \(code) (HTTP \($0)): \(message)" } ?? "recapi: \(code): \(message)"
    }

    /// Whether trying again later can succeed (quota_exceeded can't until it resets).
    public var isRetryable: Bool {
        if code == "network" || code == "timeout" { return true }
        if status == 429 { return code != "quota_exceeded" }
        return (status ?? 0) >= 500
    }

    /// Whether recapi couldn't answer in time or failed on its side.
    public var isOutage: Bool { code == "network" || code == "timeout" || (status ?? 0) >= 500 }

    /// Whether recommend and popular answer this failure with a list instead of
    /// throwing it. An outage, a limit or a revoked key can start on a live site
    /// with no deploy, and a page must not pay for it: stderr and the dashboard
    /// show it. What's left (a bad request, a reply that isn't the API's) can't
    /// start without a deploy, and a developer sees it on the first run.
    var spareThePage: Bool { isOutage || status == 429 || keyRefused }

    /// A key or shop recapi won't serve: any other call fails too.
    var keyRefused: Bool { status == 401 || status == 403 }
}

private let codeByStatus = [
    400: "invalid_request", 401: "unauthorized", 403: "forbidden", 404: "not_found", 413: "too_large",
    429: "rate_limited",
]

/// Refuses redirects: a 3xx (an http:// base URL sent on to https) fails like
/// a 4xx, or a DELETE would look done.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Percent-encodes everything but RFC 3986's unreserved characters.
func escape(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

extension RecapiClient {
    /// Sends one request within `timeout` seconds and returns a 2xx reply's
    /// JSON (nil for an empty body). Every failure is a RecapiError.
    func call(
        _ method: String, _ path: String, query: [String: String] = [:], body: JSONValue? = nil,
        timeout: Double
    ) async throws(RecapiError) -> JSONValue? {
        var query = query
        var headers = ["Accept": "application/json", "User-Agent": "recapi-swift/\(RecapiClient.version)"]
        // A public key travels in the URL only on GETs (CDN caching); the API
        // refuses a secret key there.
        if method == "GET" && key.hasPrefix(publicKeyPrefix) {
            query["key"] = key
        } else {
            headers["Authorization"] = "Bearer \(key)"
        }
        var target = base + path
        if !query.isEmpty {
            target += "?" + query.keys.sorted().map { "\(escape($0))=\(escape(query[$0]!))" }.joined(separator: "&")
        }
        guard let url = URL(string: target) else {
            throw RecapiError(code: "invalid_request", message: "bad URL \(target)")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            do {
                request.httpBody = try body.serialized()
            } catch {
                throw RecapiError(code: "invalid_request", message: "\(error)")
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await send(request, timeout: timeout)
        guard let http = response as? HTTPURLResponse else {
            throw RecapiError(code: "network", message: "not an HTTP response")
        }
        // A reply cut mid-body can read as whole: its length tells.
        if http.expectedContentLength >= 0 && Int64(data.count) != http.expectedContentLength {
            throw RecapiError(
                code: "network", message: "reply cut short: \(data.count) of \(http.expectedContentLength) bytes")
        }
        guard (200..<300).contains(http.statusCode) else { throw httpError(http, data) }
        if data.isEmpty { return nil }
        do {
            return try JSONValue.parse(data)
        } catch {
            throw RecapiError(code: "invalid_response", message: "malformed JSON reply: \(error)")
        }
    }

    /// Linux's URLSession ignores timeoutInterval, so the deadline is the
    /// client's own: a timer races the request and cancels it.
    private func send(_ request: URLRequest, timeout: Double) async throws(RecapiError) -> (Data, URLResponse) {
        let result = await withCheckedContinuation { (c: CheckedContinuation<Result<(Data, URLResponse), RecapiError>, Never>) in
            let once = Once(c)
            let task = session.dataTask(with: request) { data, response, error in
                if let response, error == nil {
                    once.resume(.success((data ?? Data(), response)))
                } else if let error = error as? URLError, error.code == .timedOut {
                    once.resume(.failure(RecapiError(code: "timeout", message: "no answer in time: \(error)")))
                } else {
                    once.resume(.failure(RecapiError(code: "network", message: "\(error.map { "\($0)" } ?? "no response")")))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.resume(.failure(RecapiError(code: "timeout", message: "no answer within \(timeout) s"))) {
                    task.cancel()
                }
            }
            task.resume()
        }
        return try result.get()
    }
}

/// Resumes a continuation once: the first of a reply and its timer wins.
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    @discardableResult
    func resume(_ value: T) -> Bool {
        let c: CheckedContinuation<T, Never>? = lock.locked {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
        return c != nil
    }
}

func httpError(_ response: HTTPURLResponse, _ data: Data) -> RecapiError {
    let payload = (try? JSONValue.parse(data))?["error"]
    let status = response.statusCode
    var code = payload?["code"]?.stringValue ?? ""
    if code.isEmpty { code = codeByStatus[status] ?? (status >= 500 ? "internal" : "http_error") }
    var message = payload?["message"]?.stringValue ?? ""
    if message.isEmpty { message = "HTTP \(status)" }
    var retryAfter: Double?
    if let header = response.value(forHTTPHeaderField: "Retry-After"),
        let seconds = Double(header.trimmingCharacters(in: .whitespaces)), seconds >= 0, seconds.isFinite
    {
        retryAfter = seconds
    }
    return RecapiError(code: code, message: message, status: status, retryAfter: retryAfter)
}

/// Items of a recommendation or popular reply; nil when one has no id.
func parseItems(_ raw: [JSONValue], slot: String) -> [Item]? {
    var items: [Item] = []
    for e in raw {
        guard let id = e["item_id"]?.stringValue else { return nil }
        var score = 0.0
        if case .number(let n)? = e["score"] { score = n }
        let s = e["slot"]?.stringValue ?? ""
        let metadata = e["metadata"]?.objectValue
        items.append(
            Item(
                itemID: id, score: score, slot: s.isEmpty ? slot : s,
                metadata: metadata?.isEmpty == false ? metadata : nil, why: e["why"]?.stringValue))
    }
    return items
}
