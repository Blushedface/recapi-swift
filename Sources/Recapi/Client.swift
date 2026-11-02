import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The recommended level scale (docs/api.md "Interaction levels").
public enum Level {
    public static let view = 3
    public static let cart = 5
    public static let purchase = 10
    /// Never recommend the item to this user again until a positive event on it.
    public static let reject = -10
    public static let names = ["view": view, "cart": cart, "purchase": purchase, "reject": reject]

    /// The level a name stands for: view, cart, purchase or reject.
    public static func parse(_ name: String) throws(RecapiError) -> Int {
        guard let level = names[name] else {
            throw .invalid("level \"\(name)\" is not view, cart, purchase or reject")
        }
        return level
    }
}

/// One recommended or popular item.
public struct Item: Sendable, Equatable {
    public let itemID: String
    public let score: Double
    /// exploit, explore or backfill.
    public let slot: String
    /// The object stored with the item (metadata of PUT /v1/items: name,
    /// picture, link, price...), nil when it has none.
    public let metadata: [String: JSONValue]?
    /// A reason code to turn into a label for visitors: "for_you",
    /// "similar", "next", "bought_together", "trending", "popular", "new",
    /// "explore" or "more" (docs/api.md "Reason codes"), nil when the API sent
    /// none. New codes may be added: show nothing for an unknown one.
    public let why: String?
}

/// A recommendation list. Fallback lists are popular items with no id.
public struct Recommendations: Sendable {
    public let recommendationID: String?
    public let fallback: Bool
    public let items: [Item]
}

/// Asks for recommendations for a user (or a visitor's anonID). A nil count
/// is the API's default (10); a nil exclude sends none.
public struct RecommendRequest: Sendable {
    public var userID: String?
    public var anonID: String?
    public var count: Int?
    public var placement: String?
    public var tagsAny: [String] = []
    public var tagsAll: [String] = []
    public var exclude: [String]?
    public var contextItemID: String?
    /// The share of explore slots, nil for the tenant's setting.
    public var discovery: Double?

    public init(
        userID: String? = nil, anonID: String? = nil, count: Int? = nil, placement: String? = nil,
        tagsAny: [String] = [], tagsAll: [String] = [], exclude: [String]? = nil, contextItemID: String? = nil,
        discovery: Double? = nil
    ) {
        self.userID = userID
        self.anonID = anonID
        self.count = count
        self.placement = placement
        self.tagsAny = tagsAny
        self.tagsAll = tagsAll
        self.exclude = exclude
        self.contextItemID = contextItemID
        self.discovery = discovery
    }
}

/// An item for upsertItems (PUT /v1/items in docs/api.md).
public struct CatalogItem: Sendable {
    public var itemID: String
    public var tags: [String]
    /// nil is the API's default, true.
    public var active: Bool?
    public var publishedAt: Date?
    public var boost: Double?
    public var title: String?
    /// Comes back with every recommendation of the item.
    public var metadata: [String: JSONValue]?

    public init(
        itemID: String, tags: [String] = [], active: Bool? = nil, publishedAt: Date? = nil, boost: Double? = nil,
        title: String? = nil, metadata: [String: JSONValue]? = nil
    ) {
        self.itemID = itemID
        self.tags = tags
        self.active = active
        self.publishedAt = publishedAt
        self.boost = boost
        self.title = title
        self.metadata = metadata
    }

    var wire: JSONValue {
        var out: [String: JSONValue] = ["item_id": .string(itemID)]
        if !tags.isEmpty { out["tags"] = JSONValue.strings(tags) }
        if let active { out["active"] = .bool(active) }
        if let publishedAt { out["published_at"] = .string(timestamp(publishedAt)) }
        if let boost { out["boost"] = .number(boost) }
        if let title { out["title"] = .string(title) }
        if let metadata { out["metadata"] = .object(metadata) }
        return .object(out)
    }
}

/// RFC 3339 in UTC with milliseconds, as the other libraries send.
func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

