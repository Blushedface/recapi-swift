import Foundation

/// Keeps per-user state: an in-process cache, a Redis, an app's files
/// (`FileStore`)... Values are strings; `get` returns nil for a missing key.
/// Pass a shared store when several processes serve the same users. Calls
/// are made under the client's lock: keep them quick.
public protocol RecapiStore: Sendable {
    func get(_ key: String) throws -> String?
    func set(_ key: String, _ value: String) throws
    func delete(_ key: String) throws
}

/// An in-process store keeping the most recently used users.
public final class MemoryStore: RecapiStore, @unchecked Sendable {
    private let max: Int
    private let lock = NSLock()
    private var values: [String: String] = [:]
    // Most recently used last; a linear scan is fine at the default size,
    // which a server with more users replaces with a shared store.
    private var order: [String] = []

    /// A store keeping at most `maxUsers` users (10,000 when below 1).
    public init(maxUsers: Int = 10_000) { max = maxUsers < 1 ? 10_000 : maxUsers }

    public func get(_ key: String) -> String? {
        lock.locked {
            guard let value = values[key] else { return nil }
            touch(key)
            return value
        }
    }

    public func set(_ key: String, _ value: String) {
        lock.locked {
            values[key] = value
            touch(key)
            while order.count > max { values[order.removeFirst()] = nil }
        }
    }

    public func delete(_ key: String) {
        lock.locked {
            values[key] = nil
            order.removeAll { $0 == key }
        }
    }

    private func touch(_ key: String) {
        if let i = order.lastIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}

/// A store in a directory, for apps: a visitor's history and the
/// recommendations they were shown survive the app being closed, as the web
/// library's do in the browser. By default in Application Support/recapi.
///
/// The first call reads the directory (an app has one visitor: a few kB);
/// changes go to disk on a background queue, so `track` stays quick on the
/// main thread. One file per user, named by a hash of the key and replaced
/// whole (`Data.write(.atomic)`), so a killed app leaves the previous state or
/// the new one. Keeps the `maxUsers` most recently written users. Plain files,
/// no UserDefaults and no file dates: nothing for the app's privacy manifest.
/// One process per directory.
public final class FileStore: RecapiStore, @unchecked Sendable {
    private let directory: URL
    private let max: Int
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.recapi.store")
    // By file name. Each value's sequence number is stored with it: the
    // eviction order survives a restart without reading file dates.
    private var values: [String: (value: String, seq: Int64)] = [:]
    // Files to rewrite (or delete, once gone from values) on the queue.
    private var dirty: Set<String> = []
    private var seq: Int64 = 0
    private var loaded = false
    private var scheduled = false
    // Test hook: runs on the queue before each write.
    var beforeWrite: @Sendable () -> Void = {}

    /// A store in `directory` (created when missing; default Application
    /// Support/recapi) keeping at most `maxUsers` users (100 when below 1).
    public init(directory: URL? = nil, maxUsers: Int = 100) {
        self.directory = directory ?? FileStore.defaultDirectory
        max = maxUsers < 1 ? 100 : maxUsers
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (base ?? FileManager.default.temporaryDirectory).appendingPathComponent("recapi", isDirectory: true)
    }

    public func get(_ key: String) -> String? {
        lock.locked {
            load()
            return values[sha256Hex(key)]?.value
        }
    }

    public func set(_ key: String, _ value: String) {
        lock.locked {
            load()
            let name = sha256Hex(key)
            seq += 1
            values[name] = (value, seq)
            dirty.insert(name)
            evict()
            schedule()
        }
    }

    public func delete(_ key: String) {
        lock.locked {
            load()
            let name = sha256Hex(key)
            if values.removeValue(forKey: name) != nil {
                dirty.insert(name)
                schedule()
            }
        }
    }

    /// Waits until every change made so far is on disk (a failed write is
    /// tried again with the next change). The client's `flush` and `close`
    /// call it.
    public func flush() { queue.sync {} }

    private func evict() {
        while values.count > max, let oldest = values.min(by: { $0.value.seq < $1.value.seq })?.key {
            values[oldest] = nil
            dirty.insert(oldest)
        }
    }

