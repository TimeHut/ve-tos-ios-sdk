Pod::Spec.new do |s|
  s.name = 'VeTOSiOSSDK'
  s.version = '2.1.8-timehut.1'
  s.summary = '由 TimeHut 维护和分发的火山引擎 TOS iOS SDK。'
  s.description = <<-DESC
    由 TimeHut 维护的火山引擎 TOS SDK 静态 XCFramework，支持分片上传和断点续传，
    最小分片大小为 4 MiB。发布版本 tag 和私有 TimeHutSpec 中的 spec 前，
    请先运行 scripts/build-xcframework.sh 生成二进制产物。
  DESC
  s.homepage = 'https://github.com/TimeHut/ve-tos-ios-sdk'
  s.license = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.authors = 'Volcengine', 'TimeHut'

  # 发布版本的 tag 必须包含生成的 Frameworks 目录。
  s.source = {
    :git => 'https://github.com/TimeHut/ve-tos-ios-sdk.git',
    :tag => s.version.to_s
  }

  s.ios.deployment_target = '15.0'
  s.module_name = 'VeTOSiOSSDK'
  s.static_framework = true
  s.vendored_frameworks = 'Frameworks/VeTOSiOSSDK.xcframework'
  s.frameworks = 'Foundation', 'UIKit', 'MobileCoreServices'
  s.preserve_paths = 'Frameworks/BUILD_INFO.txt'
end
