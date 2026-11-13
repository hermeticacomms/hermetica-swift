Pod::Spec.new do |s|
  s.name          = 'HermeticaSDK'
  s.version       = '0.4.0'
  s.summary       = 'Hermetica iOS SDK: events, profiles, push, in-app messages and geofences.'
  s.homepage      = 'https://github.com/hermeticacomms/hermetica-swift'
  s.license       = { :type => 'MIT', :file => 'LICENSE' }
  s.author        = 'Hermetica'
  s.source        = { :git => 'https://github.com/hermeticacomms/hermetica-swift.git', :tag => "v#{s.version}" }
  s.ios.deployment_target = '13.0'
  s.swift_versions = ['5.9']
  s.source_files  = 'Sources/HermeticaSDK/**/*.swift'
  s.frameworks    = 'Foundation', 'UIKit', 'UserNotifications', 'CoreLocation'
end
