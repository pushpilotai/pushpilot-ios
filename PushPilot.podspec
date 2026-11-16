# CocoaPods spec for the app library only. The PushPilotNotificationService library for a Notification Service
# Extension ships through Swift Package Manager. Flutter's CocoaPods route depends on this pod.
Pod::Spec.new do |s|
  s.name             = 'PushPilot'
  s.version          = '2.0.0'
  s.summary          = 'Registers an iOS app installation with PushPilot and handles its pushes and taps.'
  s.description      = 'Forwards the APNs device token to PushPilot, records taps on PushPilot pushes and opens their links. No Firebase.'
  s.homepage         = 'https://github.com/pushpilotai/pushpilot-ios'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'PushPilot' => 'https://pushpilot.ai' }
  s.source           = { :git => 'https://github.com/pushpilotai/pushpilot-ios.git', :tag => s.version.to_s }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.source_files     = 'Sources/PushPilot/**/*.swift'
  s.resource_bundles = { 'PushPilot' => ['Sources/PushPilot/PrivacyInfo.xcprivacy'] }
end
