Pod::Spec.new do |s|
  s.name             = 'glitch_vpn_core'
  s.version          = '0.2.4'
  s.summary          = 'Flutter FFI plugin for the libglitchcore VPN core (stub on iOS).'
  s.description      = <<-DESC
Flutter FFI plugin for the libglitchcore VPN core. There is no engine
implementation on iOS; this pod provides the platform stub only.
                       DESC
  s.homepage         = 'https://github.com/glitch-vpn/glitch_vpn_core_plugin'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Maksim Bezlegkii' => 'max.bezlegkiy@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
