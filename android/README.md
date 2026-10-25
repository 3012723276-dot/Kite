# Kite for Android

Android 重写版，第一阶段目标：最小可跑闭环，不是 iOS 版的完整移植。

iOS / macOS 版是 Swift / SwiftUI，Android 没法直接编译 Swift，
所以这里是全新的 Kotlin + Jetpack Compose 工程，网易云 API 逻辑
按 iOS 版的 `NeteaseCrypto` / `NeteaseAPI` 重新实现。

## 第一阶段范围（已完成骨架 + 最小闭环代码）

- 网易云 weapi 加密：AES-128-CBC + RSA encSecKey（与 iOS 版同一算法）
- 登录：手机号 + 验证码（接口已接通，Cookie 持久化待下一步）
- 首页：新专辑列表（对应 iOS 闪退前加载的那一步）
- 搜索：单曲搜索，点歌后用 ExoPlayer 播放
- 底部播放条：播放 / 暂停

## 下一步（未做）

- 登录 Cookie 持久化到 SharedPreferences / DataStore，重启后不用重登
- 歌单详情、专辑详情点进去的歌曲列表
- 播放页（封面、歌词、进度条、上一首 / 下一首）
- ViewModel + StateFlow 重构（当前界面直接用 remember + 协程，先跑通再重构）
- 在 Android Studio 里真机编译验证，修编译报错

## 不在第一阶段

- 桌面歌词、CarPlay、Stem 分离、AutoMix、离线下载、iCloud 同步
- 这些是后续按模块逐步加的，不是第一版就全有。

## 技术栈

- 语言：Kotlin
- UI：Jetpack Compose + Material 3 + Navigation
- 网络：OkHttp + kotlinx-serialization
- 播放：Media3 ExoPlayer
- 图片：Coil
- 最低版本：Android 8.0（API 26），目标 Android 15（API 35）

## 目录

- `app/src/main/java/moe/kite/android/api/`：加密 + API 客户端
- `app/src/main/java/moe/kite/android/player/`：播放器封装
- `app/src/main/java/moe/kite/android/ui/`：Compose 界面
- `app/src/main/java/moe/kite/android/model/`：数据模型

## 密钥说明

`NeteaseCrypto.kt` 里的 weapi 密钥与 iOS 版 `NeteaseCrypto.swift`
保持一致才能调通 weapi，密钥取值请从 iOS 源码同名文件里复制，
不要把密钥贴到公开聊天或公开仓库之外的任何地方。

## iOS 功能对齐路线（目标：和 iOS 一模一样的功能，安卓适配）

| iOS 功能 | Android 对应做法 |
|---|---|
| 首页 / 新专辑 / 推荐歌单 | Compose 列表 + 底部导航，替代 macOS 侧边栏 |
| 搜索 / 歌单 / 专辑详情 | 同 weapi 接口，Compose 详情页 |
| 播放 / 歌词 / 播放队列 | Media3 + MediaSession + 通知栏播放控制，替代 Dynamic Island / 锁屏控制 |
| 登录（短信 / 扫码） | 短信登录先行，扫码登录后续用二维码 + 轮询 |
| 我的收藏 / 喜欢 / 云盘 | 同 weapi 接口，本地 Room 缓存后续加 |
| 下载 / 离线 | Android 存储 + Media3 离线，后续加 |
| CarPlay | Android Auto（后续，MediaSession 兼容） |
| macOS 专属（Dock、菜单栏、快捷键、Sparkle 更新） | 不做安卓版，改用 Android 通知、分享、系统设置 |

安卓适配原则：不照搬 iOS 布局，用 Material 3、底部导航、
系统返回手势、深色模式、不同屏幕尺寸（手机 / 平板）适配。
