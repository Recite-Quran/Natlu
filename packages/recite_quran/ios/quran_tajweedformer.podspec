Pod::Spec.new do |s|
  s.name             = 'quran_tajweedformer'
  s.version          = '1.1.0'
  s.summary          = 'TajweedFormer V4 FFI plugin for Flutter'
  s.homepage         = 'https://github.com/Iam-Muslim/ReciteQuran'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'QuranLab & Natlu' => 'info@quranlab.ai' }
  s.source           = { :path => '.' }
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'

  # When zf_tajweed.xcframework is present in Frameworks/, vendor it directly into the app
  if File.exist?(File.join(__dir__, 'Frameworks', 'zf_tajweed.xcframework'))
    s.vendored_frameworks = 'Frameworks/zf_tajweed.xcframework'
  end

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
