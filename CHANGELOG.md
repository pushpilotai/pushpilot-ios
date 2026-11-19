# Changelog

## 2.2.0 (unreleased)

- In-app messages: the SDK fetches the messages an installation may see on each foreground (at most once a minute), caches each page with its assets inlined as `data:` URIs (the light page on phones under 3 GB of memory), and shows the first eligible `app_open` message on foreground in a locked-down transparent full-screen web view with a content security policy.
- `PushPilot.showInApp(_:) -> Bool` shows a cached message for a named in-app call, with no network round trip.
- `PushPilot.markView(_:name:)` and `unmarkView(name:)` name views, held weakly, for coach-mark messages; the view's frame reaches the page as `pushpilot.target`.
- The page's `window.pushpilot` bridge: `close`, `open` (through the link handler; `javascript:`, `data:`, `file:` and `blob:` refused), `haptic`, `track`, `insets`, `island` (Dynamic Island frame), `target`, `platform`, `light`, `posture` and `onPosture` (always `flat` with the window size on iOS until the SDK has a hinge API).
- `shown`, `clicked` and `dismissed` events are queued on disk and sent in batches to `/in-app/events/`.
- The device's shown count per message is kept with the cache; a message's cap uses the larger of it and the server's count, and its dates are checked on the device clock.

## 2.1.1 (unreleased)

- Live activities (iOS 17.2+): PushPilot starts, updates and ends Live Activities by push. New `PushPilotLive` library (and pod) for the Widget Extension: `PushPilotLiveAttributes`, the layout renderer `PushPilotLiveBlock` and the default `PushPilotLiveActivityWidget` for the Lock Screen and every Dynamic Island region.
- The app library reports the push-to-start token, whether Live Activities are on, iOS 18 broadcast support, each activity's update token, `live_started` and `live_dismissed`; ends activities past their end; and downloads layout images into an optional App Group (`initialize(sdkKey:baseUrl:appGroup:)`).
- `handleLiveActivityURL(_:)` records taps on live activities and returns the activity's own link.
- `PushPilot.status(_:)` gives a status screen the installation id, the reported live flags, whether a push-to-start token was accepted, and the last sync result; it holds no token.
- The update token path logs each step to `ai.pushpilot.sdk` without the token: an activity observed, its update token received (byte count) and sent, and a failed send.
- `live_dismissed` is not reported when iOS removes an activity after its end; an ended activity keeps its final state until its removal time when the app runs.

## 2.0.0 (2026-11-17)

First public release: Swift package at `https://github.com/pushpilotai/pushpilot-ios`, tag `2.0.0`.

- Registers the app installation with PushPilot and forwards the APNs device token and its environment (sandbox or production). PushPilot sends to Apple directly; no Firebase.
- Taps on PushPilot pushes (an APNs alert with `mutable-content`) are counted as `clicked`, with the button id, and open the push's link or hand it to `setLinkHandler`.
- `PushPilotNotificationService` library for a Notification Service Extension: adds the image and up to three buttons.
- `setExternalUserId`, `setAttributes`, `setTopics`, `logout` and `forget`.
- The backend address is configurable (default `https://pushpilot.ai`) for self-hosted PushPilot.
- Ships a privacy manifest. iOS 15 and later, no third-party dependencies.
