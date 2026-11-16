# Releasing the iOS SDK

Swift Package Manager installs straight from this repository's tags, so a pushed tag is the release. Never move or delete a pushed tag: apps that resolved it would break. Every step marked **Owner** needs the owner's explicit yes for that version.

## Each release

1. Set the version in `PushPilot.podspec`, the `from:` in `README.md` and the heading in `CHANGELOG.md` (replace "unreleased" with the date). Also `sdkVersion` in `Sources/PushPilot/PushPilot.swift`, which the SDK reports to PushPilot.
2. Tests pass:

   ```bash
   xcodebuild -scheme PushPilot-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
   pod lib lint PushPilot.podspec --platforms=ios
   ```

3. Rehearse: add this checkout to a fresh app with *Add Local…* (app target `PushPilot`, extension target `PushPilotNotificationService`), register against a local PushPilot server, receive a push with an image and buttons, tap it and see the click counted.
4. Commit, merge to `main`, tag `<version>` (for example `2.0.0`, no `v`).
5. **Owner:** make `github.com/pushpilotai/pushpilot-ios` public if it is not yet, then push `main` and the tag. This publishes the Swift package.
6. **Owner, if CocoaPods is used:** `pod trunk push PushPilot.podspec` (one-time setup: `pod trunk register <email> 'PushPilot'` and click the emailed link). Needed by Flutter apps that build iOS with CocoaPods.
7. Verify from the public address: a fresh app adds `https://github.com/pushpilotai/pushpilot-ios` with *Add Package Dependencies…*, and the push check passes again.
8. Flutter and React Native point at this repository; release them only after this step.