/// The recapi client: history, events and recommendations. It behaves like
/// the other server libraries (sdk/go, sdk/python); spec/client_vectors.json
/// pins what they must agree on. Safe for concurrent use: create one per
/// process. Tracked events go out in the background, within `flushInterval`;
/// `close()` sends what is left (an app going to the background, a server
/// shutting down).
public final class RecapiClient: @unchecked Sendable {
    /// Sent in the User-Agent.
    public static let version = "0.1.4"
    /// API limits (docs/api.md).
    public static let maxEventsPerRequest = 1000
    public static let maxItemsPerRequest = 1000
    public static let maxExclude = 500
    public static let defaultCount = 10
    public static let maxCount = 100
    /// A widget still empty after 1.5 s has lost the user: recommend gives up
    /// then and falls back, whatever the general timeout (which suits events).
    public static let recommendTimeout = 1.5
    /// Events waiting for a send: a minute-long outage at 150 events/s fits.
    static let maxQueue = 10_000
    /// How many times a retryable failure is tried again, after a jittered
    /// exponential backoff (or the Retry-After) of at most 8 s.
    public static let retries = 3
    static let retryBase = 0.5
    static let retryMax = 8.0
    /// The sender's longest wait after failed sends, in seconds.
    static let maxFlushBackoff = 60.0
    // Attribution windows, as in the JS SDK: an event on a shown item within
    // 30 minutes of the display is the click; after a click, that item's
    // events are attributed for 24 hours.
    static let displayWindowMs: Int64 = 30 * 60 * 1000
    static let clickWindowMs: Int64 = 24 * 60 * 60 * 1000
    static let maxShownItems = 100

    let key: String
    let base: String
    let publicKeyPrefix = "rk_pub_"
    let store: RecapiStore
    let timeout: Double
    let maxBatch: Int
    let interval: Double
    let prefix: String
    let session: URLSession

    /// Guards the store's read-modify-writes, the queue, failures and started.
    let lock = NSLock()
    var queue: [JSONValue] = []
    /// Sends failed in a row: the sender waits twice as long after each.
    var failures = 0
    private var started: Bool
    /// One send at a time, so batches go out in order.
    let sending = AsyncLock()
    /// A full batch wakes the sender; close() stops it.
    let wake = Signal(latch: false)
    let closed = Signal(latch: true)

    /// The clock in unix ms; tests replace it.
    var now: @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
    /// The backoff sleep in seconds, true when cut short (`untilClosed`: by
    /// close(); otherwise by the task's cancellation); tests replace it.
    var sleep: @Sendable (_ seconds: Double, _ untilClosed: Bool) async -> Bool
    /// The backoff's jitter, in 0..<1; tests replace it.
    var random: @Sendable () -> Double = { Double.random(in: 0..<1) }

    /// - Parameters:
    ///   - apiKey: a secret key (rk_sec_...): a server can then restore a
    ///     user's history from recapi when the store lacks it.
    ///   - baseURL: your recapi API origin, e.g. https://api.example.com.
    ///   - store: per-user history and attribution state; default an
    ///     in-memory MemoryStore(). Pass a shared one when several processes
    ///     serve the same users, and a FileStore() in an app, so its
    ///     visitor's history survives the app being closed.
    ///   - timeout: per request in seconds (recommend uses at most 1.5 s).
    ///   - maxBatch: events per request, at most (and by default) 1,000.
    ///   - flushInterval: seconds between background sends, default 2; a
    ///     full batch goes at once.
    public convenience init(
        apiKey: String, baseURL: String, store: RecapiStore? = nil, timeout: Double = 5, maxBatch: Int? = nil,
        flushInterval: Double = 2
    ) throws(RecapiError) {
        try self.init(
            apiKey: apiKey, baseURL: baseURL, store: store, timeout: timeout, maxBatch: maxBatch,
            flushInterval: flushInterval, configuration: .ephemeral, sender: true)
    }

