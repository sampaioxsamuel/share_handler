#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint share_handler.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'share_handler_ios'
  s.version          = '0.0.16'
  s.summary          = 'iOS implementation of the share_handler plugin.'
  s.description      = <<-DESC
  iOS implementation of the share_handler plugin.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = [
    'Classes/**/*.{h,m}',
    'share_handler_ios/Sources/share_handler_ios/**/*.swift'
  ]
  s.resource_bundles = {
    'share_handler_ios_privacy' => [
      'share_handler_ios/Sources/share_handler_ios/PrivacyInfo.xcprivacy'
    ]
  }
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.dependency 'share_handler_ios_models'
  s.platform = :ios, '14.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
