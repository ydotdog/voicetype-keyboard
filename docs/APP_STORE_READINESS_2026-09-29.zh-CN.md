# VoiceType App Store 发布差距检查

检查日期：2026-09-29。检查对象：当前工作区、1.0.0（27）归档、Apple 官方 API 和线上公开服务。

**结论：已有稳定的自动化测试和可用的 TestFlight 包，但还不适合直接重新提交审核。确定缺口集中在隐私授权、年龄问卷、旧送审配置；另外需要完成真机和支付验收，并处理键盘扩展的审核风险。**

本轮为检查：未修改产品代码、后台配置或 Apple 送审资料，未购买、删除账户或提交审核。新增本报告并将检查证据保存在 `build/appstore-audit-20260929/`。

## 本轮确认通过

| 项目 | 当前证据 | 证据边界 |
| --- | --- | --- |
| iOS 自动化 | iOS 26.2 模拟器，116 项测试通过：21 项 XCTest、74 项主 App Swift Testing、21 项键盘 Swift Testing | 不代表实际麦克风、蓝牙、后台调度、支付或真机插入已经验证 |
| 后端及共享检查 | 135 项通过；1 个本机 LibreSSL 兼容警告，无失败 | 本轮没有重跑线上 PostgreSQL/容器压力测试，也没有向真实转写供应商发音频 |
| 线上服务 | `/health/ready` 返回成功，13 项检查全部为 true；健康、隐私、支持、产品目录页面均正常 | 配置就绪不证明供应商余额、真实 Apple 通知送达或购买到账 |
| TestFlight | build 27 为 `VALID`、`IN_BETA_TESTING`、`APP_STORE_ELIGIBLE`，未过期 | 这是测试分发状态，不是正式 App Review 通过 |
| 发布归档 | 现有 build 27 的严格签名校验通过；主 App 和两个扩展均为 1.0.0（27）；SDK 为 iOS 26.2 | 没有基于当前未提交工作区重新生成发布归档 |
| 基础资料 | 隐私/支持 URL 已填写；有已处理完成的 iPhone、iPad 截图；已有年龄分级和三个消耗型内购商品 | 截图内容是否仍对应当前 UI、商业协议和当前隐私标签仍需最终复核 |