    /// `sender: false` leaves sending to flush() and close() (tests).
    init(
        apiKey: String, baseURL: String, store: RecapiStore?, timeout: Double, maxBatch: Int?,
        flushInterval: Double, configuration: URLSessionConfiguration, sender: Bool
    ) throws(RecapiError) {
        guard !apiKey.isEmpty else { throw .invalid("apiKey is required") }
        var trimmed = baseURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme ?? ""),
            !(url.host ?? "").isEmpty
        else { throw .invalid("baseURL must be an http(s) URL") }
        key = apiKey
        base = trimmed
        self.store = store ?? MemoryStore()
        self.timeout = timeout > 0 ? timeout : 5
        self.maxBatch = min(max(1, maxBatch ?? RecapiClient.maxEventsPerRequest), RecapiClient.maxEventsPerRequest)
        interval = flushInterval > 0 ? flushInterval : 2
        started = !sender
        sleep = RecapiClient.sleeper(closed)
        // Two environments' keys may share one Redis: their users must not mix.
        prefix = "recapi:" + sha256Hex(apiKey).prefix(12) + ":"
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    static func sleeper(_ closed: Signal) -> @Sendable (Double, Bool) async -> Bool {
        { seconds, untilClosed in
            if untilClosed { return await closed.wait(seconds) }
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
            return Task.isCancelled
        }
    }

    // MARK: - events

    /// Records an interaction: the user's history changes at once and the
    /// event is queued, sent in the background. `level` is an integer from
    /// -10 to 10 (Level.view, .cart, .purchase, .reject); `recommendationID`
    /// overrides the automatic attribution. Throws only on an invalid argument.
    public func track(
        itemID: String, level: Int, userID: String? = nil, anonID: String? = nil, recommendationID: String? = nil
    ) throws(RecapiError) {
        guard (-10...10).contains(level) else { throw .invalid("level must be an integer from -10 to 10") }
        guard isID(itemID) else { throw invalidID("item_id") }
        try checkIDs(["user_id": userID, "anon_id": anonID, "recommendation_id": recommendationID])
        let t = now()
        var attributed = recommendationID
        lock.locked {
            guard let key = userKey(userID, anonID) else { return }
            var state = load(key)
            state.history.apply(itemID, level: level, t: Double(t))
            if let i = state.find(itemID), state.shown[i].attributable(t) {
                // An explicit id of the recommendation that showed the item is
                // still the click on it; another id leaves the entry alone.
                if recommendationID == nil || state.shown[i].recID == recommendationID {
                    if level > 0 && state.shown[i].clicked == nil { state.shown[i].clicked = t }
                    attributed = state.shown[i].recID
                }
            }
            save(key, state, now: t)
        }
        var event: [String: JSONValue] = [
            "item_id": .string(itemID), "level": .number(Double(level)),
            "timestamp": .string(timestamp(Date(timeIntervalSince1970: Double(t) / 1000))),
            "event_id": .string(UUID().uuidString.lowercased()),
        ]
        if let userID { event["user_id"] = .string(userID) }
        if let anonID { event["anon_id"] = .string(anonID) }
        if let attributed { event["recommendation_id"] = .string(attributed) }
        enqueue(.object(event))
    }

    func enqueue(_ event: JSONValue) {
        let isClosed = closed.isFired
        lock.locked {
            if !started && !isClosed {
                started = true
                startSender()
            }
            queue.append(event)
            dropOverflow()
            if queue.count >= maxBatch { wake.fire() }
        }
        if isClosed { Task { _ = await self.drain(retry: false) } }
    }

    /// Runs with the lock held. The oldest go first: the newest events say
    /// most about the user now.
    private func dropOverflow() {
        if queue.count > RecapiClient.maxQueue { queue.removeFirst(queue.count - RecapiClient.maxQueue) }
    }

    /// Events waiting for a send.
    public var queued: Int { lock.locked { queue.count } }

    /// Sends every queued event now, `maxBatch` per request, each retried
    /// up to 3 times (the end of a job, or before a test reads the API). A
    /// batch refused for good (4xx) is dropped; one that may succeed later
    /// (network, 5xx, 429) stays queued with the rest, for the sender, and
    /// the error is thrown. Event ids make a resend harmless.
    public func flush() async throws(RecapiError) {
        let error = await drain(retry: true)
        syncStore()
        if let error { throw error }
    }

    /// Stops the sender and sends what is queued, one try per batch, so an
    /// exit never waits on a recapi outage. Events tracked afterwards are
    /// sent at once, one try each.
    public func close() async {
        // Also ends a send's retry sleep, so close waits for at most one try.
        let first = closed.fire()
        wake.fire()
        if first {
            _ = await drain(retry: false)
            syncStore()
        }
    }

