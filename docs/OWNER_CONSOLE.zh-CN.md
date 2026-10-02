# VoiceType 模型管理后台

地址：https://apeonwheels.com/voicetype/admin

旧地址 `https://voicetype.y.dog/admin` 重定向到上述公司域名。登录密码不变。

仅所有者使用。登录密码保存在本机 `~/.config/voicetype/admin-access.txt`，不放进仓库、App 或聊天记录。

## 日常操作

1. 登录后选择转写模型，填写账户备注；更换密钥时输入新的 OpenAI API key，留空会保留当前密钥。
2. 点击“测试转写”。后台只发送随软件附带的固定合成语音，会产生少量供应商费用，不使用客户录音。
3. 测试成功后点击“保存并生效”。更改对新请求即时生效，已经开始的请求沿用原配置，不需要重新发布 App。
4. 如需恢复，在历史配置中选择旧版本，点击“测试并准备恢复”，成功后确认恢复。

当前支持 OpenAI 官方接口的 `gpt-4o-mini-transcribe`、`gpt-4o-transcribe`、`whisper-1`、`gpt-4o-transcribe-diarize`。暂不允许任意服务商 URL；新增处理方需要相应的数据告知和服务端计费适配。Diarize 不支持词汇提示。

2026-10-02 核对 [OpenAI 官方停用公告](https://developers.openai.com/api/docs/deprecations)：上述四个模型计划于 2027-02-26 停用。当前配置未被更换；新模型接入应另行测试识别质量、响应格式、词汇提示和计费。

## 密钥和会话

完整密钥不会返回浏览器或 App；页面只显示指纹。配置与最近 10 个版本以 Fernet 加密后原子保存，文件权限 0600；同一页面测试成功的精确配置才能保存，10 分钟后须重新测试。并发更改会拒绝覆盖旧版本。

登录有效期一小时；退出会撤销该会话。服务重启会使所有管理会话失效。登录与连接测试有频率限制；密码哈希使用 PBKDF2-SHA256，600,000 次迭代。管理接口要求同源请求，Cookie 使用 Secure、HttpOnly 和 SameSite=Strict。生产服务保持单 worker；扩展为多 worker 前需迁移共享会话和限流存储。

## 服务端维护

- 加密配置：`/opt/voicetype/data/provider/settings.enc`。
- 服务环境：`/opt/voicetype/env/backend.env`。保留 `PROVIDER_CONFIG_ENCRYPTION_KEY`；丢失后无法解密历史密钥。
- 公司域名配置：`ADMIN_ORIGIN=https://apeonwheels.com`、`ADMIN_BASE_PATH=/voicetype/admin`。反向代理保留完整 URI，Cookie 仅限管理路径；默认部署仍兼容 `/admin`。
- 2026-09-29 发布备份包含原部署源码、镜像、环境和数据库，并在隔离 PostgreSQL 中恢复比较了全部表数据和序列。
- 今后备份须一起保存加密配置目录与环境中的加密密钥，私密存储，恢复后先做连接测试。
- OpenAI 余额与 App 用户积分独立。管理页面提供官方账单入口，不把“密钥已配置”当作有余额；连接测试可确认当时实际可用。
- 最近活动显示当前服务启动以来的测试、保存和供应商错误；服务器日志继续保留完整事件。它不是已经配置好的外部告警服务。
- 2026-09-29 已对线上当前模型完成合成语音调用，测试用时 1.848 秒；保存了相同密钥和模型以验证加密配置持久化，没有切换供应商或价格。

## 公司域名迁移记录（2026-10-02）

- 默认路径及自定义前缀的登录、同源校验、Cookie 范围、测试后保存、退出失效等回归通过；后端及共享共 168 项测试通过。
- 线上新入口、CSS、JS 均返回 200；未登录状态为 401、旧 Origin 的登录请求为 403。原密码登录成功，合成音频连接测试成功（1.228 秒），退出后会话失效；旧入口为 308 重定向。
- 当前供应商配置文件校验值未变，没有替换模型或 API key。只重建后端，Caddy reload；其他容器启动时间保持不变，产品及隐私页面仍可访问。
- 回退备份：`/opt/voicetype/backups/admin-company-20261002T105514Z`，包含旧管理源码、环境、Caddy 配置及镜像标识。此次没有引入数据库迁移。
- 证据：`build/admin-company-capacity-20261002/deploy-result.json`、`console-verification.json`。
- 容量分析见 [CAPACITY_2026-10-02.zh-CN.md](CAPACITY_2026-10-02.zh-CN.md)。
