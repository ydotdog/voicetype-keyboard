# 版本 22：真机录音与键盘跳转修复

2026-09-14。**审核暂停，完整真机使用结果仍待确认。**

## 用户报告与实际证据

版本 21 在主 App 开启麦克风后，返回键盘点击 Speak 先显示 Starting，随后退回 Open VoiceType。听音乐时开启麦克风还会打断音乐。

手机旧版进程日志显示：主 App 在设备日志时间 16:03:55 激活音频会话，16:03:57 离开前台，键盘约 16:03:58.557 发生点击反馈，主 App 在 16:03:58.756 关闭音频会话。随后读取 App Group，录音状态和命令均不存在。该现象证明会话被关闭；仅凭这些记录不能断言某个原生调用失败就是唯一原因。

## 已修改

1. **恢复直接打开 App 的按钮。** 麦克风关闭且 Full Access 已开启时，显示真正的 SwiftUI `Link`，用户点按直接请求打开 `voicetype://keyboard`。Link 单独嵌入，避免原 UIKit 按钮的 `hitTest` 吞掉点击。主 App 打开麦克风控制页；外部 URL 本身不自动开启麦克风。
2. **允许与音乐混播。** `AVAudioSession` 改用 `.playAndRecord`、`.default` 和 `.mixWithOthers`；之前缺少混播选项，是音乐被打断的明确配置原因。保留原有蓝牙和扬声器选项，真实音频路由仍需设备检验。
3. **保持 5 分钟会话连续采集。** 原实现每次 Speak 都暂停并重新启动录音器，尽管 5 分钟会话的原生截止时间并未改变。现在截止时间相同则保留正在运行的录音器；12 小时／Forever 下需要收紧到单段 10 分钟的截止时间仍正常调整。避免无必要的后台音频重启，不把这项代码修复等同于已证明真机故障完全解决。
4. **补充诊断。** 记录收到的命令类型、当前模式、原生录音器保持／重启／失败结果，不写入声音、转写文字、账户凭据。

## 修正此前关于跳转的结论

此前把审核限制直接当作技术上不可实现，进而删除了用户要求的按钮，这一判断过于笼统。已有实际发布的键盘使用原生 SwiftUI Link，且维护者确认 iOS 26 在 Full Access 条件下可打开主 App：

- [KeyboardKit 作者说明](https://keyboardkit.com/blog/2024/09/11/ios18-breaks-selector-based-url-opening)
- [已发布源码](https://github.com/KeyboardKit/KeyboardKit/blob/8.8.6/Sources/KeyboardKit/Gestures/View%2BKeyboardButtonGestures.swift#L116)
- [iOS 26 Full Access 条件](https://github.com/KeyboardKit/KeyboardKit/issues/966#issuecomment-3332569953)

这些证据支持实现并真机检验该路径；不等于 Apple 已批准当前应用的审核。

## 验证状态

- 68 项 iOS 测试通过：50 项应用测试、17 项键盘测试、1 项原生视图捕获。新增用拒绝暂停后重启的录音器复现连续性约束，及 12 小时／Forever 的原生单段上限检查；键盘验证 Link 点击区域未被 UIKit 控件遮挡。
- 正式归档 `build/VoiceType-1.0.0-22.xcarchive` 成功，主 App、键盘和 Live Activity 扩展均为版本 22，严格签名校验通过。
- 已安装并启动到 iPhone10，设备应用清单读回确认为 1.0.0（22）。
- **待真机确认：** 键盘直接跳转；开启麦克风后可录音；停止后正确转写和插入；音乐持续播放。已开启仅过滤 VoiceType／VoiceTypeKeyboard 的实时设备诊断。

证据：`/private/tmp/voicetype-fix22.log`、`/private/tmp/voicetype-fix22-archive.log`、`/private/tmp/voicetype-installed22-verified.json`、`/private/tmp/voicetype-launched22.json`、`/private/tmp/voicetype-history22-filtered.log`。
