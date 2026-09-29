# Build 26：系统组件与图标

TestFlight 内部测试版本 1.0.0 (26)，已于 2026-09-21 上传并确认可供 Internal Testers 测试。本次没有更改线上计费配置、API 密钥或词汇学习逻辑。

## 变更

- 四个主要页面使用原生 SwiftUI TabView，各页独立 NavigationStack；移除自绘底部标签栏，由系统处理安全区域与 Liquid Glass 外观。
- Settings 使用标准 Form、Section、Button；语言/词汇和纠错继续使用原生表单与导航。
- 主操作采用 iOS 26 的 glassProminent，辅助操作采用 glass；iOS 17–18 回退到原生 borderedProminent / bordered 样式。
- 使用系统动态背景与文本颜色，保留品牌字标。主按钮采用固定的深绿 tint 以保持深色模式下文字对比度。
- Home 始终使用同一个主按钮，位于状态信息上方。开、关文本共同决定按钮尺寸；开启中、待录音、录音中和转写中只更新按钮下面的状态内容。错误、余额调整提示也不插入到按钮上方。
- Session length 使用系统分段 Picker；辅助功能大字体改用菜单 Picker。
- 解除仅竖屏和全屏限制，内容根据容器宽度排版，并限制正文最大阅读宽度。

## 图标

实际 App 图标改为 `VoiceType/Resources/VoiceTypeIcon.icon`。独立透明前景叠在 `#FFFFFF` 纯白背景上，由 Icon Composer/Xcode 编译系统外观。深色与单色模式使用高对比前景，避免黑色 V 在深色/透明背景中消失。

内置 imagegen 用于生成透明前景，Icon Composer 负责纯白底色、分层和外观。最终使用的生成提示：

> Use case: background-extraction. Production icon FOREGROUND layer for Apple Icon Composer. Remove ALL cream background from the reference, make it truly fully transparent alpha, including the exterior, between black V and gold bar, and all negative space. Preserve the original black italic V and gold vertical rounded bar exactly at their original positions, shapes, size and flat solid colors. No gradients, noise, shadows, outlines or embellishments. Do not paint white or a checkerboard: output real transparent PNG. Square 1024x1024 canvas. Nothing else.

原先生成的白底位图没有作为正式资源使用；正式背景在可编辑图标工程中明确指定为纯白。XcodeGen 中将 .icon 声明为单个资源文件，避免把内部 JSON/PNG 当成普通文件拷贝。

## 验证边界

本机 Xcode 26.3 / iOS 26.2。窄屏、宽屏、横屏、大字体、深色外观的渲染覆盖是自适应布局检查，不等于 iPhone Duo 专项验证。Apple 要求使用较新 SDK 检查 Duo 的内外屏、折叠区域、垂直导航条与场景切换；本机没有 Xcode 27.1 beta / Duo 模拟器，以上列为待测。

[Apple Liquid Glass 指南](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
[Apple iPhone Duo 适配指南](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)

测试结果记录在本文末尾；截图与结果包位于 `build/ui26/`。模拟器不能证明实体键盘录音、蓝牙、Live Activity 手势或实际文本插入行为。

## 最终验证（2026-09-21）

- iOS 26.2：116 个独立测试全部通过（含参数化执行共 118 次），结果包 `build/ui26/regression.xcresult`。
- 51 张界面截图覆盖主要页面、窄屏/宽屏/横屏/深色/大字体。Home 五种麦克风状态均有截图；24 张开/关/录音/转写截图的按钮色带上下边界对比误差不超过 1 个渲染像素，记录在 `button-position-check.json`。
- iOS 18.6：7 项界面与词表兼容测试通过，系统按钮与标签栏回退样式已渲染。
- 6 项 Python 发布打包检查通过，包含 iPad 多任务的四方向声明。
- 签名 Release archive：`build/VoiceType-1.0.0-26-final.xcarchive`；App、键盘、Live Activity 均为 1.0.0 (26)，严格签名检查通过，无测试包。
- 词表的运行逻辑保持原样。将系统人名识别依赖抽为可注入查询，测试分别覆盖识别人名与系统资源不可用时的保守回退；修复原测试依赖已下载中文资源的问题。资源不足时用户可手动填写完整姓名，不作识别率保证。
- 图标在 Icon Composer 检查了普通、深色、单色预览；编译后的 App 主图标名称为 VoiceTypeIcon，旧系统使用的扁平图标也已检查为白底。
- TestFlight：Apple 处理状态 VALID，内部测试状态 IN_BETA_TESTING，已确认属于 Internal Testers；中英文测试说明已保存并回读。Build ID：`383766a8-e914-44ae-96c3-13fce7a48e5d`。验证记录：`build/release26/testflight-verified.json`。
- 未修改线上服务、未直接安装到实体设备、未提交 App Review。正式商店版本仍为 REJECTED / MANUAL。Duo 折叠/展开、真实键盘录音及系统 Clear 外观的实体设备检查待测。

上传校验修正：Apple 要求支持多任务的 iPad 声明全部四个方向。已补齐 iPad 专用方向列表，iPhone 保持竖屏和左右横屏；增加打包回归检查并重建、严格验证最终 archive。此前的本地 archive 不应用于分发。
