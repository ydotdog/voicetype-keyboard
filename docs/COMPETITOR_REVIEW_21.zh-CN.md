# VoiceType 与 Typeless、Wispr Flow：本轮取舍

**优先做好说话时的反馈、文字插入和失败恢复，保持 VoiceType 简单。** 用户提到的“whisperflow”在此按 Wispr Flow 理解。

这份比较依据两家的当前官方帮助文档，以及 VoiceType 的源码；没有安装竞品做真机对照。文档描述不能证明竞品内部采用了哪种 API，也不能据此比较实际识别准确率、延迟或耗电。

| 体验 | 官方资料能确认什么 | VoiceType 的取舍 |
| --- | --- | --- |
| 录音反馈 | Wispr 的 iOS 音量指示器只在键盘活跃时更新，真正安静时归零。[音频说明](https://docs.wisprflow.ai/articles/8884408990-connect-and-set-up-external-audio-devices) | 原来固定高度的波形不能说明是否收到声音。本轮改为真实声音强弱驱动，停顿回落，停止录音后结束波形。转写使用独立的处理状态。 |
| 开始和结束 | Typeless 手机端点击 Speak 开始，再次点击结束，结果进入原输入位置。[Dictate](https://www.typeless.com/help/quickstart/dictate) | 保持居中的 Speak／Stop 主操作。正常状态去掉解释小字，权限及故障提示仍保留。 |
| 麦克风激活 | Typeless 用空心／实心麦克风区分是否需要切换 App，并声明空闲时麦克风关闭。[iOS 说明](https://www.typeless.com/help/release-notes/ios/when-does-app-switching-happen) | VoiceType 当前在用户主动开启后维持后台采集窗口，不能宣称具有相同的空闲麦克风行为。竞品的可见跳转不构成受支持 API 的证明。 |
| 失败恢复 | 两家均提供历史复制和保存音频的重试；Wispr 的 iOS 历史可以点击失败条目重试。[Wispr](https://docs.wisprflow.ai/articles/4984532368-fix-taking-longer-than-usual-and-transcription-errors)、[Typeless](https://www.typeless.com/help/quickstart/history-and-dictionary) | 已有失败录音保留、Retry／Discard、历史复制及重复请求防重复扣费。后续应缩短用户发现和恢复失败的路径。 |
| 少量编辑 | Typeless 支持滑动切换文字键盘；Wispr 提供撤销／重做、词典、样式及字母布局。[Typeless](https://www.typeless.com/help/release-notes/ios/swipe-to-type)、[Wispr](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android) | 先做好地球键、删除和回车。完整多语言键盘和写作助手会显著增加维护范围，不作为本轮目标。 |

## Session length 保持用户确认的逻辑

Wispr 的专门说明把设置描述为**后台空闲会话的超时**，不会打断正在进行的口述；其文档还另有单段口述限制。[会话说明](https://docs.wisprflow.ai/articles/3634682593-why-the-orange-dot-or-mic-indicator-stays-on-after-dictating-ios)

VoiceType 采用用户已确认的**固定后台可用窗口**：从开启麦克风起计算 5 分钟、12 小时或 Forever，多次 Speak／Stop 不重新计时。有限窗口到期时结束采集，并处理已经录到的内容。这与 Wispr 的空闲超时不是同一语义；本轮调整波形和布局不会改变这一规则。

## 本轮声音反馈的实施边界

主 App 已接入真实录音音量采样，键盘口述期间目标每秒 4 次发布共享音量值，实际频率受系统调度影响；非录音状态为零，旧版本缺少该字段时也按零处理。键盘平滑显示最近的实测音量，静音、停止、隐藏键盘、失去权限或样本过期时归零。本轮完整 66 项 iOS 检查已通过，包含音量读取和重置行为；真机手感与声音测试仍待进行。

可见波形表达的是**输入声音强弱**，不是识别置信度，也不是正在逐字转写的证明。应当用真机分别检查安静、轻声、正常说话、停顿及耳机输入；不能把模拟音量测试当成麦克风实测。

## 尚未实现的后续建议

1. **恢复上一条文本**：在键盘中提供用户主动点击的恢复操作，避免切换输入框后误自动插入。
2. **更直接的失败状态**：区分网络、权限、没有声音与服务错误，并说明录音是否已保存。
3. **历史管理**：单条删除和保留期限。Typeless 已提供本地历史的多种保留期限，可借鉴其控制方式。[历史说明](https://www.typeless.com/help/quickstart/history-and-dictionary)
4. **自定义词典**：优先解决姓名、公司名和中英混说中的重复错词，再考虑写作风格等功能。

这些是后续候选功能，不代表已交付。本轮继续移除应用内单独录音和 Home 上重复的 Tab 入口，不因竞品有笔记、统计或多个设置入口而重新加回。
