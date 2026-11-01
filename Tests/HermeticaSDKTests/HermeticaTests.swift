import CoreLocation
import XCTest
@testable import HermeticaSDK

final class HermeticaTests: XCTestCase {
    private var defaults: UserDefaults!
    private var core: Core!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        defaults = UserDefaults(suiteName: "hermetica-tests-\(UUID().uuidString)")!
        core = makeCore()
        Hermetica.core = core
    }

    override func tearDown() {
        core = nil // its pending flush timer then does nothing
        Hermetica.core = nil
        Hermetica.inAppDelegate = nil
        super.tearDown()
    }

    private func makeCore() -> Core {
        Core(siteKey: "pk_test", baseURL: URL(string: "https://api.test/")!, session: MockURLProtocol.session(), defaults: defaults, retryBase: 0.01)
    }

    private func flush() {
        let e = expectation(description: "flush")
        Hermetica.flush { e.fulfill() }
        wait(for: [e], timeout: 10)
    }

    private func drainMain() {
        let e = expectation(description: "main")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 5)
    }

    private func requests(_ path: String) -> [MockURLProtocol.Seen] { MockURLProtocol.seen.filter { $0.path == path } }

    private func waitFor(_ path: String, count: Int = 1) -> [MockURLProtocol.Seen] {
        let deadline = Date().addingTimeInterval(5)
        while requests(path).count < count, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return requests(path)
    }

    private func events(_ r: MockURLProtocol.Seen) -> [[String: Any]] { r.body?["events"] as? [[String: Any]] ?? [] }
    private func json(_ s: String) -> (Int, Data) { (200, Data(s.utf8)) }

    // MARK: events

    func testTrackBatchesEventsIntoOneSignedRequest() throws {
        Hermetica.track("viewed", properties: ["sku": "A1", "at": Date(timeIntervalSince1970: 0)], value: 1299, currency: "USD")
        Hermetica.track("added")
        Hermetica.screen("Home")
        flush()

        let batch = requests("/ingest/v1/batch")
        XCTAssertEqual(batch.count, 1)
        let r = try XCTUnwrap(batch.first)
        XCTAssertEqual(r.request.httpMethod, "POST")
        XCTAssertEqual(r.request.value(forHTTPHeaderField: "Authorization"), "Bearer pk_test")
        XCTAssertNotNil(r.request.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(r.query["company_id"], "pk_test")
        XCTAssertEqual(r.body?["consent"] as? [String: Bool], ["analytics": true, "marketing": true])

        let evs = events(r)
        XCTAssertEqual(evs.map { $0["name"] as? String }, ["viewed", "added", "page_view"])
        let aid = try XCTUnwrap(Hermetica.anonymousId)
        XCTAssertTrue(evs.allSatisfy { $0["anonymousId"] as? String == aid })
        XCTAssertEqual(Set(evs.compactMap { $0["dedupeKey"] as? String }).count, 3)
        XCTAssertEqual(evs[0]["value"] as? Int, 1299)
        XCTAssertEqual(evs[0]["currency"] as? String, "USD")
        let props = try XCTUnwrap(evs[0]["properties"] as? [String: Any])
        XCTAssertEqual(props["sku"] as? String, "A1")
        XCTAssertEqual(props["at"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(props["hm_sdk"] as? String, "swift-\(Hermetica.sdkVersion)")
        let page = (evs[2]["context"] as? [String: Any])?["page"] as? [String: String]
        XCTAssertEqual(page?["title"], "Home")
        XCTAssertTrue(page?["url"]?.hasSuffix("/Home") == true)
        XCTAssertEqual((evs[2]["properties"] as? [String: Any])?["screen"] as? String, "Home")
    }

    func testSplitsLargeQueuesIntoServerSizedBatches() {
        for i in 0..<45 { Hermetica.track("e\(i)") }
        flush()
        let batches = requests("/ingest/v1/batch").map(events)
        XCTAssertTrue(batches.allSatisfy { $0.count <= Core.maxBatch })
        XCTAssertEqual(Set(batches.flatMap { $0.compactMap { $0["dedupeKey"] as? String } }).count, 45)
        XCTAssertTrue(core.q.sync { core.queue.isEmpty })
    }

    func testRetriesServerErrorsWithTheSameIdempotencyKey() {
        MockURLProtocol.handler = { _ in MockURLProtocol.seen.count == 1 ? (503, Data()) : (202, Data("{}".utf8)) }
        Hermetica.track("once")
        flush()
        let sent = requests("/ingest/v1/batch")
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(Set(sent.compactMap { $0.request.value(forHTTPHeaderField: "Idempotency-Key") }).count, 1)
        XCTAssertTrue(core.q.sync { core.queue.isEmpty })
    }

    func testKeepsUnsentEventsAcrossLaunches() {
        MockURLProtocol.handler = { _ in (500, Data()) }
        Hermetica.track("a")
        Hermetica.track("b")
        flush()
        XCTAssertEqual(requests("/ingest/v1/batch").count, Transport.maxRetries)
        let keys = events(requests("/ingest/v1/batch")[0]).compactMap { $0["dedupeKey"] as? String }

        MockURLProtocol.reset()
        core = makeCore() // a new launch reading the same storage
        Hermetica.core = core
        flush()
        let resent = requests("/ingest/v1/batch")
        XCTAssertEqual(resent.count, 1)
        XCTAssertEqual(resent.first.map(events)?.compactMap { $0["dedupeKey"] as? String }, keys)
    }

    func testIdentifySendsIdentifiersAndAttributes() throws {
        Hermetica.setProfileAttributes(["plan": "pro"])
        core.q.sync {}
        XCTAssertTrue(requests("/ingest/v1/identify").isEmpty, "attributes wait for an identifier")

        Hermetica.identify(externalId: "u1", email: "a+b@x.co", properties: ["first_name": "Ada"])
        Hermetica.setProfileAttributes(["vip": true])
        let sent = waitFor("/ingest/v1/identify", count: 2)
        XCTAssertEqual(sent.count, 2)
        // The two requests may arrive in either order.
        let isVip = { (r: MockURLProtocol.Seen) in (r.body?["traits"] as? [String: Any])?["vip"] != nil }
        let first = try XCTUnwrap(sent.first { !isVip($0) })
        let second = try XCTUnwrap(sent.first(where: isVip))
        XCTAssertEqual(first.body?["anonymousId"] as? String, Hermetica.anonymousId)
        XCTAssertEqual(first.body?["identifiers"] as? [String: String], ["externalId": "u1", "email": "a+b@x.co"])
        XCTAssertEqual(first.body?["traits"] as? [String: String], ["plan": "pro", "first_name": "Ada"])
        XCTAssertNotNil(first.request.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(second.body?["identifiers"] as? [String: String], ["externalId": "u1", "email": "a+b@x.co"])
        XCTAssertEqual(second.body?["traits"] as? [String: Bool], ["vip": true])
    }

    func testOptOutSendsNothingAndIsRemembered() {
        Hermetica.track("before")
        let oldId = Hermetica.anonymousId
        Hermetica.setTrackingOptOut(true)
        XCTAssertTrue(Hermetica.isTrackingOptedOut)
        XCTAssertNil(Hermetica.anonymousId)

        Hermetica.track("x")
        Hermetica.identify(email: "a@b.co")
        Hermetica.handlePushOpened(userInfo: ["hermetica_message_id": "m1"])
        let push = expectation(description: "push")
        Hermetica.setPushToken("abcd") { ok in XCTAssertFalse(ok); push.fulfill() }
        let inApp = expectation(description: "inapp")
        Hermetica.fetchInAppMessages(trigger: .appOpen) { XCTAssertTrue($0.isEmpty); inApp.fulfill() }
        let fences = expectation(description: "fences")
        Hermetica.fetchGeofences { XCTAssertTrue($0.isEmpty); fences.fulfill() }
        wait(for: [push, inApp, fences], timeout: 5)
        flush()
        XCTAssertTrue(MockURLProtocol.seen.isEmpty, "opted out: no request at all")

        core = makeCore()
        Hermetica.core = core
        XCTAssertTrue(Hermetica.isTrackingOptedOut, "remembered across launches")

        Hermetica.setTrackingOptOut(false)
        Hermetica.track("after")
        flush()
        let evs = requests("/ingest/v1/batch").flatMap(events)
        XCTAssertEqual(evs.map { $0["name"] as? String }, ["after"], "events from before the opt-out were discarded")
        XCTAssertNotEqual(evs.first?["anonymousId"] as? String, oldId)
    }

    // MARK: push

    func testPushTokenRegistrationBody() throws {
        core.pushStatus = { $0(.provisional, .restricted) }
        Hermetica.identify(email: "a@b.co")
        let done = expectation(description: "register")
        Hermetica.setPushToken(Data([0xde, 0xad, 0xbe, 0xef]), environment: .sandbox) { ok in XCTAssertTrue(ok); done.fulfill() }
        wait(for: [done], timeout: 5)

        let r = try XCTUnwrap(requests("/client/push-tokens").first)
        XCTAssertEqual(r.query["company_id"], "pk_test")
        XCTAssertNotNil(r.request.value(forHTTPHeaderField: "Idempotency-Key"))
        let data = try XCTUnwrap(r.body?["data"] as? [String: Any])
        XCTAssertEqual(data["type"] as? String, "push-token")
        let a = try XCTUnwrap(data["attributes"] as? [String: Any])
        XCTAssertEqual(a["token"] as? String, "deadbeef")
        XCTAssertEqual(a["platform"] as? String, "ios")
        XCTAssertEqual(a["vendor"] as? String, "apns")
        XCTAssertEqual(a["enablement_status"] as? String, "PROVISIONAL")
        XCTAssertEqual(a["background"] as? String, "RESTRICTED")
        let aid = try XCTUnwrap(Hermetica.anonymousId)
        let meta = try XCTUnwrap(a["device_metadata"] as? [String: String])
        XCTAssertEqual(meta["device_id"], aid)
        XCTAssertEqual(meta["sdk_version"], "swift-\(Hermetica.sdkVersion)")
        XCTAssertEqual(meta["os_name"], "ios")
        XCTAssertEqual(meta["environment"], "sandbox")
        XCTAssertEqual(Set(meta.keys), ["device_id", "sdk_version", "device_model", "os_name", "os_version", "app_name", "app_version", "app_build", "app_id", "environment"])
        let profile = (a["profile"] as? [String: Any])?["data"] as? [String: Any]
        XCTAssertEqual(profile?["type"] as? String, "profile")
        XCTAssertEqual(profile?["attributes"] as? [String: String], ["email": "a@b.co", "anonymous_id": aid])
        XCTAssertEqual(Hermetica.pushToken, "deadbeef")

        let gone = expectation(description: "unregister")
        Hermetica.unregisterPushToken { ok in XCTAssertTrue(ok); gone.fulfill() }
        wait(for: [gone], timeout: 5)
        let u = try XCTUnwrap(requests("/client/push-token-unregister").first?.body?["data"] as? [String: Any])
        XCTAssertEqual(u["type"] as? String, "push-token-unregister")
        XCTAssertEqual(u["attributes"] as? [String: String], ["token": "deadbeef", "platform": "ios", "vendor": "apns"])
        XCTAssertNil(Hermetica.pushToken)
    }

    func testIdentifyMovesARegisteredTokenToTheProfile() {
        let done = expectation(description: "register")
        Hermetica.setPushToken("tok", environment: .production) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        Hermetica.identify(externalId: "u9")
        let sent = waitFor("/client/push-tokens", count: 2)
        let who = ((sent.last?.body?["data"] as? [String: Any])?["attributes"] as? [String: Any]).flatMap { ($0["profile"] as? [String: Any])?["data"] as? [String: Any] }
        XCTAssertEqual((who?["attributes"] as? [String: String])?["external_id"], "u9")
    }

    func testPushOpenTracksTheMessageAndReturnsTheDeepLink() {
        XCTAssertEqual(Hermetica.handlePushOpened(userInfo: ["hermetica_message_id": "m1", "deep_link": "shop://cart"]), "shop://cart")
        XCTAssertEqual(Hermetica.handlePushOpened(userInfo: ["aps": ["alert": "hi"], "data": ["hermetica_message_id": "m2", "url": "https://x.test"]]), "https://x.test")
        XCTAssertNil(Hermetica.handlePushOpened(userInfo: ["other": 1]))
        flush()
        let evs = requests("/ingest/v1/batch").flatMap(events)
        XCTAssertEqual(evs.map { $0["name"] as? String }, ["$opened_push", "$opened_push"])
        XCTAssertEqual(evs.map { ($0["properties"] as? [String: Any])?["hermetica_message_id"] as? String }, ["m1", "m2"])
    }

    // MARK: in-app

    private static let message = """
    {"items":[{"id":"7c1e0f8a-0000-4000-8000-000000000001","variant":"b","layout":"carousel","priority":5,"queued":false,
      "content":{"blocks":[{"type":"heading","text":"Hi"},{"type":"video"},{"type":"buttons","buttons":[
        {"label":"Shop","action":"deep_link","value":"shop://sale"},{"label":"Ping","action":"event","value":"inapp_ping","style":"secondary"}]}]},
      "style":{"background":"#ffffff","textColor":"#111111","accentColor":"#2563eb","radius":12,"dismissible":true}}]}
    """

    private func fetch(_ t: InAppTrigger) -> [InAppMessage] {
        let e = expectation(description: "fetch")
        var out: [InAppMessage] = []
        Hermetica.fetchInAppMessages(trigger: t) { out = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        return out
    }

    func testInAppFetchQueryAndEvents() throws {
        MockURLProtocol.handler = { _ in self.json(Self.message) }
        let items = fetch(.screenView("Home"))
        let m = try XCTUnwrap(items.first)
        XCTAssertEqual(m.layout, .modal, "unknown layouts fall back to modal")
        XCTAssertEqual(m.content.blocks.map(\.type), [.heading, .unknown, .buttons])
        XCTAssertEqual(m.content.blocks[2].buttons?.map(\.action), [.deepLink, .event])

        let q = try XCTUnwrap(requests("/client/in-app-messages").first).query
        XCTAssertEqual(q["platform"], "ios")
        XCTAssertEqual(q["trigger"], "screen_view")
        XCTAssertEqual(q["name"], "Home")
        XCTAssertEqual(q["company_id"], "pk_test")
        XCTAssertEqual(q["anonymous_id"], Hermetica.anonymousId)
        let session = try XCTUnwrap(q["session_id"])

        _ = fetch(.event("added", properties: ["sku": "A1"]))
        XCTAssertEqual(requests("/client/in-app-messages").last?.query["properties"], #"{"sku":"A1"}"#)

        Hermetica.reportInAppEvent(m, type: .impression)
        let ev = try XCTUnwrap(waitFor("/client/in-app-events").first?.body)
        XCTAssertEqual((ev["events"] as? [[String: String]])?.first, ["messageId": m.id, "variant": "b", "type": "impression", "platform": "ios", "sessionId": session])
        XCTAssertEqual((ev["profile"] as? [String: String])?["anonymousId"], Hermetica.anonymousId)
    }

    func testInAppButtonsReportClicksAndRunActions() throws {
        MockURLProtocol.handler = { _ in self.json(Self.message) }
        let m = try XCTUnwrap(fetch(.appOpen).first)
        var opened: [URL] = []
        core.openURL = { opened.append($0) }
        let buttons = try XCTUnwrap(m.content.blocks[2].buttons)
        Hermetica.performInAppAction(buttons[0], message: m)
        Hermetica.performInAppAction(buttons[1], message: m)
        drainMain()
        XCTAssertEqual(opened, [URL(string: "shop://sale")!])
        let clicks = waitFor("/client/in-app-events", count: 2).compactMap { ($0.body?["events"] as? [[String: String]])?.first }
        XCTAssertEqual(clicks.map { $0["type"] }, ["click", "click"])
        XCTAssertEqual(Set(clicks.compactMap { $0["button"] }), ["Shop", "Ping"])
        flush()
        let evs = requests("/ingest/v1/batch").flatMap(events)
        XCTAssertEqual(evs.map { $0["name"] as? String }, ["inapp_ping"])
        XCTAssertEqual((evs.first?["properties"] as? [String: Any])?["hermetica_message_id"] as? String, m.id)
    }

    func testDelegateGetsEachMessageOncePerSession() {
        final class Spy: HermeticaInAppDelegate {
            var shown: [String] = []
            func hermetica(present message: InAppMessage) -> Bool { shown.append(message.id); return true }
        }
        let spy = Spy()
        Hermetica.inAppDelegate = spy
        MockURLProtocol.handler = { _ in self.json(Self.message) }
        Hermetica.enableInAppMessages()
        _ = waitFor("/client/in-app-messages")
        Hermetica.screen("Home")
        _ = waitFor("/client/in-app-messages", count: 2)
        core.q.sync {}
        drainMain()
        XCTAssertEqual(spy.shown.count, 1)
        XCTAssertEqual(requests("/client/in-app-messages").first?.query["trigger"], "app_open")
    }

    // MARK: geofences

    func testGeofenceListAndTransitions() {
        MockURLProtocol.handler = { _ in self.json(#"{"data":[{"type":"geofence","id":"g1","attributes":{"name":"Store","latitude":1,"longitude":2,"radius":150}}]}"#) }
        let e = expectation(description: "fences")
        var fences: [Geofence] = []
        Hermetica.fetchGeofences { fences = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(fences, [Geofence(id: "g1", name: "Store", latitude: 1, longitude: 2, radius: 150)])

        Hermetica.reportGeofence(.dwell, geofenceId: "g1")
        core.handleRegion(Core.regionPrefix + "g2", .enter)
        core.handleRegion("app-region", .exit) // not ours
        flush()
        let evs = requests("/ingest/v1/batch").flatMap(events)
        XCTAssertEqual(evs.map { $0["name"] as? String }, ["$geofence_dwell", "$geofence_enter"])
        XCTAssertEqual(evs.map { ($0["properties"] as? [String: Any])?["geofence_id"] as? String }, ["g1", "g2"])
    }

    func testNearestFencesFitTheRegionLimit() {
        let f = (0..<3).map { Geofence(id: "g\($0)", name: "", latitude: Double($0), longitude: 0, radius: 100) }
        XCTAssertEqual(Core.nearest(f, to: CLLocation(latitude: 2, longitude: 0), limit: 2).map(\.id), ["g2", "g1"])
        XCTAssertEqual(Core.nearest(f, to: nil, limit: 2).map(\.id), ["g0", "g1"])
    }
}