    // An app calls flush or close as it goes to the background: its visitor's
    // state must be on disk before the system may kill it.
    private func syncStore() { (store as? FileStore)?.flush() }

    /// The sender: every interval, a full batch at once, and after failed
    /// sends every 2, 4, 8... intervals up to a minute. It holds the client
    /// weakly: a client dropped without close() stops it at its next turn.
    private func startSender() {
        let wake = wake, closed = closed
        Task.detached { [weak self] in
            while let delay = self?.senderDelay() {
                let deadline = DispatchTime.now() + delay
                var woken = await wake.wait(delay)
                // A full batch goes at once, except after a failure: then the
                // backoff holds, or a down API would be hammered.
                while woken, !closed.isFired, self?.fullBatchReady() == false {
                    let left = Int64(deadline.uptimeNanoseconds) - Int64(DispatchTime.now().uptimeNanoseconds)
                    woken = await wake.wait(Double(left) / 1e9)
                }
                if closed.isFired { return }
                _ = await self?.drain(retry: true)
            }
        }
    }

    func senderDelay() -> Double {
        lock.locked {
            var delay = interval
            var i = 0
            while i < failures && delay < RecapiClient.maxFlushBackoff {
                delay *= 2
                i += 1
            }
            return min(delay, RecapiClient.maxFlushBackoff)
        }
    }

    private func fullBatchReady() -> Bool { lock.locked { failures == 0 && queue.count >= maxBatch } }

    /// Sends the queue, one batch at a time; returns the last failure.
    func drain(retry: Bool) async -> RecapiError? {
        await sending.acquire()
        defer { sending.release() }
        var dropped: RecapiError?
        while true {
            let batch: [JSONValue] = lock.locked {
                let n = min(queue.count, maxBatch)
                defer { queue.removeFirst(n) }
                return Array(queue.prefix(n))
            }
            if batch.isEmpty { return dropped }
            do throws(RecapiError) {
                try await sendEvents(batch, retry: retry)
                lock.locked { failures = 0 }
            } catch where error.isRetryable {
                // The batch goes back first.
                lock.locked {
                    queue.insert(contentsOf: batch, at: 0)
                    dropOverflow()
                    failures += 1
                }
                return error
            } catch {
                dropped = error
            }
        }
    }

    private func sendEvents(_ events: [JSONValue], retry: Bool) async throws(RecapiError) {
        let body = JSONValue.object(["events": .array(events)])
        do throws(RecapiError) {
            if retry {
                _ = try await withRetry(untilClosed: true) {
                    try await self.call("POST", "/v1/events", body: body, timeout: self.timeout)
                }
            } else {
                _ = try await call("POST", "/v1/events", body: body, timeout: timeout)
            }
        } catch where error.status == 413 && events.count >= 2 {
            // Over the API's body limit (ids mostly quotes or backslashes,
            // which JSON escapes): halves fit where the whole didn't. If the
            // second half fails, the batch is kept whole; event ids make the
            // resend harmless.
            let half = events.count / 2
            try await sendEvents(Array(events[..<half]), retry: retry)
            try await sendEvents(Array(events[half...]), retry: retry)
        }
    }

    /// Calls fn, trying a retryable failure again after a jittered
    /// exponential backoff; Retry-After wins over it, and both are capped at
    /// 8 s. A sleep cut short returns the last error.
    ///
    /// fn throws only RecapiError, but its type says plain `throws`: a
    /// typed-throws function type needs the Swift 6 runtime (iOS 18, macOS
    /// 15) in some uses, and the package supports iOS 15 and macOS 12.
    func withRetry<T>(untilClosed: Bool, _ fn: () async throws -> T) async throws(RecapiError) -> T {
        var attempt = 0
        while true {
            do {
                return try await fn()
            } catch {
                let error = error as? RecapiError ?? RecapiError(code: "internal", message: "\(error)")
                guard attempt < RecapiClient.retries && error.isRetryable else { throw error }
                var wait = RecapiClient.retryBase * pow(2, Double(attempt)) * (0.5 + random() / 2)
                if let after = error.retryAfter { wait = after }
                if await sleep(min(RecapiClient.retryMax, wait), untilClosed) { throw error }
                attempt += 1
            }
        }
    }

    // MARK: - recommendations

