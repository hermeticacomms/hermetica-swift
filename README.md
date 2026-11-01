# Hermetica iOS SDK

Events, profiles, push notifications, in-app messages and geofences for iOS apps (iOS 13+, Swift 5.9+).

## Install

**Swift Package Manager**: in Xcode choose *File → Add Package Dependencies* and enter
`https://github.com/hermeticacomms/hermetica-swift`, or add it to `Package.swift`:

```swift
.package(url: "https://github.com/hermeticacomms/hermetica-swift", from: "0.1.0")
// target dependency:
.product(name: "HermeticaSDK", package: "hermetica-swift")
```

**CocoaPods**:

```ruby
pod 'HermeticaSDK', '~> 0.1'
```

## Quick start

```swift
import HermeticaSDK

// application(_:didFinishLaunchingWithOptions:)
Hermetica.initialize(siteKey: "YOUR_PUBLIC_SITE_KEY", baseURL: URL(string: "https://your-hermetica-api")!)

Hermetica.identify(externalId: "user-123", email: "ada@example.com", properties: ["first_name": "Ada"])
Hermetica.setProfileAttributes(["plan": "pro"])
Hermetica.track("Added to Cart", properties: ["sku": "A1"], value: 1299, currency: "USD") // value in cents
Hermetica.screen("Checkout")
Hermetica.reset() // on logout: forgets the identifiers and starts a new anonymous visitor
```

Events are queued on the device, stored across launches, and sent in batches of up to 20: every 10 seconds, when 20 are
waiting, and when the app goes to the background. Failed sends are retried with backoff and kept for the next launch.
Every request carries an `Idempotency-Key`, and every event a de-duplication key, so retries never double-count.

### Tracking opt-out

```swift
Hermetica.setTrackingOptOut(true)
```

While opted out the SDK sends nothing at all (events, identify, push registration, in-app messages, geofences), drops
queued events and forgets the anonymous id. The choice is remembered across launches. If your app must ask for consent
first, opt out at first launch and opt back in once the user agrees. Consent and suppression are also enforced on the server.

## Push notifications

1. Enable the *Push Notifications* capability and upload your APNs key in Hermetica.
2. Ask for permission yourself, register with APNs, and hand the token over:

```swift
func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    Hermetica.setPushToken(token) // the APNs environment is read from the provisioning profile; pass `environment:` to override
}
```

3. Track opens and follow deep links from your `UNUserNotificationCenterDelegate`:

```swift
func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                            withCompletionHandler done: @escaping () -> Void) {
    Hermetica.handleNotificationResponse(response) // tracks $opened_push, opens the deep link (openDeepLink: false to do it yourself)
    done()
}

func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
    done(Hermetica.presentationOptions(for: n))
}
```

`Hermetica.pushPermissionStatus { status in ... }` reports the permission as the server records it, and is sent with every
token. `identify` and `reset` move the registered token to the current profile; `Hermetica.unregisterPushToken()` stops
pushes to the device.

## In-app messages

```swift
Hermetica.enableInAppMessages() // checks now (app open), then on every screen() and track()
```

The server decides which messages fit (targeting, eligibility, frequency caps); the SDK shows the best one, each message at
most once per session. The built-in presenter draws modals, banners, bottom sheets and full-screen messages with images,
headings, text and buttons, and reports impressions, clicks and dismissals. `deep_link` buttons open their link, `url`
buttons open http(s) links, `event` buttons track the named event.

To render messages yourself or route button actions, set a delegate:

```swift
final class InAppHandler: HermeticaInAppDelegate {
    func hermetica(present message: InAppMessage) -> Bool {
        // show it, then: Hermetica.reportInAppEvent(message, type: .impression)
        // on a tap:      Hermetica.performInAppAction(button, message: message)
        // on close:      Hermetica.reportInAppEvent(message, type: .dismiss)
        return true // false = use the built-in presenter
    }
    func hermetica(handle button: InAppButton, in message: InAppMessage) -> Bool {
        return false // true when you handled the link or event yourself
    }
}
let handler = InAppHandler() // keep a strong reference: the SDK holds it weakly
Hermetica.inAppDelegate = handler
```

`Hermetica.fetchInAppMessages(trigger:completion:)` returns the eligible messages without showing anything.

## Geofences

Geofences are opt-in and never trigger a permission prompt: the SDK only monitors regions when your app already holds
*Always* location access. iOS relaunches the app for region events, so call it at every launch.

```swift
// in application(_:didFinishLaunchingWithOptions:), after initialize
Hermetica.startGeofenceMonitoring() // false when there is no Always access
```

The SDK fetches the site's geofences, monitors the nearest ones within iOS's 20-region limit (regions your app monitors
itself count towards it and are left alone), and sends `$geofence_enter` / `$geofence_exit` events that can start journeys.
`Hermetica.stopGeofenceMonitoring()` removes its regions. If you run your own geofencing, use
`Hermetica.fetchGeofences { fences in ... }` and `Hermetica.reportGeofence(.enter, geofenceId: id)` (also `.exit`, `.dwell`).

## Debugging

`Hermetica.debug = true` logs what is queued, dropped and sent (never the site key).

## License

MIT