SDK 已达到 Apple 自 2026-04-28 起要求的 iOS 26 SDK 最低门槛：[Apple 官方说明](https://developer.apple.com/cn/news/?id=ueeok6yw)。

## 发布前必须完成

### 1. 补齐 App 内隐私入口与第三方 AI 明确授权

**已确认代码缺口。** 对 App 的 Swift 源码检查未找到隐私政策链接、OpenAI 数据披露界面或用户同意状态；登录页和设置页也没有这些入口。现有麦克风授权只说明语音转文字和后台录音，没有说明音频与词汇提示会发送到 OpenAI。实际上传直接进入后端请求。

线上隐私政策已经公开说明 OpenAI、音频和词汇提示的处理方式，但仅有网站政策不够。

需要完成：

- 登录页和设置中提供易于访问的隐私政策链接；设置中同时提供支持入口。
- 首次启用云端转写前，明确告知发送的数据、VoiceType 后端及 OpenAI、处理用途，并取得用户主动同意。
- 拒绝或撤回同意后不得上传；正常录音、键盘触发、History 重试均应遵守同一授权状态。
- 核对线上隐私政策、App Privacy 标签和实际数据流一致。

依据：[审核指南 5.1.1(i)、5.1.1(ii)、5.1.2(i)](https://developer.apple.com/app-store/review/guidelines/#privacy)。

代码定位：`VoiceType/Views/DashboardView.swift:277`（登录页）、`:1126`（设置）、`VoiceType/Services/RecordingController.swift:654`（系统麦克风授权）、`:884`（上传入口）。

### 2. 完成年龄分级新增问题

**已确认后台字段未填。** 当前年龄分级为 4+，但 `socialMedia` 和 `socialMediaAgeRestricted` 均为 null。

Apple 已要求自 2026 年 9 月起，新提交或更新必须回答新增社交媒体问题。按当前功能，VoiceType 没有社交内容流，预计应申报无社交媒体功能；仍需在问卷中完成适用回答并保存，不能把已有 4+ 当作新问卷已经完成。

依据：[Apple 2026-07-09 公告](https://developer.apple.com/news/?id=tlur8uvi)。

### 3. 将正式送审配置更新到最终候选版本

**已确认 Apple 后台仍是旧状态：**

- 正式版本 1.0：`REJECTED`，发布方式 `MANUAL`。
- 关联构建仍是 build 9；build 27 目前只在 TestFlight。
- 旧审核提交状态为 `UNRESOLVED_ISSUES`。
- Small、Medium、Large 三档内购都是 `READY_TO_SUBMIT`，尚未通过审核。

修复并验收最终包后，选择对应新构建，处理旧拒审事项，将三档内购与 App 放进同一个适用的送审草稿，核对草稿完整性后再提交，保留手动发布。

首次消耗型内购须随 App 版本一起审核：[Apple 内购送审说明](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase)。

### 4. 更新商店介绍、审核说明和演示证据

**已确认文字过时。** 线上商店介绍仍说“在主 App 录音，再用键盘插入”；线上审核说明仍要求点击 Home 录音控件，而独立录音入口已被移除。审核员按现有说明操作可能无法找到功能。

- 用最终包重走“启用键盘 → 开启麦克风 → 返回 Notes → 录音 → 文字插入 → 关闭麦克风”，据此改写说明。
- 写清后台音频的目的、会话时长、用户停止入口、临时待机音频处理方式及 Full Access 的用途。
- 准备真机演示，展示其他 App 处于前台时确实可以口述插入并停止麦克风；当前审核附件数量为 0。
- 当前各有一张 iPhone 和 iPad 商店截图，状态 COMPLETE；送审前应确认并更新为最终界面。本轮没有对这些远端截图做视觉一致性判定。
- 确保审核员登录后有足够额度测试短录音。
- 重新读取 Resolution Center 原始拒绝信息，逐项回应。本轮官方 API 确认了拒绝状态，但浏览器需要重新登录，因此未读取拒绝消息原文；仓库里以 2.5.4 为主题的说明不能替代原文。

依据：[Apple 审核指南 2.1、2.3、2.5.4](https://developer.apple.com/app-store/review/guidelines/)。

### 5. 完成最终包的真机验收

**缺少当前版本的完整验收证据，不等于确认这些功能仍然有故障。** 仓库中主要验收清单仍以 build 24 为当前版本，并保留多项待测。

| 验收组 | 应取得的证据 |
| --- | --- |
| 主流程 | iPhone 和 iPad：新装、Apple 登录、键盘启用、授权、录音、转写、正确输入框插入、关闭麦克风 |
| 权限与系统限制 | 拒绝/恢复麦克风权限、关闭 Full Access、密码框、禁止第三方键盘的宿主 App，均有可理解的行为 |
| 会话与音频 | 5 分钟到期、12 小时/Forever 策略、单段上限、锁屏、前后台、电话中断、蓝牙切换、音乐共存、快速启停 |
| Live Activity | 明确停止入口、移除活动后停止麦克风；区分灵动岛收起与实际移除 |
| 恢复与账户 | 断网后重试、杀进程恢复、登录过期、账号切换，无丢失/跨账号显示/重复扣费；真实删除与 Apple 授权撤销 |
| 支持范围 | iPad 横竖屏与多任务、最小支持系统、当前公开 iOS/iPadOS、较大字体和小屏体验 |

本轮自动测试使用 iOS 26.2；不能将其作为所有支持系统或真机行为的验收。

### 6. 完成真实沙盒内购与退款闭环

本地计费、幂等和退款测试已通过；线上 V2 通知的 Sandbox/Production 地址也已配置。但是目前没有本轮取得的端到端证据。

- 在最终测试包验证三档购买、取消、待处理、购买完成但网络断开、重启后补发。
- 将实际余额与服务端账本对应，确认每笔仅入账一次。
- 验证 Apple TEST 通知送达、实际沙盒退款及退款撤销，检查余额变化。
- 当前资料记录过缺少适用的 App Store Server API 内购密钥；本轮未检查私钥库存，不能确认该缺口是否已补齐。
- 上架前在 Business 页面复核协议、税务、收款和适用地区的交易者声明；历史 Active 状态不代表今天仍有效。

这组工作是本项目的发布验收要求，不能因为商品已 `READY_TO_SUBMIT` 就视为支付链路正常。

## 需要先处理的审核风险

### 键盘扩展的 4.4.1 风险

当前 Full Access 关闭时，回车、删除、切换键盘仍可用，自动测试也覆盖了前两项；没有普通字符输入，核心语音功能不可用。麦克风关闭时，扩展使用 SwiftUI `Link` 打开 VoiceType 主 App。

Apple 4.4.1 要求键盘具备输入功能、可切换下一键盘、在无网络或无 Full Access 时仍可工作，并限制启动 Settings 以外的 App。因此这两处是需要明确处理的审核风险：仅回车/删除是否足够，和扩展跳转主 App 的交互是否会被接受。使用公开 SwiftUI API、测试通过都不能单独证明审核会接受。

建议在最终送审前提供实际可用的离线基础输入；评估并调整从键盘启动主 App 的依赖，至少确保审核员能从主 App 手动启用麦克风后完成整个流程。本报告不把它写成 Apple 已确认的拒审原因。

依据：[Apple 审核指南 4.4.1](https://developer.apple.com/app-store/review/guidelines/#extensions)。代码：`VoiceTypeKeyboard/KeyboardViewController.swift:401`、`:735`、`:850`；测试：`VoiceTypeKeyboardTests/KeyboardLifecycleTests.swift:384`。

## 发布收尾与运营

- 冻结可复现源码：当前 `main` 的提交仍是 build 25 记录，build 26/27 的 UI、配置、图标及相关文件还在未提交工作区。先整理分支、review、提交最终版本，再把构建和源码一一对应。
- 更新 `LAUNCH_READINESS.md`、`RELEASE_CHECKLIST.md`、`LAUNCH_STATUS.zh-CN.md`，以最终候选包为准，保留历史记录但避免旧状态充当当前结论。
- 核实转写供应商余额、真实短音频转写、延迟与错误告警、退款通知失败告警、定期备份与恢复流程。已有就绪检查和过去的备份恢复证据，仍不足以证明持续监控已经运行。
- 如首发面向中文用户，补中文界面/商店页是产品完善项；当前仅有英文商店文案。它不是所有地区发布的普遍强制条件。

建议顺序：**隐私与键盘风险处理 → 最终构建及自动回归 → iPhone/iPad 与沙盒支付验收 → 更新材料和问卷 → 复核送审草稿 → 用户决定提交 → 审核通过后手动发布。**

## 本轮证据

- `build/appstore-audit-20260929/asc-readonly.json`：App、构建、内购、审核状态。
- `build/appstore-audit-20260929/asc-details.json`：关联 build 9、线上文案/审核说明、隐私 URL、年龄问卷。
- `build/appstore-audit-20260929/asc-assets.json`：截图处理状态、空审核附件；其中个别不支持的 API 查询错误不影响已取得的状态结论。
- `build/appstore-audit-20260929/service-readiness.json`：13 项检查和产品目录。
- `build/appstore-audit-20260929/python-tests.log`：135 项通过。
- `build/appstore-audit-20260929/ios-tests.xcresult`、`ios-summary.json`、`ios-tests.log`：116 项通过。
- `build/appstore-audit-20260929/archive.json`：归档版本与 SDK。

早期公开服务探测对 `/ready` 和 `/v1/billing/catalog` 返回 404；它们不是本项目的实际接口。随后按源码访问 `/health/ready` 和 `/v1/billing/products` 均成功，不能把早期 404 当作产品故障。