    /// Personalised recommendations for a user (or a visitor's anonID).
    ///
    /// It sends the history from the store; without one, recapi uses its
    /// stored history for userID and returns it for the store. A history the
    /// store started without it (a track or identify came first) gets
    /// recapi's fetched once, within the same deadline, and merged in. No
    /// retry, at most 1.5 s: on a network error, timeout or 5xx it returns
    /// popular items (fallback, no id). If those fail too (recapi is down),
    /// the list is empty: hide the slot. A 4xx or 429 is thrown: a fallback
    /// would hide an integration bug or a plan limit.
    public func recommend(_ r: RecommendRequest) async throws(RecapiError) -> Recommendations {
        try checkIDs(["user_id": r.userID, "anon_id": r.anonID])
        let limit = min(timeout, RecapiClient.recommendTimeout)
        // The restore and the recommendation share one deadline.
        let deadline = DispatchTime.now() + limit
        let left = { max(0, Double(Int64(deadline.uptimeNanoseconds) - Int64(DispatchTime.now().uptimeNanoseconds)) / 1e9) }
        let key = userKey(r.userID, r.anonID)
        let t = now()
        var state = key.map { k in lock.locked { load(k) } } ?? UserState()
        if let userID = r.userID, let key, !state.restored, !state.history.isEmpty, !self.key.hasPrefix(publicKeyPrefix) {
            // Half the time left, so the recommendation itself still fits.
            state = await restore(key, userID, state, t: t, timeout: left() / 2)
        }
        let (history, recent, rejected) = state.history.wire(now: Double(t))
        let exclude = withRejected(r.exclude, rejected)
        var body: [String: JSONValue] = ["history": .array(history), "recent": JSONValue.strings(recent)]
        if let v = r.userID { body["user_id"] = .string(v) }
        if let v = r.anonID { body["anon_id"] = .string(v) }
        if let v = r.placement { body["placement"] = .string(v) }
        if let v = r.contextItemID { body["context_item_id"] = .string(v) }
        if let v = r.count { body["count"] = .number(Double(v)) }
        if !r.tagsAny.isEmpty { body["tags_any"] = JSONValue.strings(r.tagsAny) }
        if !r.tagsAll.isEmpty { body["tags_all"] = JSONValue.strings(r.tagsAll) }
        if let exclude { body["exclude"] = JSONValue.strings(exclude) }
        if let v = r.discovery { body["discovery"] = .number(v) }

        let reply: JSONValue?
        let items: [Item]
        let recID: String
        do throws(RecapiError) {
            reply = try await call("POST", "/v1/recommendations", body: .object(body), timeout: left())
            guard let id = reply?["recommendation_id"]?.stringValue, let raw = reply?["items"]?.arrayValue,
                let parsed = parseItems(raw, slot: "exploit")
            else { throw RecapiError(code: "invalid_response", message: "malformed recommendations response") }
            (recID, items) = (id, parsed)
        } catch where error.isOutage {
            return await fallback(r, exclude: exclude ?? [], timeout: limit)
        }

        if let key {
            lock.locked {
                var state = load(key)
                for item in items { state.show(ShownItem(item: item.itemID, recID: recID, shown: t)) }
                if state.shown.count > RecapiClient.maxShownItems {
                    state.shown.removeFirst(state.shown.count - RecapiClient.maxShownItems)
                }
                // Only trusted when we sent nothing; merged, never replacing
                // what was tracked while the request was in flight, and only
                // once: a concurrent first call may have merged it already.
                let done = state.restored && !state.history.isEmpty
                if history.isEmpty && recent.isEmpty, let snapshot = reply?["history"], snapshot.objectValue != nil,
                    !done
                {
                    state.history = state.history.merged(snapshot: History(snapshot: snapshot), now: Double(t))
                    state.restored = true
                }
                save(key, state, now: t)
            }
        }
        return Recommendations(recommendationID: recID, fallback: false, items: items)
    }

