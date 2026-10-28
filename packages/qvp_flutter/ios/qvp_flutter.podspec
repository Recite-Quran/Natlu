Pod::Spec.new do |s|
  s.name             = 'qvp_flutter'
  s.version          = '0.7.0'
  s.summary          = 'Flutter wrapper for the QVP vector mushaf engine'
  s.description      = <<-DESC
Flutter wrapper for the QVP vector mushaf engine (dart:ffi over libqvp_ffi).
                       DESC
  s.homepage         = 'https://quran.ws'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Quran.ws' => 'team@quran.ws' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'

  s.vendored_frameworks = 'QvpEngine.xcframework'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
