# VoiceType：恢复 build 27 与上架资料

日期：2026-10-02。按用户要求撤回产品层面改动，填写 App Store Connect，并将公开产品资料迁到公司域名。正式审核未提交，保持手动发布。

## 产品恢复

- iOS 主 App、键盘、Live Activity、共享代码、测试和 Xcode 项目共 69 个文件，与保存的 build 27 基线 `eaa91c3eb3110fbb9dd66fc72a5b1820973af766` 完全一致。
- 移除新增 ABC 输入界面、云端同意弹窗及设置开关，恢复原有键盘点击进入 App 并自动启用麦克风的实现。
- 原 build 27 签名归档保留，主 App 和两个扩展均为 `1.0.0 (27)`。App Store 已选用此前上传且有效的 build 27；未上传 build 28/29。
- 回归通过：116 项 iOS 测试、7 项共享检查。完整回归运行时使用恢复后的产品源码及 build 29 包装版本号，随后项目号恢复为 27；截图工具独立重新构建了原版 build 27。
- iPhone10 安装两次均被设备锁定阻止，错误 `kAMDMobileImageMounterDeviceLocked`。手机尚未完成回退安装；没有卸载 App 或删除数据。键盘跳转及灵动岛停止录音仍需恢复安装后的真机验证。
- 用户此前要求的独立所有者模型管理后台继续保留，入口为 https://voicetype.y.dog/admin 。

## 公司页面

- 产品：https://apeonwheels.com/voicetype/
- 隐私政策：https://apeonwheels.com/voicetype/privacy/
- 支持：https://apeonwheels.com/voicetype/support/

旧 `voicetype.y.dog` 的 `/privacy`、`/privacy-policy`、`/support`、`/help` 均重定向到公司页面，因此原二进制中的链接继续可用。隐私及支持文案对应 build 27 实际行为，包含 OpenAI 处理、本地失败录音、账户历史、词汇提示、账户删除及备份保留说明。

部署仅新增公司网站的 VoiceType 路径并调整上述重定向。14 个无关文件哈希未变，已有 Money Flow、Guanxiang、公司主页及 VoiceType 健康检查均返回 200，没有重启容器。线上备份：`/opt/voicetype/backups/company-voicetype-20261002T093402Z`。

最终文案复核补充了时限/中断可结束已开始的片段并转写，以及运行日志在账户删除后可留存至轮换或删除。修正页面于 `20261002T102120Z` 再次发布并验证，修正前快照保存在同时间戳的备份目录。

## App Store Connect 已保存

App ID：`6776679139`，商店版本 `1.0`，构建 `1.0.0 (27)`。

- 保留名称 VoiceType Keyboard；填写副标题、推广文案、描述、关键词、版权和公司域名链接，同步 TestFlight 公共链接。
- 保存与 build 27 对应的审核步骤和后台音频说明，明确标记真机演示录屏尚未附上。
- 六张实际界面截图：iPhone、iPad 各三张，均已被 Apple 处理为 `COMPLETE`。替换前的图片已备份到本地。
- 核对年龄分级 4+、Productivity 分类、Apple 标准许可及六类已发布隐私标签。未宣称新的无障碍支持能力。
- App 价格为免费；175 个地区设为发布后可用，三档现有消耗型内购一起加入草稿。
- 草稿 `1d2fd1b1-7ef1-4cb6-88cf-950cb6499438` 共四项：App 版本及三档内购，状态 `READY_FOR_REVIEW`，`submittedDate` 为空。
- 原拒审记录已结束并保留历史消息。没有点击 Submit for Review；发布方式仍是 `MANUAL`。

## 未完成的真机证据和区域资料

Apple 2026-06-18 对 build 9 的 2.5.4 拒审要求真机录屏展示退到主屏幕后持续后台录音。当前仍缺该附件，不能以模拟器截图或“Ready for Review”草稿状态代替。

需要在解锁的 iPhone10 安装 build 27 后录制：键盘点麦克风 → 进入 App 自动启用 → 回到主屏幕 → Notes 中口述并插入 → 关闭麦克风。同时单独核对灵动岛停止按钮。三档真实沙盒购买、退款等支付流程及 iPad 真机检查未在本次完成。

China Mainland ICP Filing Number 仍为空，没有填写未经提供的备案号码。175 地区可用设置不构成当地分发资格或审核通过的证明。

## 本地证据

- `build/product-restore-20261002/restore-verification.json`：逐文件一致性、测试及真机状态。
- `build/product-restore-20261002/ios-baseline-full.xcresult`、`ios-baseline-full.log`、`shared.log`：回归结果。
- `build/product-restore-20261002/build27-signature.json`：原归档签名与版本。
- `build/company-pages-20261002/production-verification.json`：线上页面、重定向及无关文件完整性。
- `build/store-20261002/metadata-after.json`、`screenshots-final-iphone.json`、`screenshots-final-ipad.json`、`final-state.json`：Apple 保存结果。
- `build/store-20261002/asc-draft-final.png`：Chrome 中显示 build 27 和三档内购的四项草稿。
- `build/store-20261002/device-restore27-retry.json`：手机锁定导致的安装失败。

上述证据目录不进入 Git；凭据也不进入仓库。
