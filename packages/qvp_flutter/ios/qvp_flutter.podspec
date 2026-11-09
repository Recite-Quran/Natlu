Pod::Spec.new do |s|
  s.name             = 'qvp_flutter'
  s.version          = '0.8.0'
  s.summary          = 'Flutter wrapper for the QVP vector mushaf engine'
  s.description      = <<-DESC
Flutter wrapper for the QVP vector mushaf engine (dart:ffi over libqvp_ffi).
                       DESC
  s.homepage         = 'https://quran.ws'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Quran.ws' => 'team@quran.ws' }
  s.source           = { :path => '.' }
  # The sources and the framework sit in the Swift package directory (qvp_flutter/), so
  # CocoaPods and Swift Package Manager build the same files.
  s.source_files     = 'qvp_flutter/Sources/qvp_flutter/**/*.{c,h}'
  s.public_header_files = 'qvp_flutter/Sources/qvp_flutter/include/**/*.h'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'

  s.vendored_frameworks = 'qvp_flutter/QvpEngine.xcframework'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
