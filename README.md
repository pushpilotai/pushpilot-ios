# PushPilot iOS SDK

Swift package that registers your app's installation with PushPilot and forwards its Apple push (APNs) device token, so you can send pushes to individual users from the PushPilot dashboard. PushPilot sends to Apple directly with your APNs key; no Firebase is involved.

- iOS 15 or later, Swift Package Manager, no third-party dependencies.
- Never asks for notification permission, never registers for remote notifications on its own, never swizzles methods, collects no IDFA, IDFV or hardware identifier.
- Two libraries: `PushPilot` for your app, and `PushPilotNotificationService` for an optional Notification Service Extension that shows images and buttons.

## Install

In Xcode choose **File › Add Package Dependencies…**, enter this repository's URL, add the `PushPilot` library to your app target and, if you want images or buttons, the `PushPilotNotificationService` library to your Notification Service Extension target. In a `Package.swift`:

```swift
.package(url: "<this repository's URL>", from: "2.0.0")
// app target:
.product(name: "PushPilot", package: "pushpilot-ios")
// Notification Service Extension target:
.product(name: "PushPilotNotificationService", package: "pushpilot-ios")
```

## Integrate

1. **Create an APNs auth key** in your Apple Developer account (*Certificates, Identifiers & Profiles › Keys*, with *Apple Push Notifications service* enabled) and download the `.p8` file. Apple lets you download it only once.
2. **Give PushPilot the key.** In the dashboard, add an APNs push project with the `.p8` file, its **Key ID** and your **Team ID** (top right of the developer account). Then create the iOS app on that project with your app's **bundle id**, which is the APNs topic, and copy its public SDK key. One key works for all your apps and for both sandbox and production.
3. **Turn on Push Notifications** in your app target: *Signing & Capabilities › + Capability › Push Notifications*. This adds the `aps-environment` entitlement.
4. **Initialise PushPilot, register for the device token and forward it:**

```swift
import PushPilot
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushPilot.initialize(sdkKey: "pp_sdk_…")
        UNUserNotificationCenter.current().delegate = self // set it here, before launch ends, to get taps that launch the app
        // Register at every launch once the user has allowed notifications, so the token stays current.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
                DispatchQueue.main.async { application.registerForRemoteNotifications() }
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushPilot.setPushToken(deviceToken)
    }

    // Taps on a push or one of its buttons.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if !PushPilot.handleNotificationResponse(response) {
            // not a PushPilot push: handle it yourself
        }
        completionHandler()
    }
}
```

5. **Ask for notification permission yourself**, when it suits your app, and register once it is granted. PushPilot never prompts; it reads the result and reports it.

```swift
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
    if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
}
```

6. **Identify the user** after login with `PushPilot.setExternalUserId(user.id)` and call `PushPilot.logout()` at logout.
7. **Optional: show images and buttons** with a Notification Service Extension (below).

Calls made before `initialize` are applied at once if an earlier launch saved the SDK key, and are otherwise queued until it runs. In a SwiftUI app, attach the delegate with `@UIApplicationDelegateAdaptor(AppDelegate.self)`.

### Taps and links

