import Foundation

#if os(iOS)
    import UIKit
#endif

/// All SDK state. Every mutable field is touched only on `q`.
final class Core {
    static let maxBatch = 20
    static let maxQueue = 200
    enum Key {
        static let queue = "hermetica.queue", anonymousId = "hermetica.anonymousId", profile = "hermetica.profile"
        static let optOut = "hermetica.trackingOptOut", pushToken = "hermetica.pushToken", pushEnv = "hermetica.pushEnvironment"
    }

    let transport: Transport
    let defaults: UserDefaults
    let q = DispatchQueue(label: "com.hermetica.sdk")
    let sessionId = "s" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    var flushInterval: TimeInterval = 10
    var now: () -> Date = Date.init
    var pushStatus: (@escaping (PushEnablementStatus, PushBackgroundStatus) -> Void) -> Void = Core.systemPushStatus
    var openURL: (URL) -> Void = Core.systemOpen

    var queue: [[String: Any]]
    /// externalId / email / phone, as the app last told us.
    var profile: [String: String]
    var pendingTraits: [String: Any] = [:]
    var optedOut: Bool
    var inAppEnabled = false
    var inAppSeen = Set<String>()
    private var inflight = false
    private var timerArmed = false
    private var waiters: [() -> Void] = []

    init(siteKey: String, baseURL: URL, session: URLSession = .shared, defaults: UserDefaults = .standard, retryBase: Double = 0.5) {
        transport = Transport(baseURL: baseURL, siteKey: siteKey, session: session, retryBase: retryBase)
        self.defaults = defaults
        optedOut = defaults.bool(forKey: Key.optOut)
        profile = defaults.dictionary(forKey: Key.profile) as? [String: String] ?? [:]
        queue = defaults.data(forKey: Key.queue).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        #if os(iOS)
            observeLifecycle()
        #endif
    }

    // MARK: identity (call on q)

    func anonymousIdLocked() -> String? {
        guard !optedOut else { return nil }
        if let id = defaults.string(forKey: Key.anonymousId) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Key.anonymousId)
        return id
    }

    private func saveProfile() { defaults.set(profile, forKey: Key.profile) }

    func identify(externalId: String?, email: String?, phone: String?, traits: [String: Any]) {
        q.async {
            guard !self.optedOut else { return log("identify dropped (tracking opt-out)") }
            for (k, v) in [("externalId", externalId), ("email", email), ("phone", phone)] where v?.isEmpty == false { self.profile[k] = v }
            self.saveProfile()
            self.pendingTraits.merge(traits) { _, new in new }
            self.sendIdentifyLocked()
            if externalId != nil || email != nil || phone != nil { self.registerPush(nil, environment: nil, done: nil) }  // move the device to this profile
        }
    }

    /// Attributes wait until there is an identifier: the server only accepts identify with one.
    private func sendIdentifyLocked() {
        guard !profile.isEmpty, let aid = anonymousIdLocked() else { return }
        let body: [String: Any] = ["anonymousId": aid, "identifiers": profile, "traits": jsonSafe(pendingTraits), "consent": Self.consent]
        pendingTraits = [:]
        transport.post("/ingest/v1/identify", body)
    }

    func reset() {
        q.async {
            self.profile = [:]
            self.pendingTraits = [:]
            self.inAppSeen = []
            self.saveProfile()
            self.defaults.removeObject(forKey: Key.anonymousId)
            self.registerPush(nil, environment: nil, done: nil)  // the device now belongs to the new anonymous visitor
        }
    }

    func setOptOut(_ out: Bool) {
        q.sync {
            optedOut = out
            defaults.set(out, forKey: Key.optOut)
            guard out else { return }
            queue = []
            pendingTraits = [:]
            persistQueue()
            defaults.removeObject(forKey: Key.anonymousId)  // a new visitor id after opting back in
        }
    }

    // MARK: events

    /// Opting out is the only gate; the app asks for consent before it lets tracking on.
    static let consent: [String: Bool] = ["analytics": true, "marketing": true]

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func enqueue(_ name: String, _ properties: [String: Any], value: Int? = nil, currency: String? = nil, page: [String: String]? = nil) {
        q.async {
            guard !self.optedOut, let aid = self.anonymousIdLocked() else { return log("dropped \(name) (tracking opt-out)") }
            var props = jsonSafe(properties) as? [String: Any] ?? [:]
            props["hm_sdk"] = "swift-\(Hermetica.sdkVersion)"
            var ev: [String: Any] = ["name": name, "properties": props, "dedupeKey": UUID().uuidString.lowercased(), "occurredAt": Self.iso.string(from: self.now()), "anonymousId": aid]
            if let value { ev["value"] = value }
            if let currency { ev["currency"] = currency }
            if let page { ev["context"] = ["page": page] }
            self.queue.append(ev)
            if self.queue.count > Self.maxQueue { self.queue.removeFirst(self.queue.count - Self.maxQueue) }  // drop oldest
            self.persistQueue()
            if self.queue.count >= Self.maxBatch { self.flushLocked() } else { self.armTimer() }
        }
    }

    private func persistQueue() {
        defaults.set(try? JSONSerialization.data(withJSONObject: queue), forKey: Key.queue)
    }

    private func armTimer() {
        guard !timerArmed else { return }
        timerArmed = true
        q.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            self?.timerArmed = false; self?.flushLocked()
        }
    }

    func flush(_ done: (() -> Void)? = nil) { q.async { self.flushLocked(done) } }

    /// Sends batches until the queue is empty or a batch fails; failed events stay queued (and persisted) for the next flush.
    private func flushLocked(_ done: (() -> Void)? = nil) {
        if let done { waiters.append(done) }
        guard !inflight else { return }
        guard !optedOut, !queue.isEmpty else { return finishLocked() }
        inflight = true
        let batch = Array(queue.prefix(Self.maxBatch))
        let keys = Set(batch.compactMap { $0["dedupeKey"] as? String })
        transport.post("/ingest/v1/batch", ["events": batch, "consent": Self.consent]) { status in
            self.q.async {
                self.inflight = false
                guard Transport.settled(status) else { log("batch failed (\(status)), kept for later"); return self.finishLocked() }
                // By key, not by position: opt-out or new events may have changed the queue meanwhile.
                self.queue.removeAll { keys.contains($0["dedupeKey"] as? String ?? "") }
                self.persistQueue()
                self.flushLocked()
            }
        }
    }

    private func finishLocked() {
        let w = waiters
        waiters = []
        w.forEach { $0() }
    }

    #if os(iOS)
        private func observeLifecycle() {
            let nc = NotificationCenter.default
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                var task = UIBackgroundTaskIdentifier.invalid
                let end = { if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid } }
                task = UIApplication.shared.beginBackgroundTask(withName: "hermetica.flush", expirationHandler: end)
                self?.flush { DispatchQueue.main.async(execute: end) }
            }
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.flush() }
        }
    #endif

    static func systemOpen(_ url: URL) {
        #if os(iOS)
            DispatchQueue.main.async { UIApplication.shared.open(url) }
        #endif
    }
}

/// Values JSON cannot carry (dates, URLs, custom types) become strings instead of failing the whole batch.
func jsonSafe(_ v: Any) -> Any {
    switch v {
    case let d as [String: Any]: return d.mapValues(jsonSafe)
    case let a as [Any]: return a.map(jsonSafe)
    case is String, is NSNumber, is NSNull: return v
    case let d as Date: return Core.iso.string(from: d)
    case let u as URL: return u.absoluteString
    default: return String(describing: v)
    }
}
