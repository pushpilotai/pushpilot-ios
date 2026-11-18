# CocoaPods spec for live activities: the attributes, layout renderer and default widget, for the app's
# Widget Extension. The PushPilot pod depends on it, so `import PushPilotLive` works with either package manager.
Pod::Spec.new do |s|
  s.name             = 'PushPilotLive'
  s.version          = '2.1.1'
  s.summary          = 'PushPilot live activities: ActivityKit attributes, layout renderer and the default widget.'
  s.description      = 'Draws PushPilot live activities started by push in a Widget Extension, on the Lock Screen and in the Dynamic Island.'
  s.homepage         = 'https://github.com/pushpilotai/pushpilot-ios'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'PushPilot' => 'https://pushpilot.ai' }
  s.source           = { :git => 'https://github.com/pushpilotai/pushpilot-ios.git', :tag => s.version.to_s }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.source_files     = 'Sources/PushPilotLive/**/*.swift'
end
