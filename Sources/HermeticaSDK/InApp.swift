import Foundation

// Unknown server values decode to a fallback instead of failing the whole message list.
public enum InAppLayout: String, Decodable {
    case modal, bannerTop = "banner_top", bannerBottom = "banner_bottom", fullscreen, bottomSheet = "bottom_sheet"
    public init(from decoder: Decoder) throws { self = try InAppLayout(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .modal }
}
public enum InAppBlockType: String, Decodable {
    case heading, text, image, buttons, unknown
    public init(from decoder: Decoder) throws { self = try InAppBlockType(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}
public enum InAppAction: String, Decodable {
    case dismiss, deepLink = "deep_link", url, event
    public init(from decoder: Decoder) throws { self = try InAppAction(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .dismiss }
}

public struct InAppButton: Decodable {
    public let label: String
    public let action: InAppAction
    public let value: String?
    /// "primary" (default) or "secondary".
    public let style: String?
}
public struct InAppBlock: Decodable {
    public let type: InAppBlockType
    public let text: String?
    public let url: String?
    public let alt: String?
    public let buttons: [InAppButton]?
}
public struct InAppContent: Decodable {
    public let blocks: [InAppBlock]
    /// Web only; the native presenter renders `blocks`.
    public let html: String?
}
public struct InAppStyle: Decodable {
    /// Hex colours such as "#ffffff".
    public let background: String
    public let textColor: String
    public let accentColor: String
    public let radius: Double
    public let dismissible: Bool
}
public struct InAppMessage: Decodable {
    public let id: String
    public let variant: String
    public let layout: InAppLayout
    public let priority: Int
    public let queued: Bool
    public let content: InAppContent
    public let style: InAppStyle
}
private struct InAppList: Decodable { let items: [InAppMessage] }

public enum InAppTrigger {
    case appOpen
    case screenView(String)
    case event(String, properties: [String: Any] = [:])
}
public enum InAppEventType: String { case impression, click, dismiss }

/// Set `Hermetica.inAppDelegate` to render messages yourself or to handle button actions.
public protocol HermeticaInAppDelegate: AnyObject {
    /// Return true when you show the message yourself; then report it with `Hermetica.reportInAppEvent` and `performInAppAction`.
    func hermetica(present message: InAppMessage) -> Bool
    /// Return true when you handled a `deep_link`, `url` or `event` button; false runs the default (open the link, track the event).
    func hermetica(handle button: InAppButton, in message: InAppMessage) -> Bool
}
public extension HermeticaInAppDelegate {
    func hermetica(present message: InAppMessage) -> Bool { false }
    func hermetica(handle button: InAppButton, in message: InAppMessage) -> Bool { false }
}

extension Hermetica {
    /// Shows in-app messages from now on: on app open (immediately), on `screen` and on `track`.
    public static func enableInAppMessages() {
        guard let core else { return }
        core.q.async { core.inAppEnabled = true }
        core.runTrigger(.appOpen)
    }

    /// The messages that fit this moment, best first (eligibility and frequency caps are decided by the server). Empty on any failure.
    public static func fetchInAppMessages(trigger: InAppTrigger, completion: @escaping ([InAppMessage]) -> Void) {
        guard let core else { return completion([]) }
        core.fetchInApp(trigger, done: completion)
    }

    public static func reportInAppEvent(_ message: InAppMessage, type: InAppEventType, button: String? = nil) {
        core?.reportInApp(message, type, button: button)
    }

    /// For custom renderers: reports the click and runs the button's action (as the built-in presenter does).
    public static func performInAppAction(_ button: InAppButton, message: InAppMessage) {
        guard let core else { return }
        core.reportInApp(message, .click, button: button.label)
        DispatchQueue.main.async { core.handleInAppAction(button, message) }
    }
}

extension Core {
    func fetchInApp(_ t: InAppTrigger, done: @escaping ([InAppMessage]) -> Void) {
        q.async {
            guard let aid = self.anonymousIdLocked() else { return done([]) }
            var trigger = "app_open", name: String?, props: String?
            switch t {
            case .appOpen: break
            case .screenView(let n): trigger = "screen_view"; name = n
            case .event(let n, let p):
                trigger = "event"; name = n
                let json = p.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: jsonSafe(p))).map { String(decoding: $0, as: UTF8.self) }
                props = (json?.count ?? 0) <= 4096 ? json : nil  // the server caps it; better no properties than no messages
            }
            let query: [(String, String?)] = [
                ("platform", "ios"), ("trigger", trigger), ("session_id", self.sessionId), ("name", name), ("properties", props),
                ("external_id", self.profile["externalId"]), ("email", self.profile["email"]), ("phone_number", self.profile["phone"]), ("anonymous_id", aid),
            ]
            self.transport.get("/client/in-app-messages", query) { data in
                done(data.flatMap { try? JSONDecoder().decode(InAppList.self, from: $0) }?.items ?? [])
            }
        }
    }

    func reportInApp(_ m: InAppMessage, _ type: InAppEventType, button: String?, done: ((Bool) -> Void)? = nil) {
        q.async {
            guard let aid = self.anonymousIdLocked() else { done?(false); return }
            var ev: [String: Any] = ["messageId": m.id, "variant": m.variant, "type": type.rawValue, "platform": "ios", "sessionId": self.sessionId]
            if let button { ev["button"] = String(button.prefix(60)) }
            var who: [String: String] = ["anonymousId": aid]
            who["externalId"] = self.profile["externalId"]
            who["email"] = self.profile["email"]
            who["phoneNumber"] = self.profile["phone"]
            self.transport.post("/client/in-app-events", ["events": [ev], "profile": who]) { done?((200..<300).contains($0)) }
        }
    }

    /// Fetches for `t` and presents the best message not yet shown this session.
    func runTrigger(_ t: InAppTrigger) {
        q.async {
            guard self.inAppEnabled, !self.optedOut else { return }
            self.fetchInApp(t) { items in
                self.q.async {
                    guard let best = items.first, !self.inAppSeen.contains(best.id) else { return }
                    self.inAppSeen.insert(best.id)
                    DispatchQueue.main.async { self.present(best) }
                }
            }
        }
    }

    /// Main thread.
    func present(_ m: InAppMessage) {
        if Hermetica.inAppDelegate?.hermetica(present: m) == true { return }
        #if os(iOS)
            InAppPresenter.shared.show(m)
        #endif
    }

    /// Main thread. The click itself is reported by the caller.
    func handleInAppAction(_ b: InAppButton, _ m: InAppMessage) {
        guard b.action != .dismiss, let v = b.value, !v.isEmpty else { return }
        if Hermetica.inAppDelegate?.hermetica(handle: b, in: m) == true { return }
        switch b.action {
        case .event: enqueue(v, ["hermetica_message_id": m.id])
        case .url: if let u = URL(string: v), ["http", "https"].contains(u.scheme?.lowercased() ?? "") { openURL(u) }
        case .deepLink: if let u = URL(string: v) { openURL(u) }
        case .dismiss: break
        }
    }
}
