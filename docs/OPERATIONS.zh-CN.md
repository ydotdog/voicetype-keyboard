# VoiceType 额度与 API 管理

核对日期：2026-09-21。免费额度等数值来自线上运行进程的白名单配置；未读取或导出密钥、用户明细或 API 账户余额。

## 新用户与 TestFlight

- 首次 Apple 登录赠送 100,000 credits（App 内 $0.10 余额），一次性、不过期、不按月刷新。
- 按 Apple 身份记录领取资格；删除账号重建不会重复赠送。
- 测试者没有独立赠送档位。TestFlight 使用沙盒购买，服务器目前接受 `SANDBOX,PRODUCTION`，沙盒购买也会按商品入账：990,000 / 4,990,000 / 19,990,000 credits。
- 沙盒购买不向测试者收费，但实际转写仍由运营者的 OpenAI API 账户支付。没有另设测试者累计免费上限。
- 当前沙盒与正式购买写入同一用户余额账本，并未实现独立的测试余额钱包。正式运营前应决定隔离策略；本次界面改动不修改账本。
- 每次转写先预留预计额度，最低 20,000 credits；长录音可能预留更多。成功按实际计费结算，失败释放预留。低于门槛时，即使最终费用可能很低，也会拒绝启动转写。
- 免费额度不是固定分钟套餐。不要把 100,000 credits 宣传为保证可用的分钟数。

## 目前的服务端

有 FastAPI 转写、登录、支付验证和账本服务，没有可视化运营后台，也没有运营者登录页面、API 余额告警或自动供应商切换。

线上配置：官方 OpenAI 地址，`gpt-4o-mini-transcribe`，`COST_MARKUP_BPS=7143`；开发赠送接口关闭。用户使用余额与运营者的 API 账单是不同的账本。`/health/ready` 只检查密钥是否存在，不证明密钥有效或还有余额。

## 更换同一服务商的 API 密钥

1. 先在供应商后台核对余额、项目归属与权限。更换同一项目下的 key 不会增加余额。
2. 在服务器上保留受限权限的旧配置备份。密钥只写入 `/opt/voicetype/env/backend.env` 的 `OPENAI_API_KEY`，不要放进 App、Git、聊天或日志。
3. 如果切换到不同的供应商账户，同时设置新的 `OPENAI_PROVIDER_ACCOUNT_ID`，使未来记录能区分成本来源。保持数据库、Apple 凭据、JWT 和 `SIGNUP_GRANT_HMAC_SECRET` 原值。
4. 更新环境文件后，只重新创建 backend 服务，让进程读取新环境。普通容器 restart 不会重新加载 Compose 的 env_file：

   ```sh
   cd /opt/voicetype/app
   sudo docker compose -f deploy/gcp-vm/docker-compose.yml up -d --no-deps --force-recreate backend
   ```

   此操作会短暂中断后端，宜等正在转写的请求结束再执行。
5. 检查服务健康，并用不含私人内容的短录音确认真实转写成功、只扣一次额度；失败则恢复旧配置并重新创建 backend。通过后再停用旧 key。

App 继续访问原来的 `https://voicetype.y.dog`，无须用户升级。更换为其他供应商还需验证认证、`/v1/audio/transcriptions` 路由、multipart 字段、语言/词表提示、响应格式、usage 及费用表；不能只换 URL 就视为完成。

## Personal vocabulary 如何学习

- 设置中的 “Learn from my corrections” 默认开启。
- 在 History → Edit & teach 中编辑一条转写时，App 比较前后文字，针对一次较小的修改提取候选词。系统自然语言识别优先尝试人名、地名和组织名；英文扩展到完整单词，否则使用修改片段。
- 用户检查或修改候选词，打开 “Remember a spelling” 并保存后才加入词表。单纯复制文字、普通转写成功或在其他 App 中修改文字不会触发学习。
- 保存的是希望识别出的写法，不是不断训练个人模型，也不是“错误词 → 正确词”的强制替换表。下一段录音会把词表作为提示传给识别服务，不能保证每次同音词都正确。
- 按账号保存在当前设备，不做跨设备云同步。最多 200 条，每条 2–40 字符；每次使用最近最多 50 条，并受总长度限制。重新教同一个词会移到前面，频繁说出某个词不会自动提高它的排序。
- 可手动添加、逐条忘记、清空，或关闭默认纠错学习。关闭不会清除已有词，也不阻止用户在一次纠错中主动选择记住。
- 保存修改更新当前设备 History，不会改变已插入其他 App 的文本。失败录音重试使用当时的原始语言和词表提示。

Apple 参考：[TestFlight 内购测试](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight)。
