# PushPilot iOS SDK

Swift package that registers your app's installation with PushPilot and forwards its Apple push (APNs) device token, so you can send pushes to individual users from the PushPilot dashboard. PushPilot sends to Apple directly with your APNs key; no Firebase is involved.

- iOS 15 or later, Swift Package Manager, no third-party dependencies.
- Never asks for notification permission, never registers for remote notifications on its own, never swizzles methods, collects no IDFA, IDFV or hardware identifier.
- Two libraries: `PushPilot` for your app, and `PushPilotNotificationService` for an optional Notification Service Extension that shows images.

## Install

In Xcode choose **File › Add Package Dependencies…**, enter this repository's URL, add the `PushPilot` library to your app target and, if you want images, the `PushPilotNotificationService` library to your Notification Service Extension target. In a `Package.swift`:

```swift
.package(url: "<this repository's URL>", from: "1.0.0")
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

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushPilot.initialize(sdkKey: "pp_sdk_…")
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
}
```

5. **Ask for notification permission yourself**, when it suits your app, and register once it is granted. PushPilot never prompts; it reads the result and reports it.

```swift
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
    if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
}
```

6. **Identify the user** after login with `PushPilot.setExternalUserId(user.id)` and call `PushPilot.logout()` at logout.
7. **Optional: show images** with a Notification Service Extension (below).

Calls made before `initialize` are queued and applied once it runs. In a SwiftUI app, attach the delegate with `@UIApplicationDelegateAdaptor(AppDelegate.self)`.

### Sandbox and production

Apple has two push environments, and a device token only works in the one it was issued for. The SDK works out which one from the running build and sends it as `apns_environment`, so PushPilot uses the matching Apple host:

| Build | Environment |
|---|---|
| Run from Xcode on a device (development provisioning profile) | `sandbox` |
| Simulator | `sandbox` |
| TestFlight and App Store | `production` |
| Ad hoc and enterprise | `production` |

It reads the `aps-environment` entitlement from the provisioning profile embedded in the app; builds without one (TestFlight and App Store) are production. Nothing needs configuring. Simulators on Apple silicon Macs can receive real sandbox pushes.

### Images: Notification Service Extension

iOS shows an image in a push only when an app extension attaches it. PushPilot pushes carry the image as `image_url` and set `mutable-content`, so iOS hands them to your extension first.

1. In Xcode choose **File › New › Target… › Notification Service Extension**. Give it a deployment target of iOS 15 or later.
2. Add the `PushPilotNotificationService` library (not `PushPilot`) to the new extension target.
3. Replace the generated `NotificationService` class with:

```swift
import PushPilotNotificationService
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let images = PushPilotImageAttacher()

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        if images.didReceive(request, withContentHandler: contentHandler) { return }
        contentHandler(request.content) // not a PushPilot push: handle it yourself, or deliver it as is
    }

    override func serviceExtensionTimeWillExpire() {
        images.serviceExtensionTimeWillExpire()
    }
}
```

`didReceive` returns `false` for pushes that are not from PushPilot and leaves them to you, so the extension can be shared with other code. For PushPilot pushes it downloads the `https` image (up to 10 MB, a type iOS can attach such as JPEG, PNG or GIF), attaches it and delivers the push. If there is no image, the download fails, or iOS's time limit for the extension runs out, the push is delivered without the image.

## API

All `PushPilot` methods are static, callable from any thread, and return at once; disk and network work runs on a private background queue.

| Method | What it does |
|---|---|
| `initialize(sdkKey:baseUrl:)` | Starts the SDK. Call once at launch; later calls are ignored. `baseUrl` defaults to `PushPilot.defaultBaseUrl` (`https://pushpilot.ai`) and only needs setting for a self-hosted server. Other platforms call this `init`; Swift reserves `init` for initialisers, so it is `initialize` here. |
| `setPushToken(_:)` | Takes the `Data` from `didRegisterForRemoteNotificationsWithDeviceToken` as is and syncs it. Pass `nil` to clear it; the device then stops receiving pushes. |
| `setExternalUserId(_:)` | Links the installation to your own user id (1–255 characters). A push to that id reaches all of the user's installations. |
| `setAttributes(_:)` | Sets custom attributes, e.g. `["plan": "pro", "trial_ends": date]`. Values are `String`, `Bool`, a number, `Date` (sent as ISO 8601) or `nil` to remove. Only attributes declared for the app in the dashboard are stored; others are dropped by the server with a logged warning. |
| `setTopics(_:)` | Replaces the installation's topics. Names are 1–255 letters, digits or `-_.~%`; invalid names are dropped with a log message, the rest are de-duplicated and sorted, and only the first 100 are kept. |
| `logout()` | Clears the external user id. The installation stays registered and keeps receiving pushes. |
| `forget()` | Deletes this installation from PushPilot and clears everything the SDK stored. The SDK starts over with a new installation id, which is registered only after your next PushPilot call (any setter) or the next app launch. To stop pushes on the device as well, also call `UIApplication.shared.unregisterForRemoteNotifications()`. |
| `handleMessage(_:) -> Bool` | Returns whether a received push's `userInfo` came from PushPilot (it carries `source` = `pushpilot`). No network call, works without `initialize`. |