    private func schedule() {
        if scheduled { return }
        scheduled = true
        queue.async { self.write() }
    }

    private func load() {
        if loaded { return }
        loaded = true
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.utf8.count == 64 && name.utf8.allSatisfy(isLowerHex) {
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path),
                let nl = data.firstIndex(of: 0x0A), let n = Int64(String(decoding: data[..<nl], as: UTF8.self)),
                let value = String(data: data[(nl + 1)...], encoding: .utf8)
            else { continue }
            values[name] = (value, n)
            seq = Swift.max(seq, n)
        }
        // A smaller maxUsers than the last run's.
        evict()
        if !dirty.isEmpty { schedule() }
    }

    private func write() {
        beforeWrite()
        let batch = lock.locked {
            scheduled = false
            defer { dirty.removeAll() }
            return dirty.map { ($0, values[$0]) }
        }
        var failed: [String] = []
        for (name, entry) in batch {
            let file = directory.appendingPathComponent(name)
            do {
                if let entry {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Data("\(entry.seq)\n\(entry.value)".utf8).write(to: file, options: .atomic)
                } else if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            } catch {
                failed.append(name)
            }
        }
        if !failed.isEmpty { lock.locked { dirty.formUnion(failed) } }
    }
}

private func isLowerHex(_ c: UInt8) -> Bool { (0x30...0x39).contains(c) || (0x61...0x66).contains(c) }

/// An item a recommendation showed the user: its id, when, and when the user
/// first clicked it (nil: not yet).
struct ShownItem {
    var item: String
    var recID: String
    var shown: Int64
    var clicked: Int64?

    func attributable(_ t: Int64) -> Bool {
        if let clicked { return t - clicked <= RecapiClient.clickWindowMs }
        return t - shown <= RecapiClient.displayWindowMs
    }
}

/// What the store keeps per user: the history and the shown items, oldest
/// first. `restored` is set once the history holds recapi's stored one.
/// `anonID` is the visitor identify merged in before that: recapi's snapshot
/// also holds that visitor's browsing, so the restore asks it to leave it out.
/// Its JSON is the other server libraries', so they can share a store.
struct UserState {
    var history = History()
    var shown: [ShownItem] = []
    var restored = false
    var anonID: String?

    func find(_ item: String) -> Int? { shown.firstIndex { $0.item == item } }

    /// Records an item as shown last, after any earlier display of it.
    mutating func show(_ s: ShownItem) {
        if let i = find(s.item) { shown.remove(at: i) }
        shown.append(s)
    }

    func dump(now: Int64) -> String {
        let kept = shown.filter { $0.attributable(now) }.suffix(RecapiClient.maxShownItems).map { s -> JSONValue in
            var e: [JSONValue] = [.string(s.item), .string(s.recID), .number(Double(s.shown))]
            if let clicked = s.clicked { e.append(.number(Double(clicked))) }
            return .array(e)
        }
        var state: [String: JSONValue] = ["history": history.encoded(), "shown": .array(Array(kept))]
        if restored { state["restored"] = .bool(true) }
        if let anonID, !anonID.isEmpty { state["anon_id"] = .string(anonID) }
        return String(decoding: (try? JSONValue.object(state).serialized()) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// A stored state; nil when it is malformed.
    init?(stored raw: String) {
        guard let state = try? JSONValue.parse(Data(raw.utf8)), let shown = state["shown"]?.arrayValue,
            let history = state["history"].flatMap(History.init(stored:))
        else { return nil }
        self.history = history
        if case .bool(true)? = state["restored"] { restored = true }
        if let anonID = state["anon_id"]?.stringValue, isID(anonID) { self.anonID = anonID }
        for e in shown {
            guard let list = e.arrayValue, (3...4).contains(list.count), let item = list[0].stringValue, isID(item),
                let recID = list[1].stringValue, case .number(let at) = list[2]
            else { continue }
            var s = ShownItem(item: item, recID: recID, shown: Int64(at))
            if list.count == 4, case .number(let clicked) = list[3] { s.clicked = Int64(clicked) }
            show(s)
        }
    }

    init() {}
}
