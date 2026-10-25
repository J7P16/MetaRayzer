#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint metarayzer_native.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'metarayzer_native'
  s.version          = '0.1.0'
  s.summary          = 'MetaRayzer macOS native layer (frame link + Vision hand detection).'
  s.description      = <<-DESC
MetaRayzer macOS native layer (frame link + Vision hand detection).
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  s.source           = { :path => '.' }
  s.source_files = 'metarayzer_native/Sources/metarayzer_native/**/*'

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'metarayzer_native_privacy' => ['metarayzer_native/Sources/metarayzer_native/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
