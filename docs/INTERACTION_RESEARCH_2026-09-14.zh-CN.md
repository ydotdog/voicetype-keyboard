# VoiceType、Typeless 与 Wispr Flow：iOS 交互范式比较

调研日期：2026-09-14。本文只做产品研究，没有修改应用代码、安装新版本或提交审核。用户所说的 Whisper Flow 在此按 Wispr Flow 理解。

**判断：VoiceType 的主要差距在于流程衔接、状态区分和失败后的可恢复性。先确定完整操作规则，才能让图标、波形、触感和后台行为始终一致。**

## 证据范围

竞品依据本轮查阅的官方帮助中心、开发者发布记录及官方演示页；没有安装两家竞品进行同机测试。VoiceType 依据当前第 23 版源码，以及用户已报告的使用问题。源码能够证明设计路径，不能证明实机手感、速度、音乐共存或耗电。此前版本的问题与第 23 版已经改动的部分分开列出。

本轮搜索也出现了用户讨论中的 App 往返、键盘纠错等抱怨；它们只作为线索，没有用来估计发生率。以下判断主要依赖一手资料和当前源码。

## 逐项比较

| 环节 | Typeless 的官方描述 | Wispr Flow 的官方描述 | VoiceType 23 的现状与差距 |
| --- | --- | --- | --- |
| 从其他 App 开始 | 键盘触发听写；空心麦克风表示需要短暂切 App，实心表示可以直接说话。[激活说明](https://www.typeless.com/help/release-notes/ios/when-does-app-switching-happen) | 有激活后的返回引导，支持范围内自动返回，其他情况手动返回；发起请求有短暂有效期。[衔接说明](https://docs.wisprflow.ai/articles/1986921789-how-to-set-up-flow-shortcuts-for-iphone) | 关闭时点击图标会打开 Home，仍需点开启麦克风，再返回键盘点一次开始。用户已经表达的录音意图没有贯穿这条路径。 |
| 点击之前知道会发生什么 | 用麦克风空心／实心区分是否会切 App。[状态说明](https://www.typeless.com/help/release-notes/ios/when-does-app-switching-happen) | 文档区分设置未完成、启动、录音、处理和故障状态；未核实当前关闭／就绪的具体图标。[键盘说明](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone) | 关闭和就绪都呈现实心麦克风，但一个跳转、一个录音。纯图标可以保留，应提供可辨认的状态差异。 |
| 说完与不要这一段 | 手机端再点同一按钮结束；开发者发布记录还列出独立 Cancel。[听写](https://www.typeless.com/help/quickstart/dictate)、[版本记录](https://apps.apple.com/us/app/typeless-ai-voice-keyboard/id6749257650) | 首次使用教程用勾选按钮完成；取消、重试与重新录音在故障说明里分开处理。[教程](https://docs.wisprflow.ai/articles/3152211871-setup-guide)、[重试说明](https://docs.wisprflow.ai/articles/2503460374-retry-failed-transcriptions) | 点击波形结束并提交；键盘缺少独立取消当前片段的入口。误触后不应只有等待或提交这一种正常出口。 |
| 声音与操作反馈 | 本轮没有找到 iOS 采样频率、实际延迟或具体振动模式的公开承诺。 | iOS 音量指示随键盘活跃更新，真正静音时为空；另有触感和减少动态效果说明。[音频说明](https://docs.wisprflow.ai/articles/8884408990-connect-and-set-up-external-audio-devices)、[键盘说明](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone) | 第 23 版改为真实音量 20 Hz、缩短动画，并允许录音期间触感。现在仍需验证轻声、停顿、连续语音和耳机，频率数字本身不能代表跟手。 |
| 转写失败 | History 支持复制、用相同音频重试和删除。[历史说明](https://www.typeless.com/help/quickstart/history-and-dictionary) | 键盘可以打开具体错误及恢复操作；History 提供重试。[键盘错误](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)、[重试](https://docs.wisprflow.ai/articles/2503460374-retry-failed-transcriptions) | 第 23 版已移除失败阻塞，并将旧重试与新录音隔离。但键盘尚缺明确的“失败、已保存到 History”反馈；用户可能只看到按钮恢复，却不知道这一段去了哪里。 |
| 未插入与收起键盘 | 官方说明支持短暂离开后继续录音；具体跨输入框落点没有同机验证。[版本记录](https://apps.apple.com/us/app/typeless-ai-voice-keyboard/id6749257650) | 对未送达文本提供恢复操作；录音未捕获音频时需要重新录，不能恢复不存在的音频。[恢复说明](https://docs.wisprflow.ai/articles/2503460374-retry-failed-transcriptions) | 离开输入框时取消自动插入意图，避免旧文字串入其他位置；可从 History 复制。保护已有，但键盘缺少明确的手动恢复上一条结果入口。 |
| 改几个字 | 滑动切换到文字键盘，补字、标点和小修正。[Swipe-to-type](https://www.typeless.com/help/release-notes/ios/swipe-to-type) | 字母键盘、光标移动、长按删除等遵循熟悉的键盘操作。[键盘说明](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone) | 主要是回车、删除和切换键盘。可以继续保持简单，但需把切到系统键盘修改、再回来录音的路径做好。完整多语言键盘会明显增加维护成本。 |
| 首次设置成功的标准 | 有手机听写操作说明。[Dictate](https://www.typeless.com/help/quickstart/dictate) | 教程让用户实际说一句并看到文字插入。[Setup](https://docs.wisprflow.ai/articles/3152211871-setup-guide) | 主要是设置示意与步骤文字，缺少实际验证闭环。首次引导应通过真正的键盘完成一句话；这不需要恢复已删除的常驻独立录音功能。 |
| 历史管理 | 有复制、重试、删除、保留时长等操作；较新的发布说明增加可选同步。[历史](https://www.typeless.com/help/quickstart/history-and-dictionary)、[同步更新](https://www.typeless.com/help/release-notes/ios/keep-your-history-synced) | 历史条目提供按结果状态区分的复制／重试操作。[故障恢复](https://docs.wisprflow.ai/articles/4984532368-fix-taking-longer-than-usual-and-transcription-errors) | 失败项有 Retry／Delete，成功项目前以两行预览和 Copy 为主。失败恢复已经改善，完整文本查看和统一的记录管理仍是后续取舍。 |

## 两项必须单独判断的产品规则

**后台会话与一段录音的时长。** VoiceType 按用户已经确认的固定窗口运行：从打开麦克风起计时，多次录音不重置，有限窗口到期结束采集并处理已录内容。Home 已有相应解释，但键盘仍缺少会话即将到期等衔接反馈。Wispr 的专门文章将其描述为后台闲置超时、不打断正在说话；另一篇故障文档的描述并不完全一致。Typeless 也没有在本轮资料中给出可直接对应的固定时长规则。这一部分应明确记录为产品取舍，不能根据一个竞品页面擅自改变已有约定。[Wispr 会话说明](https://docs.wisprflow.ai/articles/3634682593-why-the-orange-dot-or-mic-indicator-stays-on-after-dictating-ios)、[另一故障说明](https://docs.wisprflow.ai/articles/4984532368-fix-taking-longer-than-usual-and-transcription-errors)

**听音乐与用哪个麦克风。** Wispr 的 iOS 文档允许默认使用内置麦克风，同时通过蓝牙耳机播放音频。这个例子提示我们应分别设计播放与拾音行为。VoiceType 当前允许混播和蓝牙免提输入，但还没有清楚的产品级音频路由策略或实机验证结论。不能声称竞品在所有耳机上都不打断音乐，也不能把它们桌面端的静音设置直接当成 iPhone 行为。[iOS 音频路由说明](https://docs.wisprflow.ai/articles/8884408990-connect-and-set-up-external-audio-devices)

## 我之前遗漏的整体设计

第一，麦克风是否可用、是否正在录一段、是否正在处理旧录音，需要分别定义。先前让失败记录阻止麦克风，是把这几件事绑在一起产生的产品错误；第 23 版的拆分解决了这个阻塞，但尚未补齐所有用户可见反馈。

第二，每个状态都需要明确“用户看见什么、此时点击会怎样、失败时怎么退出来”。去掉 Speak／Stop 文字可以保持界面简洁；同时要保留状态差异、取消出口和必要的异常提示。动画和振动也应各有含义：按下表示收到触摸，真实声纹表示已经收到声音，处理状态表示收音已经结束。

第三，验证应围绕完整任务。正常说一句之外，还要覆盖：第一次安装、麦克风未开、权限撤销、未登录、网络断开、额度不足、听音乐、蓝牙切换、收起键盘、切换输入框、会话到期、连续录音，以及旧重试在新任务期间完成。单个按钮或静态页面检查无法覆盖这些组合。

## 建议定稿的操作规则（尚未实施）

1. 从键盘发起的录音请求应贯穿必要的激活流程；普通打开 App 与用户主动发起录音需要区分。无法自动返回时，给出直接的返回引导。
2. 关闭、就绪、启动中、正在录音、处理中、失败已保存，必须在界面上可区分；正常状态保持简洁。
3. 结束并提交、取消当前片段、关闭后台麦克风，是三个不同意图。每个意图应有固定行为。
4. 新录音保持可用；旧失败留在 History。需要恢复文字时由用户明确触发，避免旧结果突然插入新输入框。竞品公开资料没有证明两家都允许历史重试与实时录音并行；这是我们第 23 版独立验证的设计。
5. 收起键盘、换 App、换输入框后，录音是否继续、文字去哪、怎么找回，都要有明确规则。
6. 新手第一次使用，以真正通过键盘完成一次文字插入作为成功标准。

建议优先定稿前四项，再安排音频场景与首次使用的完整验证。姓名／术语词典、少量纠错可以后续评估；完整文字键盘、翻译、语音改写、笔记和多端同步先保留为候选，符合维护成本可控的小产品目标。Home／History／Credit／Settings 的现有分工可以保留，无需恢复重复入口。

## 资料局限与源码依据

- Wispr 最新帮助说明明确存在 iOS 26.4 之后的手动滑回路径，因此不能保证每次都自动返回。不同版本记录与帮助文档的描述也有差异。[当前键盘说明](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)
- Typeless 7 月激活页声称空闲时关闭麦克风；该声明不能证明其内部机制，也不能套用到 VoiceType 的持续后台采集实现。[激活说明](https://www.typeless.com/help/release-notes/ios/when-does-app-switching-happen)
- Typeless History 通用指南的“仅本机”描述与较新可选同步发布说明不一致，本文采用较新、明确注明可选的说明。[同步更新](https://www.typeless.com/help/release-notes/ios/keep-your-history-synced)
- 未比较两家识别准确率、端到端延迟、耗电、支付或实际触感，不作胜负判断。
- VoiceType 当前路径：[链接进入 Home](/Users/kyleqi/Downloads/voicetype-keyboard/VoiceType/VoiceTypeApp.swift)、[Home 与 History 界面](/Users/kyleqi/Downloads/voicetype-keyboard/VoiceType/Views/DashboardView.swift)、[键盘状态和插入](/Users/kyleqi/Downloads/voicetype-keyboard/VoiceTypeKeyboard/KeyboardViewController.swift)、[独立录音恢复](/Users/kyleqi/Downloads/voicetype-keyboard/VoiceType/Services/RecordingController.swift)、[时长策略](/Users/kyleqi/Downloads/voicetype-keyboard/Shared/RecordingSessionPolicy.swift)。源码在本轮只读。
