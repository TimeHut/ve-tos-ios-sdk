# ve-tos-ios-sdk

## TimeHut XCFramework 分发

`timehut` 分支包含 TimeHut 的定制修改。最小分片大小为 4 MiB，默认分片大小
仍为 20 MiB。本二进制 SDK 支持 iOS 15 及以上版本。

`VeTOSiOSSDK.podspec` 从 `TimeHut/ve-tos-ios-sdk` 仓库的固定版本 tag 安装
预先构建的静态 XCFramework。发布前先生成产物并进行校验：

```bash
bash scripts/build-xcframework.sh
pod lib lint VeTOSiOSSDK.podspec --private
```

脚本生成 `Frameworks/VeTOSiOSSDK.xcframework`，包含真机 arm64 和模拟器
arm64/x86_64 架构，同时生成构建信息文件 `Frameworks/BUILD_INFO.txt`。
日志和中间归档保存在已被 Git 忽略的 `build/xcframework/` 目录中。
版本号和最低 iOS 版本从 podspec 中读取。重新构建前需移走或删除已有的
XCFramework，脚本不会自动覆盖现有产物。

本地接入时，将旧 SDK 依赖替换为以下配置，并修改为实际源码路径：

```ruby
pod 'VeTOSiOSSDK', :path => '/path/to/ve-tos-ios-sdk'
```

发布首个版本 `2.1.8-timehut.1` 时，将 podspec、构建脚本、LICENSE 和完整的
`Frameworks/` 目录提交到 `timehut` 分支，再基于该提交创建版本 tag。
tag 必须包含二进制产物，CocoaPods 安装时不会执行构建脚本。

```bash
git push origin timehut
git tag 2.1.8-timehut.1
git push origin 2.1.8-timehut.1
pod spec lint VeTOSiOSSDK.podspec --private
pod repo push timehut-timehutspec VeTOSiOSSDK.podspec --private
```

执行 `pod repo push` 时，使用本机已有的 TimeHutSpec 仓库名称。
在应用的 Podfile 中显式指定私有源，并将 `Podfile.lock` 提交到版本管理：

```ruby
source 'https://github.com/TimeHut/TimeHutSpec.git'
source 'https://cdn.cocoapods.org/'

pod 'VeTOSiOSSDK', '2.1.8-timehut.1',
    :source => 'https://github.com/TimeHut/TimeHutSpec.git'
```

首次安装执行 `pod install --repo-update`。后续发布时，更新 podspec 版本号，
重新构建并发布新的 tag 和 spec，再更新应用中锁定的版本。已发布的 tag 和 spec
保持不变。同一个应用 target 不应同时包含旧 SDK 或其源码。
由于 XCFramework 为静态库，手动通过 Xcode 接入时选择 **Do Not Embed（不嵌入）**。

## 安全与隐私

本项目重视安全问题。漏洞报告方式及支持的版本请参阅 [安全说明](SECURITY.md)。
