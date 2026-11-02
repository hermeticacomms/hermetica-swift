import Foundation

#if os(iOS)
    import UIKit
    import UserNotifications
#endif

public enum PushEnablementStatus: String {
    case authorized = "AUTHORIZED", denied = "DENIED", notDetermined = "NOT_DETERMINED", provisional = "PROVISIONAL", unauthorized = "UNAUTHORIZED"
}
public enum PushBackgroundStatus: String { case available = "AVAILABLE", denied = "DENIED", restricted = "RESTRICTED" }
/// The APNs gateway the token belongs to. Left out, it is read from the app's provisioning profile.
public enum PushEnvironment: String { case sandbox, production }

extension Hermetica {
    /// Pass the token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`. Completion: whether the server took it.
    public static func setPushToken(_ deviceToken: Data, environment: PushEnvironment? = nil, completion: ((Bool) -> Void)? = nil) {
        setPushToken(deviceToken.map { String(format: "%02x", $0) }.joined(), environment: environment, completion: completion)
    }

    public static func setPushToken(_ token: String, environment: PushEnvironment? = nil, completion: ((Bool) -> Void)? = nil) {
        guard let core else { completion?(false); return }
        core.registerPush(token, environment: environment ?? apnsEnvironment(), done: completion)
    }

    /// Stops pushes to this device (for example on logout). Sent even when tracking is opted out: it only carries the token.
    public static func unregisterPushToken(completion: ((Bool) -> Void)? = nil) {
        guard let core else { completion?(false); return }
        core.unregisterPush(done: completion)
    }

    /// The last token given to `setPushToken`.
    public static var pushToken: String? { core?.defaults.string(forKey: Core.Key.pushToken) }

    /// The notification permission as the server records it.
    public static func pushPermissionStatus(_ completion: @escaping (PushEnablementStatus) -> Void) {
        let read = core?.pushStatus ?? Core.systemPushStatus
        read { status, _ in completion(status) }
    }

    /// Tracks `$opened_push` for a Hermetica notification and returns its deep link (or nil). Call it when the user taps a notification.
    @discardableResult
    public static func handlePushOpened(userInfo: [AnyHashable: Any]) -> String? {
        var d = userInfo
        if let nested = userInfo["data"] as? [AnyHashable: Any] { d.merge(nested) { _, inner in inner } }
        let str = { (k: String) -> String? in (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if let id = str("hermetica_message_id") { core?.enqueue("$opened_push", ["hermetica_message_id": id]) }
        return str("deep_link") ?? str("url") ?? str("hermetica_url")
    }

    #if os(iOS)
        /// Call from `userNotificationCenter(_:didReceive:withCompletionHandler:)`. Tracks the open and, unless told not to, opens the deep link.
        @discardableResult
        public static func handleNotificationResponse(_ response: UNNotificationResponse, openDeepLink: Bool = true) -> URL? {
            guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return nil }
            let link = handlePushOpened(userInfo: response.notification.request.content.userInfo).flatMap(URL.init(string:))
            if openDeepLink, let link {
                let open = core?.openURL ?? Core.systemOpen
                open(link)
            }
            return link
        }

        /// For `userNotificationCenter(_:willPresent:withCompletionHandler:)`: show Hermetica pushes while the app is open.
        public static func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions {
            if #available(iOS 14.0, *) { return [.banner, .list, .sound, .badge] }
            return [.alert, .sound, .badge]
        }
    #endif

    /// Development builds carry a provisioning profile naming the APNs environment; App Store builds carry none (production).
    static func apnsEnvironment() -> PushEnvironment {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url)
        else { return .production }
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "<key>aps-environment</key>") else { return .production }
        return text[r.upperBound...].drop(while: { $0.isWhitespace }).hasPrefix("<string>development</string>") ? .sandbox : .production
    }
}

extension Core {
    /// The push-token JSON:API body the server expects (Klaviyo's shape).
    func pushBody(token: String, environment: String, enablement: PushEnablementStatus, background: PushBackgroundStatus) -> [String: Any] {
        let aid = anonymousIdLocked() ?? ""
        let b = Bundle.main.infoDictionary ?? [:]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let meta: [String: Any] = [
            "device_id": aid, "sdk_version": "swift-\(Hermetica.sdkVersion)", "device_model": Self.deviceModel(), "os_name": "ios",
            "os_version": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", "app_name": b["CFBundleName"] as? String ?? "",
            "app_version": b["CFBundleShortVersionString"] as? String ?? "", "app_build": b["CFBundleVersion"] as? String ?? "",
            "app_id": Bundle.main.bundleIdentifier ?? "", "environment": environment,
        ]
        var who: [String: String] = ["anonymous_id": aid]
        who["email"] = profile["email"]
        who["phone_number"] = profile["phone"]
        who["external_id"] = profile["externalId"]
        let profileRef: [String: Any] = ["data": ["type": "profile", "attributes": who] as [String: Any]]
        let attributes: [String: Any] = [
            "token": token, "platform": "ios", "vendor": "apns", "enablement_status": enablement.rawValue, "background": background.rawValue,
            "device_metadata": meta, "profile": profileRef,
        ]
        return ["data": ["type": "push-token", "attributes": attributes] as [String: Any]]
    }

    /// Registers `token` (or the stored one when nil) with the current profile.
    func registerPush(_ token: String?, environment: PushEnvironment?, done: ((Bool) -> Void)?) {
        q.async {
            if let token {
                self.defaults.set(token, forKey: Key.pushToken)
                self.defaults.set(environment?.rawValue, forKey: Key.pushEnv)
            }
            guard !self.optedOut, let tok = self.defaults.string(forKey: Key.pushToken) else { done?(false); return }
            let env = self.defaults.string(forKey: Key.pushEnv) ?? PushEnvironment.production.rawValue
            self.pushStatus { enablement, background in
                self.q.async {
                    let body = self.pushBody(token: tok, environment: env, enablement: enablement, background: background)
                    self.transport.post("/client/push-tokens", body) { done?((200..<300).contains($0)) }
                }
            }
        }
    }

    func unregisterPush(done: ((Bool) -> Void)?) {
        q.async {
            guard let tok = self.defaults.string(forKey: Key.pushToken) else { done?(false); return }
            self.defaults.removeObject(forKey: Key.pushToken)
            let body: [String: Any] = ["data": ["type": "push-token-unregister", "attributes": ["token": tok, "platform": "ios", "vendor": "apns"]] as [String: Any]]
            self.transport.post("/client/push-token-unregister", body) { done?((200..<300).contains($0)) }
        }
    }

    static func deviceModel() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func systemPushStatus(_ done: @escaping (PushEnablementStatus, PushBackgroundStatus) -> Void) {
        #if os(iOS)
            UNUserNotificationCenter.current().getNotificationSettings { s in
                let e: PushEnablementStatus
                switch s.authorizationStatus {
                case .denied: e = .denied
                case .notDetermined: e = .notDetermined
                case .provisional: e = .provisional
                default: e = .authorized  // authorized, ephemeral (App Clips)
                }
                DispatchQueue.main.async {
                    switch UIApplication.shared.backgroundRefreshStatus {
                    case .denied: done(e, .denied)
                    case .restricted: done(e, .restricted)
                    default: done(e, .available)
                    }
                }
            }
        #else
            done(.authorized, .available)
        #endif
    }
}
