# 版本 21：主页精简与实时录音波形

> 历史记录：版本 21 后续真机录音失败，已由版本 22 修复迭代。下文关于不能打开 App 的技术结论过于笼统；版本 22 已恢复真正的 SwiftUI Link 入口。以 [真机修复记录](DEVICE_FIX_22.zh-CN.md) 为当前状态。

按 2026-09-13 的四点反馈修改。App Review 继续暂停。

## 已实现

1. **麦克风未开启：去掉多点一步。** 删除“Set up microphone”按钮，直接居中显示“Open VoiceType / to turn on the mic”；不再点击后才展开说明。Apple 没有为自定义键盘提供受支持的主 App 启动路径，当前审核规则 4.4.1 也限制键盘启动 Settings 以外的 App，因此没有加回绕过系统限制的跳转。
2. **删除独立录音功能。** Home 按钮、录音弹层和对应展示状态全部移除；旧 `voicetype://record` 链接安全回到麦克风首页，不会自动开启录音。键盘录音的失败恢复仍保留。
3. **Home 聚焦麦克风会话。** 移除重复的 Settings、History、键盘教程入口和 Latest transcript 卡片；余额归 Credit，记录归 History，教程归 Settings。保留会话时长、开启／关闭麦克风、必要隐私说明、处理进度和失败重试。
4. **键盘收紧，品牌左对齐。** 根据后续反馈，Logo 恢复左上角；键盘正常高度从 188 pt 降至 160 pt，主按钮下移 6 pt，录音时仅显示居中的动态波形，移除可见 Stop 文案。主按钮仍宽 224 pt、高 48 pt；底部按键高 44 pt。必要权限或错误说明出现时扩展至 196 pt，主按钮位置不动。无障碍说明仍明确点按结束录音。
5. **真实音量波形。** 原来的固定柱形改成麦克风音量历史，随说话强弱平滑变化；静音回落，点 Stop 立即结束。样本超过 0.8 秒未更新、失去 Full Access、关闭会话或隐藏键盘时归零；减少动态效果开启时直接更新。波形表达输入音量，不代表识别置信度。竞品资料与取舍见 [对比记录](COMPETITOR_REVIEW_21.zh-CN.md)。

同时修复 Credit 在 320 pt 宽度下的价格文本折行和深色推荐标签对比问题，支付行为保持原逻辑。

## 视觉检查

这些图来自当前实际 SwiftUI/UIKit 视图在模拟器测试宿主中的渲染，未使用真实账号、付款或麦克风。Home/Credit 使用合成余额和未加载商品状态；键盘使用模拟输入框及会话状态、系统中性底色，真机宿主的模糊背景与交互仍需验证。

1. **Home：通过所检查的布局。** 主操作直接出现，底部四个 Tab 完整，320 pt 下文字正常换行。

![Home](/Users/kyleqi/Downloads/voicetype-keyboard/build/ui-review21/after/voicetype-home-narrow.png)

2. **键盘关闭状态：通过所检查的布局与状态测试。** 显示必要状态，没有无实际跳转作用的按钮。

![麦克风关闭](/Users/kyleqi/Downloads/voicetype-keyboard/build/ui-review21/after/keyboard-off-light-390.png)

3. **Speak／录音波形／Transcribing：通过所检查的布局与回归测试。** 主操作居中，按钮缩小；320、390、768 pt 和浅色／深色均有渲染记录。

![Speak](/Users/kyleqi/Downloads/voicetype-keyboard/build/ui-review21/after/keyboard-ready-light-390.png)

![录音波形](/Users/kyleqi/Downloads/voicetype-keyboard/build/ui-review21/after/keyboard-recording-light-390.png)

录音图使用已知的模拟音量序列驱动真实 UIKit 波形视图，冻结过渡以检查最终布局，不是真机声音或动态流畅度的证明。

![Transcribing](/Users/kyleqi/Downloads/voicetype-keyboard/build/ui-review21/after/keyboard-transcribing-dark-320.png)

4. **Credit 与权限异常：通过所检查的布局。** 小屏推荐标签可换到下一行，Full Access 设置路径完整；商品图中的 Unavailable 是离线测试状态，不是一次真实购买结果。

![权限说明](/Users/kyleqi/Downloads/voicetype-keyboard/build/ui-review21/after/keyboard-access-light-320.png)

截图不能证明 VoiceOver 的完整使用体验、所有系统字体大小、真实购买成功或后台音频连续性。当前仍不把产品标记为完成上线验收。

## 验证记录

- 最新完整 iOS 检查通过 66 项：48 项应用 Swift 测试、17 项键盘测试、1 项原生视图捕获 XCTest。日志：`/private/tmp/voicetype-ui21-wave-v2.log`。新增真实控制器音量读取、旧状态兼容、异常音量、静音、过期样本、权限、停止及退出重置检查。
- 打包及实际 Swift 共享状态检查通过 6 项。随后仅完善静态截图捕获，17 项键盘测试与渲染再次通过：`/private/tmp/voicetype-ui21-wave-render.log`。
- 后续收紧高度、恢复左上角 Logo、移除可见 Stop 文案后，再次通过全部 17 项键盘测试与宽／窄屏、浅／深色渲染。日志：`/private/tmp/voicetype-ui21-compact-left.log`。检查包含操作区、必要说明与底部按键不重叠。
- 版本 1.0.0（21）正式归档 `build/VoiceType-1.0.0-21-compact.xcarchive` 成功，主 App 与两个扩展版本一致、严格签名校验通过、不含测试模块。已于 2026-09-14 03:53 EDT 通过 USB 安装并启动，设备清单核实版本 1.0.0（21）；实际声音与完整键盘录入仍待验证；详见 [LAUNCH_READINESS.md](LAUNCH_READINESS.md)。
- 原生渲染图保存在 `build/ui-review21/before` 与 `build/ui-review21/after`。

## Apple 的限制依据

- [审核规则 4.4.1](https://developer.apple.com/app-store/review/guidelines/#extensions)
- [NSExtensionContext.open](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:))：由扩展类型决定支持情况。
- [Apple DTS 关于扩展启动 App 的说明](https://developer.apple.com/forums/thread/764570)：不受支持的绕过方式存在系统版本兼容风险。
