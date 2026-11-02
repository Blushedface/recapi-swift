import Foundation

/// The history parameters of docs/history-spec.md.
public enum HistorySpec {
    public static let halfLifeSeconds = 604_800.0
    public static let topK = 50
    public static let recentSize = 20
    public static let rejectedSize = 200
    public static let maxIDBytes = 256
}

/// Whether the API accepts `s` as an id: 1-256 bytes of UTF-8 without
/// control characters (general category Cc, as the API checks).
public func isID(_ s: String) -> Bool {
    let bytes = s.utf8.count
    return bytes > 0 && bytes <= HistorySpec.maxIDBytes
        && !s.unicodeScalars.contains { $0.properties.generalCategory == .control }
}

/// Byte order, as Go and Python compare ids; Swift's `<` compares by
/// canonical equivalence, which can order two ids differently.
func idBefore(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

private let rate = log(2.0) / HistorySpec.halfLifeSeconds

func decay(_ dtMs: Double) -> Double { exp(-rate * (dtMs / 1000)) }

/// One user's decayed history, exactly as docs/history-spec.md (times in unix
/// ms): a port of sdk/go's, whose spec/history_vectors.json it passes too.
/// `top` maps item -> (score at t, t), `recent` is oldest first, `rejected`
/// maps item -> its newest rejection, and `lastT` is the newest event applied
/// to the recent list (nil when unknown).
struct History: Equatable {
    var top: [String: (s: Double, t: Double)] = [:]
    var recent: [(item: String, t: Double)] = []
    var rejected: [String: Double] = [:]
    var lastT: Double?

    static func == (a: History, b: History) -> Bool {
        a.top.mapValues { [$0.s, $0.t] } == b.top.mapValues { [$0.s, $0.t] }
            && a.recent.map(\.item) == b.recent.map(\.item) && a.recent.map(\.t) == b.recent.map(\.t)
            && a.rejected == b.rejected && a.lastT == b.lastT
    }

    /// Nothing to send, so the server uses its stored history. Rejections
    /// alone don't count: the server still has the user's positive events.
    var isEmpty: Bool { top.isEmpty && recent.isEmpty }

    mutating func apply(_ item: String, level: Int, t: Double) {
        if level == 0 { return }
        if level < 0 {
            reject(item, t: t)
            return
        }
        if let mark = rejected[item] {
            if t < mark { return }
            rejected[item] = nil
        }
        let score = Double(level)
        if let cur = top[item] {
            top[item] = t >= cur.t
                ? (cur.s * decay(t - cur.t) + score, t)
                : (cur.s + score * decay(cur.t - t), cur.t)
        } else {
            top[item] = (score, t)
        }
        if lastT == nil || t >= lastT! {
            recent.removeAll { $0.item == item }
            recent.append((item, t))
            if recent.count > HistorySpec.recentSize {
                recent.removeFirst(recent.count - HistorySpec.recentSize)
            }
            lastT = t
        }
        prune(now: t)
    }

    mutating func reject(_ item: String, t: Double) {
        // Dropped, not lowered: a lowered score would decay back towards 0.
        if let cur = top[item], cur.t > t { return }
        top[item] = nil
        recent.removeAll { $0.item == item }
        if let mark = rejected[item], mark >= t {} else { rejected[item] = t }
        pruneRejected()
    }

    /// The entries with their weight at now, by weight desc, ties by item id asc.
    func ranked(now: Double) -> [(item: String, weight: Double, t: Double)] {
        top.map { (item: $0.key, weight: $0.value.s * decay(now - $0.value.t), t: $0.value.t) }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : idBefore($0.item, $1.item) }
    }

    /// The rejected items, oldest mark first, ties by id.
    func rejectedOrder() -> [String] {
        rejected.keys.sorted {
            let a = rejected[$0]!, b = rejected[$1]!
            return a != b ? a < b : idBefore($0, $1)
        }
    }

    mutating func prune(now: Double) {
        if top.count <= HistorySpec.topK { return }
        var kept: [String: (s: Double, t: Double)] = [:]
        for e in ranked(now: now).prefix(HistorySpec.topK) { kept[e.item] = top[e.item] }
        top = kept
    }

    mutating func pruneRejected() {
        if rejected.count <= HistorySpec.rejectedSize { return }
        for item in rejectedOrder().dropLast(HistorySpec.rejectedSize) { rejected[item] = nil }
    }

    /// The request's history and recent, and the rejected items. Weights are
    /// decayed to now and rounded half up to 4 decimals like JS Math.round;
    /// ages are whole seconds, never negative.
    func wire(now: Double) -> (history: [JSONValue], recent: [String], rejected: [String]) {
        let history = ranked(now: now).prefix(HistorySpec.topK).map { e -> JSONValue in
            let age = max(0, ((now - e.t) / 1000).rounded(.down))
            return .array([.string(e.item), .number((e.weight * 1e4 + 0.5).rounded(.down) / 1e4), .number(age)])
        }
        return (Array(history), recent.map(\.item), rejectedOrder())
    }

    /// A history from the server's snapshot (GET /v1/users/{id}/history, or
    /// a recommendation reply's history), skipping invalid entries. Each top
    /// entry is a score at as_of, each rejected item a mark at as_of. lastT
    /// stays unknown: as_of is the server clock, and a local clock behind it
    /// would see every new event as out of order.
    init(snapshot: JSONValue) {
        guard case .number(let asOf)? = snapshot["as_of"] else { return }
        for e in snapshot["top"]?.arrayValue ?? [] {
            guard let pair = e.arrayValue, pair.count >= 2, let item = pair[0].stringValue, isID(item),
                case .number(let score) = pair[1], score >= 0
            else { continue }
            top[item] = (score, asOf)
        }
        var seen = Set<String>()
        for e in snapshot["recent"]?.arrayValue ?? [] {
            if let item = e.stringValue, isID(item), seen.insert(item).inserted { recent.append((item, asOf)) }
        }
        if recent.count > HistorySpec.recentSize { recent.removeFirst(recent.count - HistorySpec.recentSize) }
        for e in snapshot["rejected"]?.arrayValue ?? [] {
            if let item = e.stringValue, isID(item) { rejected[item] = asOf }
        }
        prune(now: asOf)
        pruneRejected()
    }

    init() {}

    /// The union of two histories built from disjoint events. Top scores add
    /// up, expressed at the later of the two times; the recent lists are
    /// interleaved by time (self first on ties); rejection marks are united,
    /// and a mark older than the item's merged entry is dropped, otherwise the
    /// item leaves the top and the recent list.
    func merged(with other: History, now: Double) -> History {
        var out = History()
        out.top = top
        for (item, e) in other.top {
            guard let mine = out.top[item] else {
                out.top[item] = e
                continue
            }
            let later = max(e.t, mine.t)
            out.top[item] = (e.s * decay(later - e.t) + mine.s * decay(later - mine.t), later)
        }
        out.rejected = rejected
        for (item, t) in other.rejected where out.rejected[item].map({ t > $0 }) ?? true {
            out.rejected[item] = t
        }
        for (item, t) in out.rejected {
            if let e = out.top[item], e.t > t {
                out.rejected[item] = nil
            } else {
                out.top[item] = nil
            }
        }
        var byItem: [String: (t: Double, order: Int)] = [:]
        for (order, e) in (recent + other.recent).enumerated() where byItem[e.item].map({ e.t > $0.t }) ?? true {
            byItem[e.item] = (e.t, order)
        }
        // Rejected items go before the trim, so they don't cost the list its places.
        let kept = byItem.filter { out.rejected[$0.key] == nil }
            .sorted { $0.value.t != $1.value.t ? $0.value.t < $1.value.t : $0.value.order < $1.value.order }
            .map { (item: $0.key, t: $0.value.t) }
        out.recent = Array(kept.suffix(HistorySpec.recentSize))
        out.lastT = [lastT, other.lastT].compactMap { $0 }.max()
        out.prune(now: now)
        out.pruneRejected()
        return out
    }

    /// Merges a server snapshot, keeping the items rejected here rejected. The
    /// snapshot dates its scores as_of, which only bounds when its events
    /// happened; a local rejection is usually one the server hasn't stored
    /// yet, so it wins over the snapshot's score.
    func merged(snapshot: History, now: Double) -> History {
        var trimmed = snapshot
        trimmed.top = snapshot.top.filter { rejected[$0.key] == nil }
        return merged(with: trimmed, now: now)
    }

    /// The stored form (raw scores), shaped like the other libraries', so a
    /// store can be shared with them.
    func encoded() -> JSONValue {
        .object([
            "top": .array(top.map { .array([.string($0.key), .number($0.value.s), .number($0.value.t)]) }),
            "recent": .array(recent.map { .array([.string($0.item), .number($0.t)]) }),
            "rejected": .array(rejected.map { .array([.string($0.key), .number($0.value)]) }),
            "lastT": lastT.map { .number($0) } ?? .null,
        ])
    }

    /// The inverse of encoded(); nil for any malformed field. A state stored
    /// before rejections existed has no rejected.
    init?(stored: JSONValue) {
        guard let top = stored["top"]?.arrayValue, let recent = stored["recent"]?.arrayValue,
            let lastT = stored["lastT"]
        else { return nil }
        switch lastT {
        case .null: self.lastT = nil
        case .number(let t): self.lastT = t
        default: return nil
        }
        for e in top {
            guard let (item, nums) = History.entry(e, 2), nums[0] >= 0 else { return nil }
            self.top[item] = (nums[0], nums[1])
        }
        for e in recent {
            guard let (item, nums) = History.entry(e, 1) else { return nil }
            self.recent.append((item, nums[0]))
        }
        for e in stored["rejected"]?.arrayValue ?? [] {
            guard let (item, nums) = History.entry(e, 1) else { return nil }
            rejected[item] = nums[0]
        }
        pruneRejected()
    }

    /// Reads [id, n...] with exactly n numbers.
    private static func entry(_ raw: JSONValue, _ n: Int) -> (String, [Double])? {
        guard let list = raw.arrayValue, list.count == n + 1, let item = list[0].stringValue, isID(item) else {
            return nil
        }
        var nums: [Double] = []
        for v in list.dropFirst() {
            guard case .number(let x) = v else { return nil }
            nums.append(x)
        }
        return (item, nums)
    }
}
