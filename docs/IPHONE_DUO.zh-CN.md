# iPhone Duo 适配

VoiceType 的主 App 和键盘扩展只按窗口宽度排版，不判断机型和方向。同一套界面因此可以用在 iPhone Duo 的外屏、展开后的内屏，以及内屏上的半屏窗口：展开时页面变宽，不换成另一套界面。

本文记录改了什么、怎么验证的，以及在当前开发机上验证不了的部分。

## 生效条件：用 iOS 27 以上的 SDK 构建

当前的构建环境是 Xcode 26.3（iOS 26.2 SDK）。Apple 的[准备页面](https://developer.apple.com/iphone-duo/prepare/)按构建所用的 SDK 说明了 App 在 iPhone Duo 上的表现：

| 构建用的 SDK | 在 iPhone Duo 上 |
| --- | --- |
| iOS 26 及更早（当前环境） | 能运行。展开时 App 按手机大小显示在内屏中央，四周留空；合上时显示在状态栏和摄像头的左侧 |
| iOS 27 | 展开时 App 铺满内屏的大部分，仍避开右侧的状态栏 |
| iOS 27.1 及以上 | App 用满整个屏幕，工具栏和标签栏竖排在状态栏下方 |

所以用当前环境打出的包，在 Duo 上拿到的是手机大小的窗口，本文的宽屏布局不会出现。改动已经在代码里，换用 iOS 27 以上的 SDK 重新构建后才在 Duo 上起作用。这套布局只看宽度，对 iPad 和多数横屏 iPhone 现在就起作用。

按 Apple 的 [Xcode 支持页面](https://developer.apple.com/support/xcode/)，Xcode 27（含 iOS 27 SDK）和 Xcode 27.1（含 iOS 27.1 SDK）都要求 macOS 26.6 以上。开发机是 macOS 26.1，两个版本都装不了，要先升级系统。

以上依据 Apple 的页面，没有在 Duo 真机或模拟器上确认过。

## 测试用的窗口尺寸

Apple 没有公布 iPhone Duo 的点（pt）尺寸，设计规范和开发文档里也没有。下表是推算值，只用在测试里。App 代码里没有写入任何一个设备尺寸。

推算方法：取 App Store Connect 截图规格里 iPhone Duo 的像素尺寸（外屏 1398 × 2034，内屏 2007 × 2853），除以 3。

内屏不能用官网技术规格里的面板分辨率（1878 × 2670，430 ppi）来算。截图比面板大约 6.9%，接近外屏与内屏的像素密度之比（460 : 430，约 7.0%），由此推断内屏按 669 × 951 pt 渲染，再缩小显示到面板上。本文较早的版本按面板分辨率算出 626 × 890，偏小约 7%，已更正。

| 姿态 | 窗口（pt，推算值） | 首页、额度页 |
| --- | --- | --- |
| 合上，外屏 | 466 × 678 | 单栏 |
| 展开，竖向 | 669 × 951 | 单栏 |
| 展开，横向（铰链竖直，约在 x = 475） | 951 × 669 | 两栏 |
| 展开横向时的半屏窗口 | 475 × 669 | 单栏 |
| 展开竖向时的半屏窗口 | 334 × 951 | 单栏 |

- 展开竖向时保持单栏是有意的：内容区宽 621 pt，分成两栏每栏只有 294.5 pt，低于规则要求的 304 pt。
- 表里是整块屏幕的尺寸。按 Apple 的说明，Duo 的状态栏在屏幕右侧，用 iOS 27.1 SDK 构建后工具栏和标签栏会竖排在它下方，内容区因此比表里窄。两栏规则按实际拿到的宽度判断，不依赖表里的数字。

## 改动

布局相关的类型都在 `VoiceType/Views/AdaptiveLayout.swift`。

- **页面容器 `TabPage`**：四个标签页共用一个滚动容器，内容居中。历史、设置最宽 720 pt，首页、额度页最宽 960 pt，窗口再宽也不会把文字拉成一整行。
- **两栏 `PageColumns`**：内容区宽度达到 640 pt（即窗口宽 688 pt）时，首页和额度页把同一组视图排成等宽两栏，栏间距 32 pt；不足时按原顺序上下排列。辅助功能字号下始终单栏。
  - 首页：左栏是麦克风开关和状态，右栏是时长设置和说明。
  - 额度页：左栏是余额和说明，右栏是额度包。
  - 这条规则只看宽度，所以 iPad 和多数横屏 iPhone 也会显示两栏（扣掉左右安全区后内容区仍有 640 pt 的机型；iPhone SE 这样 667 pt 宽的屏幕仍是单栏）。
- **登录页**：标志、标题和登录按钮之间的留白可以压缩。窗口矮（如合上的外屏）时先收紧留白，内容仍放不下才滚动；内容放得下时页面不回弹。内容最宽 560 pt。
- **键盘设置页**：改用系统导航栏，返回按钮是 `cancellationAction` 位置上的工具栏项，带图标和标题，由系统决定它放在哪条栏上。
- **弹窗的工具栏按钮**（Dictation、Edit & teach、Transcription 三个弹窗里的 Done、Cancel、Save）：iOS 26 及以上同时带图标和标题，系统才能把它们移到竖向的栏上；更早的系统保持文字按钮。
- **提示条**：原来靠固定的 92 pt 下边距避开底部的标签栏。现在放进各标签页内容的安全区，标签栏在底部或在侧边时，提示条都落在内容区内。
- **键盘扩展**：麦克风按钮宽度为键盘宽度的 45%，限制在 224–400 pt；回车键为 28%，限制在 160–320 pt。键盘宽度不到约 498 pt 时（所有竖屏 iPhone 和合上的 Duo）两个按钮与之前相同；更宽的键盘（展开的 Duo、iPad、横屏 iPhone）上按钮随之变宽。

没有新增 Info.plist 键，也没有改支持的方向（iPhone 上是竖向和左右横向，iPad 上是四个方向）。

## 对照 Apple 列出的三类写法

Apple 的准备页面列了三类需要改掉的写法。在主 App、键盘扩展、实时活动扩展、共享代码和测试的 Swift 源码里搜索的结果：

| Apple 列出的写法 | 本项目 |
| --- | --- |
| 用主屏幕的尺寸算布局（`UIScreen.main`） | 没有用到 `UIScreen` |
| 按设备方向决定布局（`UIDevice.current.orientation`、`interfaceOrientation` 等） | 没有用到 |
| 用机型或尺寸类别判断设备（`userInterfaceIdiom`、`horizontalSizeClass`） | 没有用到；布局只看拿到的宽度 |

## 验证

环境：Xcode 26.3，iOS 26.2 SDK，Swift 6，iPhone 17 模拟器。

| 项目 | 结果 |
| --- | --- |
| 改动前的基线：6 个快照测试、30 个键盘测试 | 全部通过，留下 59 张 App 快照和 36 张键盘快照，用来和改动后逐像素比较 |
| 改动后编译主 App、键盘扩展、实时活动扩展和两个测试包 | 通过（在更正测试尺寸之前） |
| 两栏规则：`AdaptiveLayoutTests` 里的 8 项检查 | 在 macOS 上执行通过（用的是更正前的宽度，见下） |
| 更正尺寸后的三个测试文件（只改了尺寸数字和注释） | 通过语法检查（`swiftc -frontend -parse`），还没有重新编译 |
| 改动后在 iOS 模拟器里运行布局测试（4 个）、快照测试（9 个）、键盘测试（30 个） | 还没有运行 |

所以到目前为止，界面改动经过了编译，两栏规则经过了执行。四个标签页、登录页、键盘设置页、提示条和键盘在各个尺寸下的实际画面还没有经过渲染验证，“手机宽度下画面与之前一致”也还没有图片对比。这些改动也会进入普通 iPhone 上的界面，所以发布前需要先跑完这一步。

模拟器测试没有运行，原因是开发机内存不够。这台 Mac 有 16 GB 内存。开着其他 App、空闲内存约 1 GB 时，单独启动 iPhone 17 模拟器，35 秒内可用内存（`sysctl kern.memorystatus_level` 的读数）就从 65% 降到 44%，而且还在下降，启动被中止。作为对照，改动前的基线测试是在刚重启后跑的：开始时 81%，最低 56%。

两栏规则的 macOS 检查是一次性的替代做法：把 `VoiceType/Views/AdaptiveLayout.swift` 原样编译到 macOS，用 `NSHostingController` 代替 `UIHostingController`，期望高度与 `AdaptiveLayoutTests` 相同。执行时用的是更正前的宽度：窗口宽 313、445、466、626、687 pt 时两组内容上下排列；688、890 pt 时并排；890 pt 加辅助功能字号时上下排列。规则只有一个条件，即内容区宽度是否达到 640 pt（窗口宽 688 pt）。更正后的宽度里 334、475、669 在这条线以下，951 在以上，结论不变，但这几个宽度本身没有执行过。它也不是 iOS 上的运行结果。

在模拟器里运行。16 GB 的 Mac 上先退出其他占内存的 App；按上面的实测估算，需要约 4 GB 空闲内存：

```bash
xcodebuild test -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:VoiceTypeTests/AdaptiveLayoutTests -only-testing:VoiceTypeTests/HomeSnapshotTests -only-testing:VoiceTypeKeyboardTests
```

- `AdaptiveLayoutTests` 检查上表每个宽度下是单栏还是两栏、两栏从内容区 640 pt 开始、辅助功能字号下保持单栏。
- `HomeSnapshotTests` 把四个标签页、登录页、键盘设置页和提示条按上表的尺寸渲染成图片（`voicetype-*.png`），写在模拟器里 App 的临时目录下。
- 键盘测试把键盘按 320、390、466、669、768、951 pt 六个宽度渲染成图片（`keyboard-*.png`）。

## 当前开发机上验证不了的部分

- **没有 iPhone Duo 模拟器。** Xcode 27.1（含 iOS 27.1 SDK）要求 macOS 26.6 以上，开发机是 macOS 26.1 和 Xcode 26.3。快照测试是在 iPhone 17（iOS 26.2）模拟器里把窗口设成上表的推算尺寸来渲染的，不包含真实的安全区、铰链和侧边栏。
- **用 iOS 27 以上 SDK 构建后的表现没有验证。** 铺满内屏、状态栏在右侧、工具栏和标签栏竖排，这些都要换 SDK 后才出现。
- **半开姿态下的铰链避让没有做。** 它需要 iOS 27.1 的 `reservedRegions`，当前 SDK 编译不了。按 Apple 的说明，这个保留区域只在半开时生效，完全展开时不生效。
- **键盘扩展只做了离屏渲染测试**（宽度 320 到 951 pt）。真机上的键盘高度、系统地球键和候选栏没有测。按 Xcode 27.1 的发布说明，Duo 模拟器里大多数 App 扩展不能运行和调试，所以键盘要用真机测。

## 换到 Xcode 27.1 之后

1. 把 macOS 升级到 26.6 以上，安装 Xcode 27.1，用 iOS 27.1 SDK 重新构建。
2. 运行 Apple 提供的 app resizability 检查：在 Xcode 的编码助手里要求 “get my app ready for iPhone Duo”，或用 `xcrun agent skills export` 把它导出给其他编码工具。Xcode 26.3 里没有这个命令。
3. 在 iPhone Duo 模拟器上重跑现有的快照测试和布局测试，再用真机过一遍键盘。Apple 还列了另外两种测试办法：可调整大小的 iOS 模拟器，以及 macOS 27 上的 iPhone 镜像。
4. 看一遍各页的顶部和右侧：状态栏在右侧、工具栏和标签栏竖排之后，内容有没有被挡住。
5. 评估 `ArrangementView` 和 `reservedRegions`：半开时让两栏避开铰链。
6. 评估 `toolbarVerticalBehavior(_:)`：确认合上横握时工具栏移到侧边后的表现。
7. 两栏的起始宽度（内容区 640 pt）是按推算尺寸定的。拿到官方尺寸后核对一次。
8. 确认 Duo 展开后倒过来拿时界面是否需要跟着转。现在 iPhone 上没有声明倒置竖向（`UIInterfaceOrientationPortraitUpsideDown`）。
