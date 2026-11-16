# Changelog

## 2.0.0 (unreleased)

First public release: Swift package at `https://github.com/pushpilotai/pushpilot-ios`, tag `2.0.0`.

- Registers the app installation with PushPilot and forwards the APNs device token and its environment (sandbox or production). PushPilot sends to Apple directly; no Firebase.
- Taps on PushPilot pushes (an APNs alert with `mutable-content`) are counted as `clicked`, with the button id, and open the push's link or hand it to `setLinkHandler`.
- `PushPilotNotificationService` library for a Notification Service Extension: adds the image and up to three buttons.
- `setExternalUserId`, `setAttributes`, `setTopics`, `logout` and `forget`.
- The backend address is configurable (default `https://pushpilot.ai`) for self-hosted PushPilot.
- Ships a privacy manifest. iOS 15 and later, no third-party dependencies.