    /// Answers a failed recommend with popular items, minus the excluded
    /// ones: a few more are asked for, up to the API's 100.
    private func fallback(_ r: RecommendRequest, exclude: [String], timeout: Double) async -> Recommendations {
        let n = r.count ?? RecapiClient.defaultCount
        var skip = Set(exclude)
        if let item = r.contextItemID { skip.insert(item) }
        guard
            let popular = try? await popular(
                count: min(n + skip.count, RecapiClient.maxCount), tagsAny: r.tagsAny, tagsAll: r.tagsAll,
                timeout: timeout)
        else {
            // recapi is down altogether: an empty list the page can hide beats
            // an error that fails the whole page.
            return Recommendations(recommendationID: nil, fallback: true, items: [])
        }
        let items = popular.filter { !skip.contains($0.itemID) }.prefix(n)
        return Recommendations(recommendationID: nil, fallback: true, items: Array(items))
    }

    /// Merges recapi's stored history into a local one that lacks it (a fresh
    /// store). The recommendation's reply carries it only when the request
    /// sends no history, which would drop this one. So it is asked for apart,
    /// once: a failure leaves the state as it was, to be tried on the next call.
    private func restore(_ key: String, _ userID: String, _ state: UserState, t: Int64, timeout: Double) async
        -> UserState
    {
        let query = state.anonID.map { ["anon_id": $0] } ?? [:]
        let path = "/v1/users/\(pathEscape(userID))/history"
        guard let snapshot = try? await call("GET", path, query: query, timeout: timeout),
            snapshot.objectValue != nil
        else { return state }
        return lock.locked {
            var state = load(key)
            // A concurrent first call may have merged it already.
            if !state.restored {
                state.history = state.history.merged(snapshot: History(snapshot: snapshot), now: Double(t))
                state.restored = true
                state.anonID = nil
                save(key, state, now: t)
            }
            return state
        }
    }

    /// For a login: the visitor's history and shown items become the user's.
    /// They are merged into what the store has for userID (scores add up, as
    /// in the history spec), then the visitor's entry is deleted. Without it,
    /// a visitor's clicks stop counting once they log in.
    public func identify(anonID: String, userID: String) throws(RecapiError) {
        guard isID(anonID) else { throw invalidID("anon_id") }
        guard isID(userID) else { throw invalidID("user_id") }
        let visitor = userKey(nil, anonID)!, user = userKey(userID, nil)!
        let t = now()
        lock.locked {
            let guest = load(visitor)
            if guest.history.isEmpty && guest.history.rejected.isEmpty && guest.shown.isEmpty { return }
            var state = load(user)
            state.history = state.history.merged(with: guest.history, now: Double(t))
            // recapi's snapshot, fetched later, holds this visitor's browsing too.
            if !state.restored { state.anonID = anonID }
            // Oldest display first, as recommend keeps them; an item's later display wins.
            let shown = (state.shown + guest.shown).enumerated()
                .sorted { $0.element.shown != $1.element.shown ? $0.element.shown < $1.element.shown : $0.offset < $1.offset }
            state.shown = []
            for s in shown { state.show(s.element) }
            save(user, state, now: t)
            try? store.delete(visitor)
        }
    }

    /// Non-personalised popular items, for pages without a user (no retry).
    public func popular(count: Int? = nil, tagsAny: [String] = [], tagsAll: [String] = []) async throws(RecapiError)
        -> [Item]
    {
        try await popular(count: count ?? RecapiClient.defaultCount, tagsAny: tagsAny, tagsAll: tagsAll, timeout: timeout)
    }

    private func popular(count: Int, tagsAny: [String], tagsAll: [String], timeout: Double) async throws(RecapiError)
        -> [Item]
    {
        var query = ["count": String(count)]
        if !tagsAny.isEmpty { query["tags_any"] = tagsAny.joined(separator: ",") }
        if !tagsAll.isEmpty { query["tags_all"] = tagsAll.joined(separator: ",") }
        let reply = try await call("GET", "/v1/popular", query: query, timeout: timeout)
        guard let raw = reply?["items"]?.arrayValue, let items = parseItems(raw, slot: "backfill") else {
            throw RecapiError(code: "invalid_response", message: "malformed popular response")
        }
        return items
    }

    // MARK: - catalog and users

