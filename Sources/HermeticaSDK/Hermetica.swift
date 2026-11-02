import Foundation

/// The Hermetica SDK. Call `initialize` once at launch; every other call before that is ignored.
public enum Hermetica {
    static var core: Core?

    /// Prints what the SDK queues, drops and sends (never the site key).
    public static var debug = false

    /// Renders in-app messages yourself or handles their buttons. Held weakly.
    public static weak var inAppDelegate: HermeticaInAppDelegate?

    /// - Parameters:
    ///   - siteKey: the site's public key.
    ///   - baseURL: your Hermetica API address.
    public static func initialize(siteKey: String, baseURL: URL) {
        guard core == nil else { return log("initialize called twice; keeping the first configuration") }
        let c = Core(siteKey: siteKey, baseURL: baseURL)
        core = c
        c.flush()  // what an earlier launch could not send
    }

    /// Who this is. Any identifier you pass is kept until `reset`; `properties` become profile attributes.
    public static func identify(externalId: String? = nil, email: String? = nil, phoneNumber: String? = nil, properties: [String: Any] = [:]) {
        core?.identify(externalId: externalId, email: email, phone: phoneNumber, traits: properties)
    }

    /// Profile attributes (first_name, plan, ...). Sent with the next identifier if none is known yet.
    public static func setProfileAttributes(_ attributes: [String: Any]) {
        core?.identify(externalId: nil, email: nil, phone: nil, traits: attributes)
    }

    /// Queues an event. `value` is in minor units (cents) with an ISO 4217 `currency`.
    public static func track(_ event: String, properties: [String: Any] = [:], value: Int? = nil, currency: String? = nil) {
        guard let core else { return }
        core.enqueue(event, properties, value: value, currency: currency)
        core.runTrigger(.event(event, properties: properties))
    }

    /// A screen view: sent as a page view named after the screen, and offered to in-app messages with a screen trigger.
    public static func screen(_ name: String, properties: [String: Any] = [:]) {
        guard let core else { return }
        var props = properties
        props["screen"] = name
        let app = Bundle.main.bundleIdentifier ?? "app"
        let path = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        core.enqueue("page_view", props, page: ["url": "app://\(app)/\(path)", "title": name])
        core.runTrigger(.screenView(name))
    }

    /// Logout: forgets the identifiers and starts a new anonymous visitor. The push token moves to that visitor.
    public static func reset() { core?.reset() }

    /// While opted out nothing is stored or sent (events, identify, push registration, in-app, geofences) and queued events are
    /// discarded. The choice is remembered across launches.
    public static func setTrackingOptOut(_ optedOut: Bool) {
        guard let core else { return }
        core.setOptOut(optedOut)
        #if os(iOS)
            if optedOut { stopGeofenceMonitoring() }
        #endif
    }

    public static var isTrackingOptedOut: Bool { core.map { c in c.q.sync { c.optedOut } } ?? false }

    /// The visitor id events are sent with; nil while opted out.
    public static var anonymousId: String? { core.map { c in c.q.sync { c.anonymousIdLocked() } } ?? nil }

    /// Sends queued events now (the SDK also flushes every few seconds, at 20 events and when the app goes to the background).
    public static func flush(completion: (() -> Void)? = nil) {
        guard let core else { completion?(); return }
        core.flush(completion)
    }
}
