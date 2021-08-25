Pod::Spec.new do |s|

  s.name         = "DKRecorder"
  s.version      = "1.0.0"
  s.summary      = "Record UIView in Swift"

  s.homepage     = "https://github.com/DikeyKing/DKRecorder"
  s.license      = "MIT"
  s.author             = { "Dikey" => "dikeyking@gmail.com" }
  s.social_media_url   = "https://gitlab.com/DikeyKing"

  s.platform     = :ios
  s.platform     = :ios, "9.0"
  s.ios.deployment_target = "9.0"

  s.source       = { :git => 'https://github.com/DikeyKing/DKRecorder.git', :tag => s.version }
  s.source_files = 'DKRecorder/*.swift'

end