Forward `userNotificationCenter(_:didReceive:withCompletionHandler:)` to `PushPilot.handleNotificationResponse(_:)` as above; the SDK swizzles nothing. For a PushPilot push it records the click (with the button's id if a button was tapped) and opens the link: the button's `url` for a button, the push's `url` for a tap on the push itself. A button without a `url` records the click and opens nothing. Swiping a push away is not recorded. The call returns `false` for pushes that are not from PushPilot and does nothing with them.

If you get the tap as plain values instead of a `UNNotificationResponse` (some wrappers and notification libraries hand over only those), call `PushPilot.handleNotificationTap(userInfo:actionIdentifier:)` with the notification's `userInfo` and the action identifier iOS reported. It does the same and returns the same. Each notification is handled once per app process, so if both your code and a library forward the same tap, it is still counted and opened once.

Without a link handler the system opens the link (`UIApplication.open`): a web page in Safari, a universal link or your own URL scheme in your app. To route links yourself, set a handler in `application(_:didFinishLaunchingWithOptions:)`. From then on it receives every PushPilot link instead of the system, on the main thread, once per tap; it returns nothing, and the SDK never opens the link as well:

```swift
PushPilot.setLinkHandler { url in
    router.open(url) // or UIApplication.shared.open(url) for links you don't handle
}
```

The handler set at the moment a tap is handled decides who opens its link. iOS delivers the tap that launched a killed app after `didFinishLaunchingWithOptions` returns, so a handler set there also gets that tap. A handler set later does not get links tapped before it was set; the system has already opened those. A link is never lost and never opened twice.

Your own key-value data from the dashboard is in the push's `userInfo["data"]` as `[String: String]`:

```swift
let data = response.notification.request.content.userInfo["data"] as? [String: String] ?? [:]
```

### Sandbox and production

Apple has two push environments, and a device token only works in the one it was issued for. The SDK works out which one from the running build and sends it as `apns_environment`, so PushPilot uses the matching Apple host:

| Build | Environment |
|---|---|
| Run from Xcode on a device (development provisioning profile) | `sandbox` |
| Simulator | `sandbox` |
| TestFlight and App Store | `production` |
| Ad hoc and enterprise | `production` |

It reads the `aps-environment` entitlement from the provisioning profile embedded in the app; builds without one (TestFlight and App Store) are production. Nothing needs configuring. Simulators on Apple silicon Macs can receive real sandbox pushes.

### Images and buttons: Notification Service Extension

iOS shows an image in a push only when an app extension attaches it, and shows buttons only for a category registered on the device. PushPilot pushes carry the image as `image_url` and up to three `buttons`, and set `mutable-content`, so iOS hands them to your extension first. One extension does both.

1. In Xcode choose **File › New › Target… › Notification Service Extension**. Give it a deployment target of iOS 15 or later.
2. Add the `PushPilotNotificationService` library (not `PushPilot`) to the new extension target.
3. Replace the generated `NotificationService` class with:

```swift
import PushPilotNotificationService
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let pushPilot = PushPilotServiceExtension()

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        if pushPilot.didReceive(request, withContentHandler: contentHandler) { return }
        contentHandler(request.content) // not a PushPilot push: handle it yourself, or deliver it as is
    }

    override func serviceExtensionTimeWillExpire() {
        pushPilot.serviceExtensionTimeWillExpire()
    }
}
```

`didReceive` returns `false` for pushes that are not from PushPilot and leaves them to you, so the extension can be shared with other code. For PushPilot pushes it:

- **Buttons:** registers a notification category for exactly that push's buttons (its id is `pushpilot.` plus a hash of the buttons, so the same set reuses one category) next to your app's own categories, which it keeps, and sets it on the push. A button with a `url` opens the app when tapped so the link can be opened; one without dismisses the push without opening the app.
- **Image:** downloads the `https` image (up to 10 MB, a type iOS can attach such as JPEG, PNG or GIF) and attaches it.

Anything that fails is skipped and the push is still delivered: without buttons if the category could not be registered, without the image if there is none, the download fails, or iOS's time limit for the extension runs out. Without the extension, PushPilot pushes still arrive and taps on them still work; they just have no image or buttons.

## API

All `PushPilot` methods are static, callable from any thread, and return at once; disk and network work runs on a private background queue.

| Method | What it does |
|---|---|
| `initialize(sdkKey:baseUrl:)` | Starts the SDK. Call once at launch; later calls are ignored. The key and `baseUrl` are saved on the device, so in a process where the app has not called `initialize` yet (for example one launched by a tap on a push) the first SDK call starts the SDK from them; `initialize` then replaces them. `baseUrl` defaults to `PushPilot.defaultBaseUrl` (`https://pushpilot.ai`) and only needs setting for a self-hosted server. Other platforms call this `init`; Swift reserves `init` for initialisers, so it is `initialize` here. |
| `setPushToken(_:)` | Takes the `Data` from `didRegisterForRemoteNotificationsWithDeviceToken` as is and syncs it. Pass `nil` to clear it; the device then stops receiving pushes. |
| `setExternalUserId(_:)` | Links the installation to your own user id (1–255 characters). A push to that id reaches all of the user's installations. |
| `setAttributes(_:)` | Sets custom attributes, e.g. `["plan": "pro", "trial_ends": date]`. Values are `String`, `Bool`, a number, `Date` (sent as ISO 8601) or `nil` to remove. Only attributes declared for the app in the dashboard are stored; others are dropped by the server with a logged warning. |
| `setTopics(_:)` | Replaces the installation's topics. Names are 1–255 letters, digits or `-_.~%`; invalid names are dropped with a log message, the rest are de-duplicated and sorted, and only the first 100 are kept. |
| `logout()` | Clears the external user id. The installation stays registered and keeps receiving pushes. |
| `forget()` | Deletes this installation from PushPilot and clears everything the SDK stored. The SDK starts over with a new installation id, which is registered only after your next PushPilot call (any setter) or the next app launch. To stop pushes on the device as well, also call `UIApplication.shared.unregisterForRemoteNotifications()`. |
| `handleMessage(_:) -> Bool` | Returns whether a received push's `userInfo` came from PushPilot (it carries `source` = `pushpilot`). No network call, works without `initialize`. |
| `handleNotificationResponse(_:) -> Bool` | Handles a tap: records the click and opens the link (see *Taps and links*). Returns whether the push came from PushPilot. |
| `handleNotificationTap(userInfo:actionIdentifier:) -> Bool` | The same, from the notification's `userInfo` and the action identifier. |
| `setLinkHandler(_:)` | Routes PushPilot links to your closure instead of the system. Pass `nil` to go back to the system. |

`PushPilotServiceExtension` (in `PushPilotNotificationService`) has `didReceive(_:withContentHandler:) -> Bool` and `serviceExtensionTimeWillExpire()`, described above.

Invalid values (an empty user id, an unsupported attribute type, a bad topic name) are dropped with a log message instead of being sent, so they cannot block later syncs.

## What the SDK sends, and when

Every request goes to `POST {baseUrl}/api/sdk/v1/register/`, `/sync/`, `/forget/` or `/events/` over HTTPS, authenticated with your public SDK key in the `X-SDK-Key` header.

| Field | Value | Source |
|---|---|---|
| `installation_id` | Random UUID created on first run | SDK; Keychain, this device only |
| `token` | APNs device token as lowercase hex, or null | `setPushToken` |
| `token_kind` | `apns` (sent only with a token) | SDK |
| `apns_environment` | `sandbox` or `production` (sent only with a token) | Read from the build's provisioning, see above |
| `external_user_id` | Your user id, or null | `setExternalUserId`, cleared by `logout` |
| `topics` | Valid topic names, sorted, at most 100 (sent only once you have called `setTopics`) | `setTopics` |
| `attributes` | Declared custom attributes (sent only once set) | `setAttributes` |
| `notification_permission` | `granted`, `denied`, `provisional` or `unknown` | Read from `UNUserNotificationCenter`, never requested |
| `os_version` | e.g. `17.2` | Automatic |
| `app_version` | `CFBundleShortVersionString` | Automatic |
| `sdk_version` | e.g. `2.0.0` | Automatic |
| `device_model` | Model identifier, e.g. `iPhone15,2` | Automatic |
| `locale` | BCP 47 tag, e.g. `en-US` | Automatic |
| `timezone` | IANA id, e.g. `Europe/Berlin` | Automatic |

**Tracked events** go to `/events/`, as `{"events": [...]}` with up to 100 per request. Each event is:

| Field | Value |
|---|---|
| `notification_id` | The id PushPilot put in the push |
| `installation_id` | This installation's id |
| `type` | `clicked`: the user tapped the push or one of its buttons |
| `button_id` | The tapped button's id; absent for a tap on the push itself |
| `at` | When it happened, RFC 3339 in UTC |

Only taps are tracked. Swiping a push away is not, and delivery is not either (reporting it would need an App Group shared between the app and the extension, which is not done yet). Nothing else is sent: no IDFA, IDFV, hardware identifier, location, email, phone, or other usage. The Notification Service Extension helper sends nothing to PushPilot; it only downloads the image URL in the push and registers the button category on the device.

When:

- **On change.** Any call above triggers a sync, and so does a change in permission, APNs environment, OS or app version, locale or timezone, which the SDK checks at launch and whenever the app becomes active. Changes within about a second go out together in one request.
- **Daily freshness.** At launch and whenever the app becomes active, the SDK syncs if the last sync is more than 24 hours old; otherwise nothing is sent.
- **First request** for an installation is `register`, sent as soon as `initialize` runs, with `token` null if the app has not passed one yet; the dashboard then shows the device as "No token", which confirms the SDK is working. Later requests are `sync`.
- **`forget`** sends only `installation_id` to `/forget/`. The new installation id is not registered until the next setter call or launch.
- **Events** are saved to disk when they happen and sent shortly after, in batches of up to 100; if the app is closed first, they are sent at the next launch. Failures are retried as below, except that a `4xx` other than `429` drops that batch. At most 500 events wait; beyond that the oldest are dropped.
- **Failures** are retried with exponential backoff from 1 second to 5 minutes with jitter; a `429` waits at least the server's `Retry-After`. Other `4xx` answers are not retried until the data changes or 24 hours pass. Unsent changes, events and a pending `forget` survive the app being closed.

Nothing the SDK stores moves to another phone: the installation id is in the Keychain with a this-device-only class, and the rest of its state (token, user id, topics, attributes, queued events, sync bookkeeping) is a file in `Application Support/PushPilot/`, a folder excluded from iCloud and computer backups. The SDK key and `baseUrl` from the last `initialize` are saved in `config.json` in that same folder: it is readable after the first unlock, so a tap or background launch can start the SDK, and it needs no `UserDefaults`, a required-reason API. The key is public, so it is not kept in the Keychain. `forget()` keeps it, as it is the app's setting rather than data about the user. A restored phone therefore registers as a new installation. Apple issues it a new device token when the app registers again, but a user who is still logged in after the restore is only linked again if you call `setExternalUserId` at launch whenever someone is logged in (repeated calls with the same id send nothing).

The SDK never logs the push token or the SDK key.

## App Store Connect: App Privacy

Both libraries ship a `PrivacyInfo.xcprivacy` manifest that Xcode merges into your app's privacy report. In App Store Connect's **App Privacy** section, declare for PushPilot:

- **Identifiers › Device ID**: collected, used for *App Functionality*, linked to the user (when you set an external user id), not used for tracking.
- **Identifiers › User ID**: collected only if you call `setExternalUserId`; *App Functionality*, linked to the user, not used for tracking.
- **Usage Data › Product Interaction**: taps on notifications and their buttons; *Analytics*, linked to the user (through the installation), not used for tracking.
- Anything you put in **custom attributes**: declare it under the matching Apple category yourself, as only your app knows what it contains.

The extension helper collects no data. PushPilot does not track users across apps, so no App Tracking Transparency prompt is needed for it. Neither library uses any of Apple's required-reason APIs (state is a file, not `UserDefaults`).

## Example app

`Example/PushPilotExample.xcodeproj` is a SwiftUI app with a Notification Service Extension target. The app initialises PushPilot at launch, sets a link handler that logs and opens links, registers for remote notifications once permission is granted, forwards the device token and taps, and has buttons for permission, set user id, set topics, logout and forget. The extension uses `PushPilotServiceExtension`. It builds and runs on the simulator as is.

The **Show a test push in 3 seconds** button tries buttons and taps without a server: it shows a local notification with a canned PushPilot push (two buttons, Hindi and Arabic text). A local notification never goes through the Notification Service Extension, so the app runs the same helper on it first to register the buttons. Lock the screen or go to the home screen, then long-press the push (or swipe left and tap **View**) to see the buttons. This exercises button registration, the tap, the click event (queued; it is only sent with a real SDK key) and the link. It does not exercise the extension itself, the image download or the extension's time limit, which need a real push from APNs. `xcrun simctl push` does not run the extension either. To try it with real pushes:

1. Open `Example/PushPilotExample.xcodeproj` in Xcode.
2. For both targets, set your signing team and bundle ids you own (the extension's must start with the app's, e.g. `com.you.example` and `com.you.example.NotificationService`).
3. In the dashboard, add your APNs key and an iOS app with the app's bundle id, and put its SDK key in `pushPilotSdkKey` in `ExampleApp.swift`.
4. Run on a device (or a simulator on an Apple silicon Mac), tap **Allow notifications**, then send a test push, with an image URL and buttons if you like, from the dashboard's device lookup.

## Tests

```bash
xcodebuild -scheme PushPilot-Package -destination 'platform=iOS Simulator,name=iPhone 17' test
```
