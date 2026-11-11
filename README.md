# PushPilot iOS SDK

Swift package that registers your app's installation with PushPilot and forwards its Firebase Cloud Messaging (FCM) token, so you can send pushes to individual users from the PushPilot dashboard.

- iOS 15 or later, Swift Package Manager, no third-party dependencies.
- No Firebase dependency: your app keeps its own Firebase setup and passes the FCM token in.
- Never asks for notification permission, never swizzles methods, collects no IDFA, IDFV or hardware identifier.

## Install

In Xcode choose **File › Add Package Dependencies…**, enter this repository's URL and add the `PushPilot` library to your app target. In a `Package.swift`:

```swift
.package(url: "<this repository's URL>", from: "1.0.0")
// target dependency:
.product(name: "PushPilot", package: "pushpilot-ios")
```

## Integrate

iOS pushes reach the device through FCM, which forwards them to Apple (APNs) with your APNs key.

1. **Upload your APNs key to Firebase.** In the Firebase console open *Project settings › Cloud Messaging › Apple app configuration* and upload your APNs authentication key (`.p8`). Without it FCM cannot deliver to iOS.
2. **Set up Firebase Messaging in your app** as Firebase documents: add `FirebaseMessaging` with Swift Package Manager, add your `GoogleService-Info.plist`, and turn on the *Push Notifications* capability.
3. **Create the app in PushPilot** (dashboard › Apps, on an active Firebase project) and copy its public SDK key.
4. **Initialise PushPilot at launch and forward the FCM token:**

```swift
import FirebaseCore
import FirebaseMessaging
import PushPilot

final class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushPilot.initialize(sdkKey: "pp_sdk_…")
        FirebaseApp.configure()
        Messaging.messaging().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        PushPilot.setPushToken(fcmToken)
    }
}
```

5. **Ask for notification permission yourself**, when it suits your app, with `UNUserNotificationCenter.current().requestAuthorization(options:)`. PushPilot never prompts; it reads the result and reports it.
6. **Identify the user** after login with `PushPilot.setExternalUserId(user.id)` and call `PushPilot.logout()` at logout.

`initialize` does not touch Firebase, so it can run before or after `FirebaseApp.configure()`. Calls made before `initialize` are queued and applied once it runs.

## API

All methods are static on `PushPilot`, callable from any thread, and return at once; disk and network work runs on a private background queue.

| Method | What it does |
|---|---|
| `initialize(sdkKey:baseUrl:)` | Starts the SDK. Call once at launch; later calls are ignored. `baseUrl` defaults to `PushPilot.defaultBaseUrl` (`https://pushpilot.ai`) and only needs setting for a self-hosted server. Other platforms call this `init`; Swift reserves `init` for initialisers, so it is `initialize` here. |
| `setPushToken(_:)` | Stores the FCM token and syncs it. Pass `nil` to clear it; the device then stops receiving pushes. |
| `setExternalUserId(_:)` | Links the installation to your own user id (1–255 characters). A push to that id reaches all of the user's installations. |
| `setAttributes(_:)` | Sets custom attributes, e.g. `["plan": "pro", "trial_ends": date]`. Values are `String`, `Bool`, a number, `Date` (sent as ISO 8601) or `nil` to remove. Only attributes declared for the app in the dashboard are stored; others are dropped by the server with a logged warning. |
| `setTopics(_:)` | Replaces the installation's topics (at most 100; letters, digits and `-_.~%`). |
| `logout()` | Clears the external user id. The installation stays registered and keeps receiving pushes. |
| `forget()` | Deletes this installation from PushPilot and clears everything the SDK stored. The SDK starts over with a new installation id, which is registered only once the app passes a push token again. To stop pushes as well, also delete the FCM token with `Messaging.messaging().deleteToken`. |
| `handleMessage(_:) -> Bool` | Returns whether a received push's `userInfo` came from PushPilot (it carries `source` = `pushpilot`). No network call, works without `initialize`. |

