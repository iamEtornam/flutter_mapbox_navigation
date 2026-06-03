#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint mapbox_navigation_plus.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'mapbox_navigation_plus'
  s.version          = '0.0.1'
  s.summary          = 'Add Turn By Turn Navigation to Your Flutter Application Using MapBox. Never leave your app when you need to navigate your users to a location.'
  s.description      = <<-DESC
Add Turn By Turn Navigation to Your Flutter Application Using MapBox. Never leave your app when you need to navigate your users to a location.
                       DESC
  s.homepage         = 'https://eopeter.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Emmanuel Peter Oche' => 'eopeter@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'mapbox_navigation_plus/Sources/mapbox_navigation_plus/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'

  # IMPORTANT: Mapbox Navigation SDK v3 for iOS is distributed only via Swift Package
  # Manager. This plugin therefore requires Flutter's Swift Package Manager support:
  #   flutter config --enable-swift-package-manager
  # The actual Mapbox dependencies are declared in Package.swift; this podspec exists
  # only so the plugin is recognized by Flutter's tooling.

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