`PushPilotImageAttacher` (in `PushPilotNotificationService`) has `didReceive(_:withContentHandler:) -> Bool` and `serviceExtensionTimeWillExpire()`, described above.

Invalid values (an empty user id, an unsupported attribute type, a bad topic name) are dropped with a log message instead of being sent, so they cannot block later syncs.

## What the SDK sends, and when

Every request goes to `POST {baseUrl}/api/sdk/v1/register/`, `/sync/` or `/forget/` over HTTPS, authenticated with your public SDK key in the `X-SDK-Key` header.

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
| `sdk_version` | e.g. `1.0.0` | Automatic |
| `device_model` | Model identifier, e.g. `iPhone15,2` | Automatic |
| `locale` | BCP 47 tag, e.g. `en-US` | Automatic |
| `timezone` | IANA id, e.g. `Europe/Berlin` | Automatic |

Nothing else is sent: no IDFA, IDFV, hardware identifier, location, email, phone or usage events. The Notification Service Extension helper sends nothing to PushPilot; it only downloads the image URL in the push.

When:

- **On change.** Any call above triggers a sync, and so does a change in permission, APNs environment, OS or app version, locale or timezone, which the SDK checks at launch and whenever the app becomes active. Changes within about a second go out together in one request.
- **Daily freshness.** At launch and whenever the app becomes active, the SDK syncs if the last sync is more than 24 hours old; otherwise nothing is sent.
- **First request** for an installation is `register`, sent as soon as `initialize` runs, with `token` null if the app has not passed one yet; the dashboard then shows the device as "No token", which confirms the SDK is working. Later requests are `sync`.
- **`forget`** sends only `installation_id` to `/forget/`. The new installation id is not registered until the next setter call or launch.
- **Failures** are retried with exponential backoff from 1 second to 5 minutes with jitter; a `429` waits at least the server's `Retry-After`. Other `4xx` answers are not retried until the data changes or 24 hours pass. Unsent changes and a pending `forget` survive the app being closed.

Nothing the SDK stores moves to another phone: the installation id is in the Keychain with a this-device-only class, and the rest of its state (token, user id, topics, attributes, sync bookkeeping) is a file in `Application Support/PushPilot/`, a folder excluded from iCloud and computer backups. A restored phone therefore registers as a new installation. Apple issues it a new device token when the app registers again, but a user who is still logged in after the restore is only linked again if you call `setExternalUserId` at launch whenever someone is logged in (repeated calls with the same id send nothing).

The SDK never logs the push token or the SDK key.

## App Store Connect: App Privacy

Both libraries ship a `PrivacyInfo.xcprivacy` manifest that Xcode merges into your app's privacy report. In App Store Connect's **App Privacy** section, declare for PushPilot:

- **Identifiers › Device ID**: collected, used for *App Functionality*, linked to the user (when you set an external user id), not used for tracking.
- **Identifiers › User ID**: collected only if you call `setExternalUserId`; *App Functionality*, linked to the user, not used for tracking.
- Anything you put in **custom attributes**: declare it under the matching Apple category yourself, as only your app knows what it contains.

The image helper collects no data. PushPilot does not track users across apps, so no App Tracking Transparency prompt is needed for it. Neither library uses any of Apple's required-reason APIs (state is a file, not `UserDefaults`).

## Example app

`Example/PushPilotExample.xcodeproj` is a SwiftUI app with a Notification Service Extension target. The app initialises PushPilot at launch, registers for remote notifications once permission is granted, forwards the device token, and has buttons for permission, set user id, set topics, logout and forget. The extension uses `PushPilotImageAttacher`. It builds and runs on the simulator as is. To try it with real pushes:

1. Open `Example/PushPilotExample.xcodeproj` in Xcode.
2. For both targets, set your signing team and bundle ids you own (the extension's must start with the app's, e.g. `com.you.example` and `com.you.example.NotificationService`).
3. In the dashboard, add your APNs key and an iOS app with the app's bundle id, and put its SDK key in `pushPilotSdkKey` in `ExampleApp.swift`.
4. Run on a device (or a simulator on an Apple silicon Mac), tap **Allow notifications**, then send a test push, with an image URL if you like, from the dashboard's device lookup.

## Tests

```bash
xcodebuild -scheme PushPilot-Package -destination 'platform=iOS Simulator,name=iPhone 17' test
```