Invalid values (an empty user id, a bad topic name) are ignored with a log message instead of being sent, so they cannot block later syncs.

## What the SDK sends, and when

Every request goes to `POST {baseUrl}/api/sdk/v1/register/`, `/sync/` or `/forget/` over HTTPS, authenticated with your public SDK key in the `X-SDK-Key` header.

| Field | Value | Source |
|---|---|---|
| `installation_id` | Random UUID created on first run | SDK; Keychain, this device only |
| `token` | FCM registration token, or null | `setPushToken` |
| `external_user_id` | Your user id, or null | `setExternalUserId`, cleared by `logout` |
| `topics` | Topic names (sent only once you have called `setTopics`) | `setTopics` |
| `attributes` | Declared custom attributes (sent only once set) | `setAttributes` |
| `notification_permission` | `granted`, `denied`, `provisional` or `unknown` | Read from `UNUserNotificationCenter`, never requested |
| `os_version` | e.g. `17.2` | Automatic |
| `app_version` | `CFBundleShortVersionString` | Automatic |
| `sdk_version` | e.g. `1.0.0` | Automatic |
| `device_model` | Model identifier, e.g. `iPhone15,2` | Automatic |
| `locale` | BCP 47 tag, e.g. `en-US` | Automatic |
| `timezone` | IANA id, e.g. `Europe/Berlin` | Automatic |

Nothing else is sent: no IDFA, IDFV, hardware identifier, location, email, phone or usage events.

When:

- **On change.** Any call above triggers a sync, and so does a change in permission, OS or app version, locale or timezone, which the SDK checks at launch and whenever the app becomes active. Changes within about a second go out together in one request.
- **Daily freshness.** At launch and whenever the app becomes active, the SDK syncs if the last sync is more than 24 hours old; otherwise nothing is sent.
- **First request** for an installation is `register`; later ones are `sync`. Nothing is registered before the app passes a push token.
- **`forget`** sends only `installation_id` to `/forget/`.
- **Failures** are retried with exponential backoff from 1 second to 5 minutes with jitter; a `429` waits at least the server's `Retry-After`. Other `4xx` answers are not retried until the data changes or 24 hours pass. Unsent changes and a pending `forget` survive the app being closed.

The SDK never logs the push token or the SDK key.

## App Store Connect: App Privacy

The package ships a `PrivacyInfo.xcprivacy` manifest that Xcode merges into your app's privacy report. In App Store Connect's **App Privacy** section, declare for PushPilot:

- **Identifiers › Device ID**: collected, used for *App Functionality*, linked to the user (when you set an external user id), not used for tracking.
- **Identifiers › User ID**: collected only if you call `setExternalUserId`; *App Functionality*, linked to the user, not used for tracking.
- Anything you put in **custom attributes**: declare it under the matching Apple category yourself, as only your app knows what it contains.

PushPilot does not track users across apps, so no App Tracking Transparency prompt is needed for it. The SDK uses none of Apple's required-reason APIs (it stores its state in a file, not `UserDefaults`).

## Example app

`Example/PushPilotExample.xcodeproj` is a SwiftUI app that initialises PushPilot at launch, forwards the FCM token from its Firebase Messaging delegate, and has buttons for permission, set user id, set topics, logout and forget. It builds without a Firebase config; it then runs without a push token. To try it with real pushes:

1. Open `Example/PushPilotExample.xcodeproj` in Xcode (it resolves this package from `..` and Firebase from GitHub).
2. Set your signing team and a bundle id registered in your Firebase project.
3. Add your `GoogleService-Info.plist` to the `PushPilotExample` target. It is git-ignored; never commit it.
4. Put your SDK key in `pushPilotSdkKey` in `ExampleApp.swift`.
5. Run on a physical device, tap **Allow notifications**, then send a test push from the dashboard's device lookup.

## Tests

```bash
xcodebuild -scheme PushPilot -destination 'platform=iOS Simulator,name=iPhone 17' test
```
