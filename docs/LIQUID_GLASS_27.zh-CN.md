# Build 27：恢复原版 logo 尺寸

Build 26 的透明前景为 1254 × 1254，在 Icon Composer 的 1024 画布中以 100% 放置，导致图形变大；生成的前景轮廓也没有完全保留原始比例。

修正：从仓库原始 AppIcon.png 的两个图形轮廓提取矢量路径，使用 1024 × 1024 坐标保存为 `VoiceTypeIcon.icon/Assets/VoiceTypeMark.svg`，保留原图形位置、大小和留白；轮廓简化误差不超过 0.3 个源像素。移除生成的前景位图引用。纯白背景及分层外观保持不变。App 功能保持 build 26 的实现。

## 验证

对比三份实际 Release archive 的 152 × 152 编译图标，以蓝色通道小于 128 的前景区域测量，范围为左、上、右、下（右/下不含）：

| 版本 | 前景范围 |
| --- | --- |
| 原版 build 25 | 51, 31, 119, 109 |
| build 26 | 38, 21, 129, 117 |
| 修正 build 27 | 51, 31, 119, 109 |

已目视检查原版与修正版编译图标，尺寸和位置一致。原版背景为米黄色，修正版保持白色与系统分层材质。

- Release archive：`build/VoiceType-1.0.0-27.xcarchive`，严格签名检查通过。
- 6 项发布打包检查通过；功能未改变，未重复运行 build 26 的完整功能测试。
- 对比图片与数据：`build/icon27/`。
- TestFlight 已确认 VALID / IN_BETA_TESTING，Internal Testers 可测试。中英文说明已保存并回读。Build ID：`759502e9-0841-465f-89e2-eb885378bd00`；记录位于 `build/release27/testflight-verified.json`。未提交正式 App Store 审核。