    /// Creates or replaces items, 1,000 per request, retried like events.
    /// Returns how many were stored; an invalid item fails, and nothing of
    /// its batch is stored.
    public func upsertItems(_ items: [CatalogItem]) async throws(RecapiError) -> Int {
        var upserted = 0
        for start in stride(from: 0, to: items.count, by: RecapiClient.maxItemsPerRequest) {
            let batch = items[start..<min(start + RecapiClient.maxItemsPerRequest, items.count)]
            let body = JSONValue.object(["items": .array(batch.map(\.wire))])
            let reply = try await withRetry(untilClosed: false) {
                try await self.call("POST", "/v1/items:batch", body: body, timeout: self.timeout)
            }
            if case .number(let n)? = reply?["upserted"] { upserted += Int(n) }
        }
        return upserted
    }

    /// Erases a user's events in recapi (GDPR) and their state in the store.
    public func deleteUser(_ userID: String) async throws(RecapiError) {
        guard isID(userID) else { throw invalidID("user_id") }
        _ = try await withRetry(untilClosed: false) {
            try await self.call("DELETE", "/v1/users/\(pathEscape(userID))", timeout: self.timeout)
        }
        lock.locked { try? store.delete(userKey(userID, nil)!) }
    }

    // MARK: - plumbing

    func userKey(_ userID: String?, _ anonID: String?) -> String? {
        if let userID { return prefix + "u:" + userID }
        if let anonID { return prefix + "a:" + anonID }
        return nil
    }

    /// A user's state. The store is a cache: when it fails or holds a
    /// malformed state, recapi's stored history is still there, so the call
    /// goes on without it.
    private func load(_ key: String) -> UserState {
        guard let raw = try? store.get(key) else { return UserState() }
        return UserState(stored: raw) ?? UserState()
    }

    private func save(_ key: String, _ state: UserState, now: Int64) {
        try? store.set(key, state.dump(now: now))
    }
}

/// The caller's exclude plus the rejected items, newest first, up to the API limit.
func withRejected(_ exclude: [String]?, _ rejected: [String]) -> [String]? {
    if rejected.isEmpty { return exclude }
    var out: [String] = []
    var seen = Set<String>()
    for item in (exclude ?? []) + rejected.reversed() where out.count < RecapiClient.maxExclude || seen.contains(item) {
        if seen.insert(item).inserted { out.append(item) }
    }
    return out
}

func pathEscape(_ s: String) -> String { escape(s) }

func invalidID(_ name: String) -> RecapiError {
    .invalid("\(name) must be 1-256 bytes of UTF-8 without control characters")
}

/// Checks the ids given by name; nil is no id.
func checkIDs(_ ids: [String: String?]) throws(RecapiError) {
    for (name, value) in ids.sorted(by: { $0.key < $1.key }) {
        if let value, !isID(value) { throw invalidID(name) }
    }
}

/// A wait that a timer or `fire()` ends. A latch stays fired (close); a
/// pulse is used by the wait it ends, or else by the next one (a full batch).
final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private let latch: Bool
    private var fired = false
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var next = 0

    init(latch: Bool) { self.latch = latch }

    var isFired: Bool { lock.locked { fired } }

    /// Waits up to `seconds`: true when fired.
    func wait(_ seconds: Double) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let id: Int? = lock.locked {
                if fired {
                    if !latch { fired = false }
                    return nil
                }
                next += 1
                waiters[next] = c
                return next
            }
            guard let id else { return c.resume(returning: true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, seconds)) {
                self.lock.locked { self.waiters.removeValue(forKey: id) }?.resume(returning: false)
            }
        }
    }

    /// Ends the waits; false when a latch had fired already.
    @discardableResult
    func fire() -> Bool {
        let (first, woken): (Bool, [CheckedContinuation<Bool, Never>]) = lock.locked {
            defer { waiters = [:] }
            let first = !fired
            if latch || waiters.isEmpty { fired = true }
            return (first, Array(waiters.values))
        }
        for c in woken { c.resume(returning: true) }
        return first
    }
}

/// A lock held across awaits, in order of arrival.
final class AsyncLock: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready: Bool = lock.locked {
                if held {
                    waiters.append(c)
                    return false
                }
                held = true
                return true
            }
            if ready { c.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.locked {
            if waiters.isEmpty {
                held = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

extension NSLock {
    /// Runs body under the lock. Foundation's own `withLock` is macOS 13 /
    /// iOS 16 on Apple platforms, newer than the package's deployment targets.
    func locked<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
