Pod::Spec.new do |s|

  s.name         = 'DKRecorder'
  s.version      = '0.1.2'
  s.summary      = 'Record UIView in Swift'

  s.homepage     = "https://github.com/DikeyKing/DKRecorder"
  s.license      = "MIT"
  s.author             = { "Dikey" => "dikeyking@gmail.com" }
  s.social_media_url   = "https://gitlab.com/DikeyKing"

  s.platform     = :ios
  s.platform     = :ios, '11.0'
  s.ios.deployment_target = '11.0'
  s.swift_versions = ['5.1', '5.2', '5.3']

  s.source       = { :git => 'https://github.com/DikeyKing/DKRecorder.git', :tag => s.version }
  s.source_files = 'DKRecorder/*.swift'

end
