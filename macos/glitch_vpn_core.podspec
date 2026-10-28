Pod::Spec.new do |s|
  s.name             = 'glitch_vpn_core'
  s.version          = '0.2.5'
  s.summary          = 'Flutter FFI plugin for the libglitchcore VPN core (stub on macOS).'
  s.description      = <<-DESC
Flutter FFI plugin for the libglitchcore VPN core. There is no engine
implementation on macOS; this pod provides the platform stub only.
                       DESC
  s.homepage         = 'https://github.com/glitch-vpn/glitch_vpn_core_plugin'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Maksim Bezlegkii' => 'max.bezlegkiy@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
