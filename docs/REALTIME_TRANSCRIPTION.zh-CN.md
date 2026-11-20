# 实时转写（OpenAI Realtime）设计

状态：已实现，尚未部署（2026-10-24）。后端、App、键盘和设置页都已写完，测试全部用 mock（后端 318 个、iOS 203 个，全部通过），没有调用 OpenAI 或生产后端。第 0–12 节是 2026-10-23 的设计稿，只在第 8、10、12 节补了注；实现和设计不一样的地方见第 13 节，运维以 `docs/OPERATIONS.zh-CN.md` 的 Live 一节为准。

目标：用户说话时，键盘里就出现文字。现有的“停止后整段上传、边转写边返回”（`docs/OPERATIONS.zh-CN.md` 的流式转写一节）保持不变，作为实时失败时的兜底。本文建立在当前分支未提交的流式转写改动之上（`PartialTranscriptStore`、SSE 路径、同 key 重试）。

## 0. 结论

推荐 **后端 WebSocket 中继 + `gpt-live-transcribe`，一段录音一条连接**：

1. **连接**：键盘点开始后，主 App 连 `wss://voicetype.y.dog/v1/realtime/transcriptions`，边录边推 24 kHz PCM。后端用自己保存的 OpenAI 密钥连 `wss://api.openai.com/v1/realtime?intent=transcription`，把文字传回 App；App 写入 App Group，键盘显示。密钥只在后端。不用临时密钥直连，也不用 WebRTC。
2. **生命周期**：点开始才连，点停止发 `commit`，拿到最终文字就关。片段之间、12 小时或 Forever 的麦克风会话空闲时，都没有实时连接。
3. **模型**：默认 `gpt-live-transcribe`，可配置。官方价 $0.017/分钟，按现有加价约 29,144 积分/分钟，是 gpt-transcribe（7,715）的 3.8 倍。最终文字直接用实时模型的结果，不再整段重转；第 3 阶段用约 50 段录音核对准确率后再定。
4. **计费**：开始时预留 1 分钟，每录约 1 分钟追加一次。拿到最终文字后按 max(后端转发的音频秒数, OpenAI 返回的秒数) 结算一次，账本 `transcription:{id}` 唯一。中途断开、取消、出错都只释放预留，不扣费；OpenAI 那边已经产生的费用由运营者承担，用“每人每天未计费实时秒数”上限防滥用。
5. **恢复**：录音照旧先存在本机。没拿到实时最终文字（断网、超时、出错、余额不足），停止后用同一个 Idempotency-Key 走现有整段上传。服务端加第 3 版认领（`fingerprint_version = 3`），两条路径共用一个 key：实时已完成就返回保存的结果，实时还没提交就让整段上传接管，所以只扣一次。
6. **键盘**：录音中（`.keyboardRecording`）也显示 `PartialTranscriptStore` 的预览。预览从不插入，最终文字仍只经 `claimForInsert` 插入一次。
7. **上线**：服务端开关默认关闭，模型目录加 `realtime` 字段，旧 App 不受影响。先只对运营者开放，再逐步扩大。回滚就是关开关，App 自动退回整段上传。

代价：用户上行流量约 3 MB/分钟（现在的 m4a 约 0.24 MB，约 12 倍）；蜂窝网络下每天实时 10 分钟，估计多耗 1.4–2% 电量；单价 3.8 倍；OpenAI 对 Realtime 端点有 30 天滥用监控留存（文件转写端点没有），隐私政策要改。

收益：边说边看到文字；停止后出结果也更快，因为不用再上传 m4a、解码、整段转写（估计从约 3–5 秒降到约 1–2 秒，待实测）。现在的中位片段只有约 2 秒，这类短句主要受益于出结果更快，预览只来得及刷新一两次。

## 1. 连接方式

### 1.1 两种做法

| | A. 后端 WebSocket 中继（推荐） | B. App 用临时密钥直连 OpenAI |
|---|---|---|
| 密钥 | 项目密钥只在后端 | 后端每段签发临时 client secret（默认 10 分钟有效），App 拿它直连 |
| 计费依据 | 每个字节都经过后端，后端知道音频秒数，也收到 usage | 后端看不到音频，只能信 App 上报，或事后看 OpenAI 的项目级用量（不分用户） |
| 控制 | 后端决定模型、提示词、600 秒上限、每人并发 | 文档说明：一个临时密钥过期前可以开多个会话，会话可在密钥过期后继续，客户端还能改会话配置。被改过的客户端可以绕过计费和上限 |
| 规范化、词表、账本、历史 | 沿用后端现有代码 | App 要把文字送回后端，后端只能相信它 |
| 传输 | WebSocket，iOS 的 `URLSessionWebSocketTask` 原生支持 | 官方把临时密钥和 WebRTC 放在一起介绍，WebSocket 指南也建议浏览器和移动端用 WebRTC。WebRTC 会接管音频会话，和 App 连续录音的 AVAudioRecorder 冲突，还要引入较大的框架 |
| 隐私政策 | “音频经我们的服务器转给 OpenAI”仍然成立，设备 IP 不直接暴露给 OpenAI | 要改成 App 直连第三方 |
| 服务器负担 | 每路多一份出站流量（约 3.84 MB/分钟）和两条长连接；同步数据库调用会卡事件循环，要放进线程池 | 几乎没有 |

**为什么 A 符合“主 App 管音频会话、键盘只发开始和停止”**：键盘扩展本来就不联网、不碰音频，两种做法里实时连接都在主 App。主 App 已经有音频会话和后端登录令牌，键盘一发开始，App 用这个令牌直接连自己的后端即可，不必先找后端换临时密钥再连 OpenAI，少一次往返。真正决定选 A 的是：计费和控制只能放在后端。

### 1.2 后端 ↔ OpenAI

- 地址 `wss://api.openai.com/v1/realtime?intent=transcription`，请求头 `Authorization: Bearer <项目密钥>`。地址由服务商配置的 `base_url` 推出（`https://` 换成 `wss://`），密钥从现有的加密服务商配置（`ProviderConfigStore`）读取，不新增密钥。
- 用 `session.update` 配置转写会话：
  - `audio.input.format`：`audio/pcm`，24000 Hz，16 位单声道。
  - `audio.input.transcription`：`model` 取 `REALTIME_TRANSCRIPTION_MODEL`（默认 `gpt-live-transcribe`）；`languages`、`keywords`、`prompt` 复用 `multilingual_hints(context, language)`。`language` 和 `languages` 不能同时发。
  - `turn_detection: null`：整段只在停止时提交一次。live 模型收到音频就出字，不需要静音检测。
  - `noise_reduction` 先不设，第 3 阶段和 `near_field` 对比。
  - `delay` 先不设。参考文档说它只用于 gpt-realtime-whisper，指南却写得像通用参数，两处不一致。
- 关键词必须是一行，不能含 `<`、`>` 和换行，否则整个配置被拒。现有 `parse_context` 已经拒绝这些字符。万一配置仍被拒，本段改走整段上传，日志只记错误码。
- 音频用 `input_audio_buffer.append`（base64）发送，停止时 `input_audio_buffer.commit`。
- 收 `conversation.item.input_audio_transcription.delta` 累积预览；`.completed` 带最终文字和 usage（按时长计费的模型是 `{type: "duration", seconds}`）；`.failed` 和 `error` 当作失败。不同条目的 completed 可能乱序，要按 `item_id` 对应；本设计每段只有一个条目。
- 文档提到后来的 delta 可能修正前面的文字，但没写修正怎么表示。所以预览由后端累积，App 只收“当前完整预览”；以后改累积规则只动后端。
- 单个会话最长 60 分钟，片段上限是 10 分钟，不受影响。
- live 模型只能在 Realtime 转写会话里用，不能整段上传。所以它只进计价表（`MODEL_PRICING`，按分钟计），不进可选模型列表（`SELECTABLE_MODELS`）；兜底时仍用用户选的整段模型。

### 1.3 App ↔ 后端协议 `voicetype.realtime.v1`

握手 `GET /v1/realtime/transcriptions`（WebSocket 升级）：

- `Authorization: Bearer <登录令牌>`，复用 `current_user`。令牌不放查询串，免得进 Caddy 访问日志。
- `Idempotency-Key: <片段 UUID>`，格式同整段上传。
- `Sec-WebSocket-Protocol: voicetype.realtime.v1`，便于以后升级协议。

浏览器不能在 WebSocket 握手里带 `Authorization` 头，所以不存在跨站劫持问题。

App → 后端：

| 消息 | 内容 |
|---|---|
| `start`（文本） | `{"type":"start","language":…,"context":{"languages":[…],"vocabulary":[…]},"format":"pcm_s16le_24000_mono"}`；context 与整段上传相同，用 `parse_context` 校验 |
| 音频（二进制） | 24 kHz 16 位单声道小端 PCM，每帧 100 ms（4,800 字节），单帧上限 32 KB |
| `commit`（文本） | `{"type":"commit","audio_seconds":12.34}`，App 按录音时间线算出的片段时长 |
| `cancel`（文本） | 用户取消，或片段短于 0.25 秒；释放预留，不扣费 |

后端 → App：

| 消息 | 内容 |
|---|---|
| `ready` | `{"type":"ready","request_id":…,"model":…,"credit_units_per_minute":29144}`，上游会话配置成功后发 |
| `partial` | `{"type":"partial","text":"…","truncated":false}`，当前完整预览的最后至多 500 字；有变化才发，每秒最多 4 次 |
| `done` | 与整段上传完全相同的 JSON（`transcription_payload`），然后正常关闭 |
| `error` | `{"type":"error","status":402,"code":"insufficient_credit","detail":"…"}`，然后关闭 |

错误码：`disabled`、`busy`、`insufficient_credit`、`credit_exhausted`、`key_used`、`superseded`、`fallback_required`、`too_long`、`protocol_error`、`provider_error`、`no_speech`、`server_restarting`（关机时连接以 1012 关闭）。

App 只认一条规则：**没收到 `done`，这段就当没有实时结果**。任何 error、断开、超时都一样（用户取消除外）。录音照常继续，停止后用同一个 key 走整段上传，由整段上传给出真实错误（比如余额不足的 402）。`no_speech` 也再走一次整段上传确认，免得实时链路的问题（比如采到的是静音）让 App 删掉用户的录音。

App 不用等 `ready` 才推音频：连接建立前 App 自己缓存，`start` 之后直接推；后端在上游就绪前最多缓存 10 秒，就绪后一起转发。

### 1.4 App 端采集

- AVAudioRecorder 继续连续录 m4a，作为安全网，不改。
- 新增 AVAudioEngine 输入 tap，经 AVAudioConverter 转成 24 kHz Int16 单声道，每 100 ms 一帧。不开语音处理（voice processing），免得改动音频会话、影响录音。
- 启动方式：
  - **S1（先做）**：片段开始时启动引擎，结束时停止。引擎启动慢会让开头缺音频，由提交时的时长核对兜住：后端转发的秒数比片段时长少 0.5 秒以上，就走整段上传，保证开头不丢。
  - **S3**：键盘可见（`keyboardReady`）时引擎就在运行，保留 0.5 秒环形缓冲，开始时连缓冲一起发。开头一定不丢，代价是键盘可见期间多一点 CPU。S1 实测截头多时改用它。
  - **S2**：整个麦克风会话都运行引擎。最简单，但最耗电，不推荐。
  - 以后可以考虑只用一个引擎，同时写 m4a 和推流，替换 AVAudioRecorder。改动大，不在第一版。
- 遇到中断、路由变化、媒体服务重置：本段放弃实时，录音按现有逻辑处理。
- 发送积压超过 5 秒（网络太慢）：本段放弃实时。
- 放弃实时时清掉预览，免得用户以为还在识别；录音不受影响。
- App 在后台靠音频后台模式持续录音，理论上可以启动引擎，但必须真机确认能启动，且不会让录音出现杂音或断点。

## 2. 计费

### 2.1 现在的整段上传

`perform_transcription`：

1. 在 `lock_user` 下查（用户, key）的 `transcription_requests`：已完成就返回保存的结果；指纹不同返回 409；租约（300 秒）内返回 409 + Retry-After；租约过期就释放旧预留。
2. `reserve_credit` 按实测时长预留，至少 20,000（`MIN_TRANSCRIPTION_RESERVATION_USD_MICROS`）。认领行的 `attempt_id` 就是预留 ID。
3. 调供应商。成功后在锁内核对 `attempt_id` 仍是自己，释放预留，按可用余额封顶扣费，写 `transcriptions` 和账本（`source_id = transcription:{id}`，有唯一索引）。
4. `finally` 释放预留，删除未完成的认领。

预留 30 分钟后才过期（`CREDIT_RESERVATION_TTL_SECONDS=1800`），比 10 分钟的片段上限长，实时会话中途不会过期。

### 2.2 映射到实时连接

| 时刻 | 做什么 |
|---|---|
| `start` | 在线程池里、`lock_user` 下：这个 key 没有认领 → 预留 max(20,000, 1 分钟实时价) = 29,144 积分，写认领行（`fingerprint_version = 3`，`attempt_id` = 预留 ID，`selected_model` = 实时模型）。已有任何认领 → `key_used`。余额不够 → `insufficient_credit`。这两种情况本段都改走整段上传。 |
| 录音中 | 后端数转发的 PCM 字节，秒数 = 字节数 ÷ 48,000。离已预留时长还剩 15 秒时，在锁内核对 `attempt_id` 仍是自己，再给同一条预留加上 1 分钟的价（新函数，`UPDATE credit_reservations SET amount_usd_micros = amount_usd_micros + ?`），同时刷新认领的 `updated_at`。始终只有一条预留，崩溃后也只需释放一条。余额不够 → `credit_exhausted`，关闭上游，释放预留，停止后走整段上传。 |
| `commit` | 记下 `realtime_committed_at`（新列）。转发秒数比 App 报的片段时长少 0.5 秒以上（开头被截或丢帧）→ `fallback_required`，释放，不扣费。否则向上游提交，最多等 30 秒拿到 completed。 |
| completed | `validated_transcript` → `normalize_transcript`。文字为空 → `no_speech`，释放，不扣费。否则计费秒数 = max(转发秒数, usage 秒数)，与现在 `provider_audio_duration` 取较大值的做法一致；`calculate_cost` 用实时模型的价格。结算完全照搬现有代码：锁内核对归属、释放预留、按可用余额封顶、写记录和账本、把认领标为完成。然后发 `done`。 |
| commit 前断开、取消、出错 | 释放预留，删除认领，不扣费。 |
| commit 后断开 | 后端继续等结果并结算。App 稍后用同 key 上传，拿到保存的结果，不再扣费。 |

“只扣一次”的保证和现在一样：每次扣费都在 `lock_user` 下并先核对认领归属；（用户, key）的认领行唯一；账本 `source_id` 唯一；认领一旦完成，之后的尝试都直接拿保存的结果。

### 2.3 价格

按 `COST_MARKUP_BPS=7143`（×1.7143），1 积分 = 1 美元微单位：

| 片段 | live（29,144/分钟） | gpt-transcribe（7,715/分钟） | gpt-4o-mini-transcribe（5,143/分钟） |
|---|---:|---:|---:|
| 2.14 秒（现在的中位数） | 1,041 | 277 | 184 |
| 10 秒 | 4,859 | 1,286 | 858 |
| 30 秒 | 14,572 | 3,858 | 2,572 |
| 10 分钟 | 291,431 | 77,144 | 51,429 |

| 积分包 | live 可用分钟 | gpt-transcribe | gpt-4o-mini-transcribe |
|---|---:|---:|---:|
| $0.99（990,000） | 34.0 | 128.3 | 192.5 |
| $4.99 | 171.2 | 646.8 | 970.3 |
| $19.99 | 685.9 | 2,591 | 3,887 |

最低 20,000 积分只够约 41 秒实时，所以开始时预留 1 分钟的价（29,144）。

### 2.4 运营者承担的费用

- 中途失败或取消的实时音频。OpenAI 定价页没写断开时未提交的音频收不收费，这里按收费估算：假设 5% 的实时分钟被浪费、每人每天 10 分钟，每人每月约 $0.26。
- 兜底时的重复调用：实时已经转了一部分，又整段上传重转一次。用户只按整段模型付一次，运营者付两次。
- 中继出站流量：约 $0.0005/分钟（GCP 外网出站约 $0.12/GB）。100 日活 × 每天 10 分钟 ≈ 每月 115 GB ≈ $14；同期供应商费用约 $510。

### 2.5 防滥用

被改过的客户端可以每段都在 commit 前断开，再整段上传：白看实时预览，只付整段价。对策：

- 每人每天“未计费实时秒数”上限 `REALTIME_UNCHARGED_SECONDS_PER_DAY`，建议 300 秒（约 $0.085）。超过后当天该用户再开始实时一律回 `disabled`，转写照常走整段上传。
- commit 之后断开不计入，因为后端照常结算。
- 计数先放内存（单进程，重启清零可以接受），真出现滥用再存数据库。

## 3. 幂等与失败恢复

### 3.1 App 端（键盘片段）

1. 开始（`beginKeyboardClip`）：当场生成片段 UUID 当 Idempotency-Key（现在是停止后才在 `beginKeyboardClipTranscription` 里生成，要提前）；同时记下这段的语言和词表，实时和整段上传都用这一份。清空 `PartialTranscriptStore`，启动采集和 WebSocket。AVAudioRecorder 照常录音。
2. 录音中：收到属于当前片段的 `partial`，就 `PartialTranscriptStore.publish(text, sessionID:)`。
3. 停止：立刻发 `commit`；同时照旧导出 m4a 并 `retainFailedTranscription` 存恢复记录。这一步是安全网，不能省。
4. 等 `done`：10 秒，片段每满 1 分钟加 1 秒，最多 20 秒。
5. 成功：先清预览，再发布最终文字（`latest` 和 History），删除恢复记录。与现在的完成路径相同。
6. 失败：关闭 WebSocket，清预览，用同一个 key 调现有的 `transcribe(fileURL:duration:token:requestID:onPartial:)`。之后到达的实时消息由 `activeTranscriptionID` 守卫丢弃。
7. 整段上传遇到 409 + Retry-After（实时刚提交、还在等结果）：按 Retry-After 自动重试，最多等 35 秒，不直接报错。

### 3.2 服务端：同一个 key 的接管规则

实时认领在开始时建立，那时还没有完整音频，所以第 3 版指纹只能是 sha256(kind=realtime, language, dictation_context)：不含音频，也不含模型（兜底用整段模型）。整段上传在 `perform_transcription` 比较指纹之前，加一个 v3 分支：

| 已有认领 | 同 key 整段上传怎么处理 |
|---|---|
| 没有、v1、v2 | 不变 |
| v3 已完成 | language 和 context 一致，且上传文件的实测时长与实时计费秒数相差不超过 1.5 秒 → 返回保存的结果，不调供应商，不扣费。否则 409（key 用在了另一段录音上） |
| v3 未完成，35 秒内已 commit | 409 + Retry-After（剩余等待时间）。实时成功，下次拿到保存的结果；实时失败，认领已删，下次正常转写 |
| v3 未完成，还没 commit（仍在推流，或连接已死） | 接管：释放实时的预留，通知同进程的实时会话中止（`superseded`），按 v2 建新尝试。实时会话结算时归属核对失败，不扣费 |

其他规则：

- 实时 `start` 遇到任何已有认领 → `key_used`。
- 同一用户发起新的实时 `start`，会中止他仍在推流（未 commit）的旧会话，不扣费；已 commit 的旧会话照常完成。
- 启动时清理：现在只有一个 uvicorn 进程，重启后不可能还有活着的实时会话，所以启动时释放所有未完成 v3 认领的预留，并删除这些认领。将来多进程部署时，要改成按 `updated_at` 判断过期。
- 关机：推流中的会话以 1012 关闭（uvicorn 0.38 的行为），释放预留；已 commit 的会话借用现有 `finish_transcription_streams()` 的 5 秒收尾，来不及就释放。

### 3.3 场景

| 场景 | 用户看到 | 扣费 |
|---|---|---|
| 正常 | 边说边出字，停止后约 1–2 秒插入最终文字（估计） | 实时价，一次 |
| `ready` 前失败（没网、繁忙、关闭、余额不足、key 已用） | 录音中没有预览，停止后整段上传（照常有 SSE 预览） | 整段价一次；余额真不够时整段上传返回 402 |
| 录音中断网或切换网络 | 预览消失；停止后整段上传 | 整段价一次；已发的实时音频由运营者承担 |
| 中途追加预留失败 | 同上 | 整段上传按可用余额处理（可能 402） |
| commit 后断开 | 等一会儿后整段上传；实时已结算就直接拿到保存的结果 | 实时价，一次 |
| 时长对不上（开头被截） | 停止后整段上传 | 整段价一次 |
| 实时判定无语音 | 整段上传确认；仍无语音就按现有规则删除录音 | 不扣费 |
| 取消，或片段短于 0.25 秒 | 无 | 不扣费；已发出的音频 OpenAI 处理过（隐私政策要写） |
| App 在录音中被杀 | 与现在相同 | 实时部分不扣费 |
| App 在停止后、`done` 前被杀 | 下次启动从 History 恢复，用同一个 key 重试 | 实时已结算就拿保存的结果；否则整段价一次 |
| 部署或重启 | 推流中的片段：停止后整段上传；已提交的：5 秒内完成就正常，否则同上 | 一次 |
| 上游失败或超时 | 停止后整段上传 | 整段价一次 |
| 超过 600 秒 | 与现在相同：App 在 10 分钟时结束片段，后端超限回 `too_long` | 按整段路径现有规则 |

## 4. 键盘

- `KeyboardViewModel.refresh()`：录音中（`.keyboardRecording`）也读 `PartialTranscriptStore.latest(for: sessionID)`，现在只在 `.transcribing` 时读。
- `updatePartialPreview()`：显示条件从 `hasFullAccess && isTranscribing` 改成 `hasFullAccess && (isKeyboardRecording || isTranscribing)`。位置不变：品牌行右侧，15pt，单行，从头截断，高度不变。录音时的波形在动作按钮里，不冲突。
- 刷新频率不变：录音中计时器每 0.05 秒画波形，每 0.25 秒读一次状态和预览文件。App 最多每秒写 4 次，正好对上。
- 预览从不插入。最终文字仍只经 `SharedTranscriptStore.latest` 和 `KeyboardAutoInsertStore.claimForInsert` 插入一次，App 先清预览再发布最终结果（现有顺序）。
- 预览文件按麦克风会话 ID 区分，不按片段区分。所以 App 每段开始时清空预览，并只发布当前片段的 `partial`，免得上一段的文字闪现。
- 键盘片段本来就需要完全访问（命令和文字都走 App Group），不用另做判断。
- VoiceOver 沿用 “Heard so far”，不主动播报每次变化。
- 截图检查：录音中带预览，浅色/深色 × 320/390/768 宽。

## 5. 电量与流量

连接只存在于单个片段内，开始时连、结束就关。12 小时或 Forever 的麦克风会话空闲时，只有现在已有的连续录音，没有任何额外网络。

### 5.1 流量

| 项目 | 每分钟语音 |
|---|---|
| 实时上行（24 kHz 16 位 PCM） | 2.88 MB，加协议开销约 3.0 MB |
| 现在整段上传的 m4a（AAC 32 kbps） | 0.24 MB |
| 后端到 OpenAI（base64，服务器出站，不算用户流量） | 3.84 MB |
| 预览下行 | 很少（至多 500 字，有变化才发，每秒最多 4 次） |

实时成功时不再上传 m4a；兜底时两份都要传。

| 每天实时时长 | 每天 | 每月 |
|---|---:|---:|
| 10 分钟 | 约 30 MB | 约 0.9 GB |
| 30 分钟 | 约 90 MB | 约 2.7 GB |
| 60 分钟 | 约 180 MB | 约 5.4 GB |

以后可以省流量：App 发 16 kHz、后端重采样（省三分之一）；或 App 编 Opus、后端解码（约省九成，但服务器要多做解码，App 要编码器）。第一版不做。

### 5.2 电量（估算，待真机实测）

增加的耗电 ≈ 片段时长 × 无线电功率，再加少量 CPU：

- 蜂窝网络持续上行约 1–1.5 W（信号差时更高），Wi-Fi 约 0.2–0.4 W，引擎采集和转换约 0.05–0.1 W。
- 按电池约 13.5 Wh 算，每天实时 10 分钟：蜂窝约多 1.4–2.0%，Wi-Fi 约 0.4–0.6%。
- 现在每段也要上传一次，只是时间短；实时把这次短上传换成了说话期间的持续上传。上传结束后无线电还要保持一会儿，这部分两者差不多。

设置和测量：

- 遵守低数据模式（`allowsConstrainedNetworkAccess = false`），低数据模式下直接走整段上传。
- 可选“仅 Wi-Fi 时实时预览”（`allowsExpensiveNetworkAccess = false`），默认值由运营者决定。
- 低电量模式下不开实时。
- 用 Xcode 的能耗工具和 Instruments 测；TestFlight 上用 MetricKit 收网络传输、蜂窝信号和 CPU 数据。

## 6. 隐私政策

有三处事实变了：

1. **发送时机**：现在是停止后上传整段；实时是说话时就持续发送这段的音频。空闲音频仍然从不发送，这一点不变。
2. **取消**：取消的片段，音频已经被我们的服务器和 OpenAI 处理过，只是不保存文字、不扣费。
3. **OpenAI 留存**：OpenAI 的 “Your data” 页按端点列出留存。`/v1/realtime` 有 30 天的滥用监控留存，`/v1/audio/transcriptions` 没有。两者都可以申请零数据留存（ZDR），需要 OpenAI 批准。也就是说，开了实时，发给 OpenAI 的音频会多一个 30 天留存，除非申请到 ZDR。

`docs/PRIVACY_POLICY.md` 建议改法（英文由运营者定稿）：

- “How transcription works” 加一段：

  > If you turn on Live preview, audio from a clip you start is streamed to our backend while you speak, and our backend forwards it to OpenAI so text can appear before you finish. Streaming starts when you start a clip and stops when the clip finishes; idle audio is never streamed. If you cancel a clip, audio already streamed has been processed, but no transcript is kept and you are not charged. Live preview uses about 3 MB of mobile data per minute of speech.

- 数据表 “Audio you record” 一行的 Kept 列补：`With Live preview, a clip is streamed while you speak.`
- “Third parties → OpenAI” 补：

  > Live preview uses OpenAI's Realtime API. OpenAI may retain Realtime API content for up to 30 days for abuse monitoring unless zero data retention applies.

  如果申请到 ZDR，改成相应说法。发布前再核对一次 OpenAI 当时的文档。
- “Microphone” 一条补：`With Live preview, the clip is streamed while it is in progress.`
- 更新 “Last updated”。
- `docs/APP_REVIEW_NOTES.md` 讲音频去向的那句后补：`With Live preview on, audio of a clip the user starts is streamed during the clip.`
- App 内：第一次打开实时预览时，说明流量、发送时机和每分钟价格。首页那句 “Only clips you start are sent for transcription” 仍然成立，不用改。
- App Store 隐私标签：数据类型和用途不变（音频，用于 App 功能），预计不用改，提交前核对。
- `OpenAI-Safety-Identifier`（官方建议的、不暴露身份的终端用户标识）：第一版不发。如果要发，用用户 ID 的密钥哈希，并写进政策。

## 7. 服务器容量

### 7.1 名额

- 现在 `MAX_CONCURRENT_TRANSCRIPTIONS` 默认 2（限制在 1–4），不排队，满了回 503。整段转写每次只占约 2–3 秒。
- 实时会话从开始说话一直占到收尾，30 秒的片段约占 31 秒，约是整段路径的 10 倍，不能共用这 2 个名额。
- 新增 `MAX_CONCURRENT_REALTIME_SESSIONS`，默认 8，范围 1–32。满了回 `busy`，App 静默走整段上传，只是没有预览，不算失败。
- 中继主要是 I/O：每路进 48 KB/s、出 64 KB/s（base64）。8 路约 0.9 MB/s，16 路约 1.8 MB/s。CPU 主要花在 base64 和 JSON 上，估计每路不到 1%。每路内存最多约 2–3 MB（上游就绪前的缓冲至多 480 KB，加收发队列）。实时中继不跑 ffmpeg（后端直接数 PCM 字节）。真正紧张的是共享的约 0.5 vCPU 持续配额、已经在用 swap 的内存，以及兜底时的 ffmpeg 解码。

### 7.2 预览被挤掉的比例（Erlang B）

沿用 `docs/CAPACITY_2026-10-02.zh-CN.md` 的假设：每人每天 20 段、每段 30 秒，20% 集中在最忙的一小时。被挤掉只是没有预览，转写照常。

| 日活 | 负载（Erlang） | 4 路 | 8 路 | 12 路 | 16 路 | 24 路 | 32 路 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 50 | 1.67 | 6.24% | 0.03% | 0 | 0 | 0 | 0 |
| 100 | 3.33 | 24.26% | 1.36% | 0.01% | 0 | 0 | 0 |
| 200 | 6.67 | 50.94% | 15.97% | 2.09% | 0.09% | 0 | 0 |
| 500 | 16.67 | 77.60% | 56.11% | 36.30% | 19.57% | 2.03% | 0.03% |

“0” 表示小于 0.005%。100 日活以内 8 路够用；200 日活要 12–16 路；500 日活要 24 路以上，那时也该升级机器或把实时中继单独部署。现在实际只有 1 位活跃用户，中位片段约 2 秒。

### 7.3 WebSocket 不经过现有的 HTTP 中间件

`RequestBodyLimitMiddleware` 和限流中间件只处理 HTTP，WebSocket 路由要自己限制：

- 每用户每 60 秒最多约 30 次 `start`；认证失败按 IP 限流。
- 单帧不超过 32 KB；PCM 总量不超过 600 秒 × 48,000 = 28.8 MB。
- 推流速度不超过实时的 1.5 倍，允许约 15 秒的突发（App 连上后补发缓冲）。
- commit 前 15 秒没有音频就断开；从 `start` 起最长 660 秒；commit 后最多等 30 秒。
- 每个用户最多 1 路推流中加 1 路等结果。
- 日志不记文字和音频，只记用户 ID、请求 ID、模型、秒数、结果码、上游错误码。上游的原始错误信息不转给 App。

### 7.4 事件循环

数据库是同步的（psycopg 连接池），现有异步路由直接在事件循环里调用。ffmpeg 测时长已经是异步子进程，没有问题。中继对停顿很敏感：一次在 `lock_user` 上等锁的查询，会让所有正在转发的连接一起卡住。所以实时路由里的数据库操作全部放进 `run_in_threadpool`，收尾的释放要用 shield，保证连接被取消时也能执行。整段路径的数据库调用以后也可以挪进线程池，不在本次范围。

### 7.5 uvicorn 和 Docker

- uvicorn 参数：`--ws-max-size 65536`（默认 16 MiB）、`--ws-per-message-deflate false`（压缩 PCM 不划算，白费 CPU）、`--ws-ping-interval 20 --ws-ping-timeout 20`（与默认相同，写明）。
- 上游连接用 `websockets` 库。它现在是被 `uvicorn[standard]` 间接装上的（本地是 15.0.1），要在 `requirements.txt` 里固定版本。
- Dockerfile 把 `sh -c "uvicorn …"` 改成 `exec uvicorn …`，保证 SIGTERM 送到 uvicorn。流式转写的交接里已经把这一点列为待确认。

### 7.6 Caddy

- `reverse_proxy` 自动处理 WebSocket 升级，不用额外配置。
- `encode zstd gzip` 遇到带 `Sec-WebSocket-Key` 的请求会跳过（看过 Caddy 源码）。
- Caddy 重载配置时，默认会关闭已升级的连接；设了 `stream_close_delay` 才会推迟关闭。这台机器上还有其他站点，改其他站点也会触发重载。建议在 VoiceType 的 `reverse_proxy` 里加 `stream_close_delay 10m`，比片段上限长。
- `stream_timeout` 默认不设，不会主动断开长连接。
- 线上实际使用 `/opt/voicetype/config/Caddyfile`，可能和仓库模板 `deploy/gcp-vm/Caddyfile.https` 不同。上线前由运营者核对，并确认没有给 server 设读写超时。本次没有连线上。

## 8. 分阶段计划

| 阶段 | 内容 | 完成标准 |
|---|---|---|
| 0 决策（约半天） | 运营者回答第 10 节；在 OpenAI 控制台确认项目能用 gpt-live-transcribe，以及 Realtime 的并发和速率上限；决定是否申请 ZDR；核对线上 Caddyfile | 决定写进本文 |
| 1 后端（约 3–4 天） | `backend/realtime.py` 和路由；v3 认领和接管规则；追加预留；`realtime_committed_at` 列；启动清理；`MODEL_PRICING` 加 live 模型；目录加 `realtime` 字段；新配置项；ws 参数和 `exec uvicorn`；仓库 Caddy 模板加 `stream_close_delay`；`.env.example` 和运维文档 | 新测试全部通过；开关关闭时现有后端测试结果不变 |
| 2a iOS 键盘（约 4–6 天） | PCM 采集、`RealtimeTranscriptionClient`、RecordingController 接入、键盘录音中预览、设置开关（目录说可用才显示）、低数据和低电量处理 | 单元测试和截图测试通过；不做真实转写 |
| 3 测试环境和真机（约 3–5 天） | 独立测试服务器，配独立的 OpenAI 项目和预算上限；测试版 App 要能指向它（Debug 版现在连生产，不能拿来测）。TestFlight 真机测：后台启动引擎、录音有无杂音、开头是否被截、流量和电量、切换网络、低数据模式、10 分钟片段、Caddy 重载。约 50 段录音（中文、英文、中英混合，安静和嘈杂）比较 live 和 gpt-transcribe 的准确率 | 测量结果写进本文；准确率可以接受 |
| 4 上线 | 先部署后端（开关关闭）；先发布隐私政策和审核说明；发布 App；`REALTIME_ALLOWED_USER_IDS` 只放运营者；再逐步扩大 | 回滚 = 关开关，App 自动走整段上传 |
| 2b App 内录音（可选） | 首页录音也用实时 | 运营者决定 |

工期是粗估，不含 App Store 审核时间。

> 进度（2026-10-24）：第 1、2a、2b 阶段已写完，测试用 mock；第 0 阶段已决定的事项见第 10 节的注。第 3 阶段没有开独立测试服务器：按用户安排，后端部署后直接在 TestFlight 上测。第 4 阶段没有按白名单逐步开放：总开关默认开，所有人都能在设置里选 Live。

新增配置（都在后端 `.env`，默认值不改变现有行为）：

> 以下是设计稿。实际的配置项、默认值和目录字段见 13.2：总开关默认开，没有每日未计费上限，多了 `REALTIME_RATE_LIMIT_PER_WINDOW`。

| 变量 | 默认 | 说明 |
|---|---|---|
| `REALTIME_TRANSCRIPTION_ENABLED` | `false` | 总开关 |
| `REALTIME_TRANSCRIPTION_MODEL` | `gpt-live-transcribe` | 实时模型 |
| `MAX_CONCURRENT_REALTIME_SESSIONS` | `8` | 1–32 |
| `REALTIME_UNCHARGED_SECONDS_PER_DAY` | `300` | 每人每天未计费实时秒数上限 |
| `REALTIME_ALLOWED_USER_IDS` | 空 | 非空时只对这些用户开放 |

模型目录 `GET /v1/transcription/models` 加 `realtime: {available, model, name, credit_units_per_minute, formatted_per_minute}`。这个接口不需要登录，所以 `available` 只反映总开关；白名单和每日上限在连接时检查，不符合就回 `disabled`，App 静默走整段上传。旧 App 解码时忽略未知字段。

实现时要动的文件：

- 后端：`backend/realtime.py`（新）、`backend/main.py`、`backend/requirements.txt`、`backend/Dockerfile`、`backend/.env.example`、`backend/tests/test_realtime.py`（新）。
- 部署：`deploy/gcp-vm/Caddyfile.https`（线上文件由运营者同步）。
- iOS：采集和客户端（新文件，放在 `VoiceType/Services/`）、`RecordingController.swift`、模型目录解码（`Shared/APIModels.swift`、`TranscriptionModelCatalogStore`）、设置页、`KeyboardViewController.swift`，以及对应测试。
- 文档：`docs/PRIVACY_POLICY.md`、`docs/APP_REVIEW_NOTES.md`、`docs/OPERATIONS.zh-CN.md`、`README.md`。

## 9. 离线测试方案

### 9.1 后端（pytest，不联网）

- 上游可替换：`realtime.open_upstream(settings)` 返回一个连接对象，测试里 monkeypatch 成假上游，按脚本回事件（会话已配置、若干 delta、completed 加 usage），也可以注入 `error`、`failed`、超时和断开。
- 用 Starlette 的 `TestClient.websocket_connect(..., headers=..., subprotocols=[...])` 走完整协议；复用 `test_billing` 的 `auth`、`load_main`，`test_reliability` 的 `fund`，以及 `test_streaming` 的 `ledger`。
- 用例：
  1. 正常：ready → partial → done；账本恰好一条 `transcription:{id}`；预留清零；认领已完成；done 的 JSON 与整段上传相同。
  2. 认证失败、开关关闭、不在白名单、超过每日上限：拒绝，不建认领。
  3. 余额不足 → `insufficient_credit`；追加失败 → `credit_exhausted` 并释放。
  4. 名额满 → `busy`。
  5. commit 前断开或 cancel：不扣费，认领删除，计入未计费秒数。
  6. commit 后断开：照常结算；之后同 key 整段上传返回保存的结果，供应商没被调用，不再扣费。
  7. 上游 `error`、`failed`、超时、配置被拒 → `provider_error`，不扣费。
  8. 接管：推流中同 key 整段上传 → 实时被 `superseded`，只按整段价扣一次；commit 后、完成前上传 → 409 + Retry-After；实时完成后上传 → 保存的结果；时长或 context 不符 → 409。用线程 Event 控制假上游的时序。
  9. 同一用户第二次 `start`：旧的推流会话被中止。
  10. 限制：超大帧、推得太快、超过 28.8 MB、空闲 15 秒、墙钟上限。
  11. `no_speech`；时长对不上 → `fallback_required`。
  12. 关机：推流中的会话被关闭并释放；启动时清理未完成的 v3 认领。
  13. 目录的 `realtime` 字段；不认识它的旧客户端不受影响。
  14. 日志里没有文字和音频。
  15. 上游地址由 `base_url` 推出（https → wss）。

### 9.2 iOS（XCTest，QA 模拟器，不联网）

- URLProtocol 不适合模拟 `URLSessionWebSocketTask`，所以加一个 `RealtimeTranscriptionTransport` 协议，测试用脚本化的假实现。
- PCM 转换：输入 48 kHz Float32 正弦波，检查输出为 24 kHz Int16、每帧 4,800 字节、幅度正确；44.1 kHz 和 16 kHz（蓝牙）输入也测。
- RecordingController（利用现有的 `transcriptionRequest`、`audioSessionActivation` 等测试接口）：
  - 只发布当前片段的 partial；
  - done 只发布一次，且先清预览；
  - error、断开、commit 后超时 → 用同一个 requestID 走整段路径；
  - 兜底开始后迟到的 done 被丢弃；
  - 取消 → 不发布；片段短于 0.25 秒 → 发 cancel；
  - 积压超过 5 秒 → 放弃实时；
  - 路由变化、中断 → 本段放弃实时，录音照常；
  - 低数据模式、低电量、目录不可用 → 不开连接；
  - 整段上传遇到 409 + Retry-After → 自动重试。
- 键盘（`KeyboardLifecycleTests`）：录音中显示预览，没有预览时隐藏；最终文字只插入一次；截图浅色/深色 × 320/390/768。
- 模拟器上不做真实转写（Debug 版连的是生产）。

## 10. 需要运营者决定的问题

1. **模型和价格**
   - A（推荐）：live 模型，按实时价收 29,144 积分/分钟，用户自己打开“实时预览”时看到价格。
   - B：live 模型，按用户所选整段模型的价格收，差价自己承担。相对 gpt-transcribe 每分钟亏约 $0.0093；100 日活 × 每天 10 分钟，每月约 $280。
   - C：gpt-transcribe 走 Realtime 并开静音检测。按文档，非 live 模型要等一段话提交（静音检测或手动提交）后才出这段文字，也就是停顿后一句一句出；价格和整段相同。要处理多条目排序，体验要先做原型。
   - **决定：A，按实时价收费（用户，2026-10-24）。** 另外按用户“模型可选”的要求，Live 里也能选 gpt-transcribe（停顿后出字，接近 C，由服务端检测停顿后提交），按它的实时价 7,715 积分/分钟收费。
2. 默认开还是关；对谁开（只有运营者、白名单，还是所有人都能在设置里自己打开）。
   - **实现：** 默认模式是 Streaming，所有人都能在设置里自己选 Live；服务端开关默认开，白名单默认空。
3. 最终文字用实时模型的结果（推荐：快，只付一次），还是停止后用 gpt-transcribe 整段重转（可能更准，但供应商要付两次钱）。
   - **实现：** 用实时模型的结果。
4. 蜂窝网络下默认允许实时吗？要不要提供“仅 Wi-Fi”。
   - **实现：** 蜂窝网络下允许，只在低数据模式下改为上传；没有“仅 Wi-Fi”选项。
5. 是否接受承担失败和取消的实时费用（估计每人每月约 $0.26）；每日未计费上限定多少（建议 300 秒）。
   - **决定：不承担（用户，2026-10-24）。** 未完成的会话按已发音频收实时价，所以也没有每日未计费上限，见 13.3。
6. 隐私：政策措辞；是否申请 ZDR；是否发 `OpenAI-Safety-Identifier`。
   - **决定：不申请 ZDR（用户，2026-10-24）**，隐私政策写明 OpenAI 最多留存 30 天。没有发 `OpenAI-Safety-Identifier`。政策英文措辞已写进 `docs/PRIVACY_POLICY.md`，发布前由运营者核对。
7. 容量：实时名额（建议从 8 开始）；什么时候升级机器，或把同机的其他服务挪走。
   - **实现：** 默认 8 路。何时升级机器仍待定。
8. 测试环境：要不要开一台测试服务器和独立的 OpenAI 项目，预算多少。
   - **按用户安排：** 不开测试服务器，后端部署后直接在 TestFlight 上测。
9. Caddy：同意加 `stream_close_delay 10m` 吗；其他站点的重载放在什么时间。
   - **实现：** 没有改 Caddy，仍待定。重载会切断进行中的 Live 会话，按断开收费，App 改为上传。
10. 开始实时的最低余额（建议 29,144，即 1 分钟）；不够就只走整段上传。
    - **实现：** 开始时要能预留 max(20,000, 1 分钟实时价)：gpt-live-transcribe 是 29,144，gpt-transcribe 是 20,000。不够回 `insufficient_credit`，App 改为上传。
11. `delay` 参数的文档不一致：先不设，等 OpenAI 澄清或实测后再说。
    - **实现：** 没有设。
12. App 内录音（2b）要不要做。
    - **实现：** 做了，首页录音也跟随同一个设置。

## 11. 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| gpt-live-transcribe 很新，文档有不一致；delta 怎么修正、单条目长到 10 分钟时的表现都没写 | 预览跳动，长片段失败 | 后端负责累积；第 3 阶段实测；失败自动走整段 |
| 断开时未提交的音频收不收费没写 | 运营者成本 | 按收费估算；每日上限 |
| Realtime 的速率和并发上限未知 | 高峰时实时被拒 | 第 0 阶段确认；被拒就走整段 |
| 后台启动 AVAudioEngine，以及它和 AVAudioRecorder 共存 | 录音出现杂音或断点 | 第 3 阶段真机验证；不开语音处理；不行就改 S3 或单一引擎 |
| 引擎启动慢，开头被截 | 实时文字缺开头 | 时长核对后走整段；必要时用 S3 预缓冲 |
| 流量和电量投诉 | 差评 | 只在片段内连接；低数据、低电量自动关闭；“仅 Wi-Fi” 选项；App 内说明 |
| 单价是 gpt-transcribe 的 3.8 倍 | 用户嫌贵 | 默认关闭、自愿打开、显示价格；或改用方案 C |
| 小机器加同步数据库，卡住事件循环 | 所有连接一起卡 | 线程池；独立名额；监控 |
| Caddy 重载或部署切断会话 | 这段没有实时结果 | `stream_close_delay`；自动兜底；避开高峰部署 |
| OpenAI 30 天留存 | 隐私承诺改变 | 改政策；考虑 ZDR |
| 兜底竞态让供应商重复收费 | 运营者成本 | commit 后上传先等待（409）；用户只付一次 |
| WebSocket 绕过 HTTP 中间件 | 滥用、内存压力 | 路由内限制（7.3） |
| 被改过的客户端 | 白看预览 | 每日上限；commit 后照常结算 |
| v3 指纹不含音频 | App 的 bug 若重用 key，可能拿到别的片段的结果 | 核对时长和 context；key 每段新建 |

## 12. 未核实

- 没有调用 OpenAI 或生产后端。事件名、usage 格式和价格都来自官方文档，没有实测。
- 电量和流量是估算。
- 线上 Caddyfile 的内容（Caddy 2.11.4，`encode zstd gzip`，`reverse_proxy backend:8080`）是部署会话转述的，本会话没有直接看。
- 容器里 uvicorn 由 `sh -c` 启动，SIGTERM 能不能传到 uvicorn 没有验证。传不到时，Docker 10 秒后强制停止，连接直接断开，启动清理释放预留，不收费。

实现之后仍未验证（2026-10-24，都要在 TestFlight 真机上看）：

- AVAudioEngine 的输入 tap 和 AVAudioRecorder 同时运行，以及 App 在后台时启动引擎：录音有没有杂音或断点，开头会不会被截。
- `URLRequest` 带的子协议头、Caddy 对 WebSocket 的转发、低数据模式下改为上传。
- OpenAI 的真实事件和延迟；停顿提交的阈值（700 毫秒、长段 30/60 秒和 20/40 秒）是否合适；多段结果的拼接。
- 路由变化（比如切换蓝牙耳机）时引擎的行为，见 13.5。
- 本地测试用 Python 3.9.6、websockets 15.0.1、starlette 0.49.3，线上是 Python 3.12.14、websockets 17.1、starlette 0.50.0。

## 13. 实现与设计的差异

本节记录 2026-10-24 写完的代码和上面的设计不一样的地方，没列出的部分按设计实现。功能在 App 里叫 **Live**，不叫 “Live preview”。

### 13.1 用户可选的模式和模型

用户要求模型和交互方式都能自己选，所以设计里的“实时预览开关”变成了三种模式。设置 → Transcription mode & model：

| 模式 | 做法 |
|---|---|
| After recording | 停止后上传，文字一次出现 |
| Streaming（默认） | 停止后上传，边转写边出字（现有 SSE 路径） |
| Live | 说话时就发送音频，边说边出字，更贵 |

- 键盘和首页录音都跟随这个选择（第 2b 阶段也做了）。
- 选 Live 后多一个 “Live model” 分组：Automatic（默认，用服务端默认模型）、gpt-live-transcribe（说话时出字）、gpt-transcribe（停顿后一句一句出）。
- 原来的模型分组在 Live 下改名为 “Upload model”，只在 Live 用不了、要整段上传时使用。
- 选了 Live 但用不了（模型目录还没加载，或服务端说不可用）时，模式分组下方说明原因，录音改为停止后上传并边转写边出字。
- 选的 Live 模型服务端不再提供时，按服务端默认模型处理。
- 没有做“第一次打开时的说明”。Live model 分组下方的说明在选择时就能看到，写了：约 3 MB/分钟；已发的音频按实时价收费，取消或断开也收；Live 完成不了时还会按上传模型再收一次；低数据模式下改为上传；OpenAI 可能把 Live 音频保留最多 30 天。

### 13.2 开关和配置

实际的配置项，替代第 8 节的表：

| 变量 | 默认 | 说明 |
|---|---|---|
| `REALTIME_TRANSCRIPTION_ENABLED` | `true` | 总开关。关掉后目录显示不可用，App 改为上传 |
| `REALTIME_TRANSCRIPTION_MODEL` | `gpt-live-transcribe` | 用户选 Automatic 时用的模型。只能是 `gpt-live-transcribe` 或 `gpt-transcribe`，其他值按默认处理 |
| `MAX_CONCURRENT_REALTIME_SESSIONS` | `8` | 1–32 |
| `REALTIME_ALLOWED_USER_IDS` | 空 | 空表示所有人；非空时只对这些用户开放 |
| `REALTIME_RATE_LIMIT_PER_WINDOW` | `30` | 每个用户每 `RATE_LIMIT_WINDOW_SECONDS` 最多开始多少次 |

- 总开关默认开，因为要在 TestFlight 上让用户自己选。旧 App 不认识新字段，不受影响。
- 没有 `REALTIME_UNCHARGED_SECONDS_PER_DAY`。未完成的会话照样收费（13.3），不需要每天的免费上限。
- Live 的价格单独放在 `REALTIME_PRICING`（每分钟 17,000 和 4,500 微美元，加价后 29,144 和 7,715 积分），没有加进 `MODEL_PRICING`。所以 gpt-live-transcribe 不会出现在整段上传的模型列表里。
- 目录 `GET /v1/transcription/models` 的字段是 `realtime: {available, default_model, models: [...]}`，每个模型带 `id`、`name`、`recommended`、`live_only`、`text_timing`（`while_speaking` 或 `after_pauses`）、`retires_on`、`pricing_basis`、`credit_units_per_minute`、`formatted_per_minute`。设计里只有一个模型。
- 目录不需要登录，`available` 只看总开关和服务商密钥，不看白名单。设了白名单时，名单外的用户也会看到 Live 可选；开始时收到 `realtime_unavailable`，App 改为上传，并在重启前不再尝试。

### 13.3 计费

按用户的决定（第 10 节问题 1 和 5），和设计相比改了两处：

- **未完成也收费。** 设计是中途断开、取消、出错都只释放预留，不扣费。实现是：取消、App 断开、App 发来格式不对的消息、超时、供应商出错、余额用完、被新的 Live 会话或同 key 的整段上传接管、时长对不上（`fallback_required`）、超过 600 秒，都按已发给 OpenAI 的秒数收实时价。秒数取 max(转发秒数, OpenAI 返回的秒数)，按余额封顶。账本描述是 `<模型> live transcription (unfinished)`，`source_id = realtime:{会话 ID}`，不保存文字。
- **只有三种结局不收费：** `no_speech`、`server_restarting`、`internal_error`。`server_restarting` 只在服务端收到 SIGTERM 或 SIGINT 之后才算。没有收到停止信号时，App 自己发来的 1012 按 `disconnected` 收费，免得被当成免费通道。
- **兜底时收两次。** Live 没完成、录音再整段上传时，Live 已发的音频按实时价收一次，整段上传按上传模型再收一次。设计里用户只付一次，差额由运营者承担。

其他：

- 开始前就被拒（繁忙、限流、余额不足、key 已用、不可用）不收费，因为还没有音频发出。
- 完成的片段最少按 1 秒收费；未完成的按实际秒数，没发出音频就是 0。
- 开始时预留 max(20,000, 1 分钟实时价)：gpt-live-transcribe 29,144，gpt-transcribe 20,000。之后预留始终比已发的音频多 15 秒，每次至少追加 1 分钟的价。
- 追加预留只改 `credit_reservations`，不刷新认领的 `updated_at`。未提交的 v3 认领总是被整段上传接管，不靠 `updated_at` 判断。
- 完成后的账本描述是 `<模型> live transcription`，`source_id = transcription:{id}`，和整段上传一样。

### 13.4 协议

- `start` 是 `{"type":"start","format":"pcm_s16le_24000_mono","model":…,"language":…,"preferred_languages":…,"vocabulary":…}`。后三项是 JSON 文本，和整段上传的表单字段一样，用同一套校验，长度上限分别是 32、256、16,000 字符，`model` 是 128。App 不发 `language`，只发首选语言和词表。
- `ready` 带 `session_id`、`model`、`text_timing`、`credit_units_per_minute`。设计里是 `request_id`。
- 没带子协议或登录无效时，握手前就关闭（1008）。App 看到的是 HTTP 403，当作旧服务端，直接上传。
- 错误码：设计的 `disabled` 改名为 `realtime_unavailable`；新增 `timeout`、`disconnected`、`cancelled`、`invalid_request`、`unsupported_model`、`rate_limited`、`unauthorized`、`internal_error`。
- 关闭码：`done` 和取消是 1000，状态码 500 以上是 1011，其他是 1008。
- **分段提交。** 设计是只在停止时提交一次。实现里 `turn_detection` 仍是 null，由后端检测停顿后分段提交：
  - gpt-transcribe：停顿 700 毫秒就提交（这段至少 1 秒，其中语音至少 0.3 秒），所以停顿后一句一句出字。
  - 两个模型都会切开长段：gpt-live-transcribe 满 30 秒后遇到 0.25 秒停顿就提交，满 60 秒强制提交；gpt-transcribe 是 20 秒和 40 秒。
  - 各段的结果可能乱序到达，后端按顺序拼接，中日韩文字之间不加空格。
  - 停止时，最后一段只有静音就清掉、不提交；OpenAI 回“缓冲区为空”也不算失败。
- 数值调整：

| 项目 | 设计 | 实现 |
|---|---|---|
| 上游就绪前后端最多缓存 | 10 秒 | 20 秒 |
| 时长对不上（改为上传）的判断 | 转发的秒数比 App 报的时长少 0.5 秒以上 | 收到的秒数少 1.0 秒以上 |
| 同 key 整段上传返回保存的 Live 结果，时长最多相差 | 1.5 秒 | max(2 秒, 10%) |
| App 等 409 + Retry-After 最多 | 35 秒 | 40 秒（后端在提交后 35 秒内回 409） |

### 13.5 App 和键盘

- 停止后等 Live 结果 15 秒。设计是 10–20 秒，按片段长短。
- 发送积压上限是 100 帧，即 10 秒。设计是 5 秒。
- 收到 `realtime_unavailable` 或 `unsupported_model` 后，这个用户在 App 重启前不再尝试 Live，直接上传。
- `no_speech`：设计是一律再整段上传确认。实现里，只要采到过非零的声音，就相信它，按无语音处理；一点声音都没采到（可能是采集出了问题）时，才整段上传确认。
- 只遵守低数据模式（`allowsConstrainedNetworkAccess = false`）。没有做低电量模式下关闭 Live，也没有“仅 Wi-Fi”选项。
- 预览只在发布最终文字前清掉（先清预览、后发布，和设计相同）。设计是放弃实时时就清掉预览；实现里 Live 中途失败时，预览停在最后收到的文字；停止后改为上传时，支持流式的上传模型会用自己的文字替换它，whisper-1 则一直显示到结果出来。
- 路由变化：和现在一样，只有设备断开（`oldDeviceUnavailable`）或没有可用路由时结束录音；其他路由变化没有为 Live 特别处理。引擎如果因此停下，后端发现音频不够或 15 秒没有消息，就结束会话（收费），App 改为上传。没有真机验证。
- 引擎用 S1：片段开始时启动，结束时停止。
- 停止时先把录音段存成恢复记录，再等 Live 结果；m4a 只在要整段上传时才导出。设计是停止时总是导出。

### 13.6 服务器和部署

- 没改 `requirements.txt`。线上镜像里 `uvicorn[standard]` 带的 websockets 是 17.1，够用。
- Dockerfile 只在 COPY 里加了 `realtime.py`。启动命令仍是 `sh -c "uvicorn …"`，没有改成 `exec`，也没有加 `--ws-max-size` 等参数；单帧 32 KB 的上限由路由自己检查。
- `realtime.py` 是新文件。如果部署只覆盖改过的 `.py` 文件，要和 `main.py` 一起放上去。
- 没改 Caddy，没加 `stream_close_delay`。Caddy 重载会切断进行中的 Live 会话，按 `disconnected` 收费，App 改为上传。
- 后端把自己的信号处理串在 uvicorn 的前面：收到 SIGTERM 或 SIGINT 时先设停止标记，再交给 uvicorn 关机。只有设了标记，1012 才算 `server_restarting`。
- 数据库调用仍在事件循环里同步执行，没有放进线程池，收尾也没有 shield，和整段路径一样。一次慢查询会让所有 Live 连接一起停顿；现在用户很少，先不改。服务端取消会话时在 `finally` 里释放预留，不收费。
- 仍是单进程。启动时删除所有未完成的 v3 认领和 `kind = 'realtime'` 的预留，不收费。`realtime_committed_at` 列在启动时按需添加，可以重复执行。
- 没有做运营后台的活跃会话视图。看有没有进行中的会话，按 `credit_reservations.kind` 统计，命令见运维文档。
- 账号在会话中被删除时，收尾不报错。

### 13.7 隐私

- 不申请 ZDR，也不发 `OpenAI-Safety-Identifier`（第 10 节问题 6）。
- `docs/PRIVACY_POLICY.md` 已写明：Live 在说话时发送音频；空闲音频从不发送；取消的片段已被处理且照样收费，但不保存文字；完成不了时改为上传；约 3 MB/分钟；低数据模式下不用 Live；OpenAI 最多保留 30 天。发布带 Live 的 App 之前，要先重新发布公司网站上的隐私页。
- `docs/APP_REVIEW_NOTES.md` 加了一条检查项：提交的构建包含 Live 时，更新给审核员的说明。

## 参考资料

- [OpenAI：Realtime 转写指南](https://developers.openai.com/api/docs/guides/realtime-transcription)：`intent=transcription`、会话配置、delta 和 completed、手动提交、keywords 和 languages 的规则、`delay`。
- [OpenAI：gpt-live-transcribe](https://developers.openai.com/api/docs/models/gpt-live-transcribe)：价格、收到音频就出字、不带静音检测、只用于 Realtime 转写会话。
- [OpenAI：gpt-transcribe](https://developers.openai.com/api/docs/models/gpt-transcribe)：价格，整段和 Realtime 都可用。
- [OpenAI：gpt-realtime-whisper](https://developers.openai.com/api/docs/models/gpt-realtime-whisper)：`delay` 和 turn_detection 的限制。
- [OpenAI：Realtime 服务器事件](https://developers.openai.com/api/reference/resources/realtime/server-events)：delta、completed（含 usage）、failed、committed，以及 completed 可能乱序。
- [OpenAI：创建 client secret](https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create)：有效期 10–7200 秒（默认 600）、过期前可开多个会话、客户端可改配置。
- [OpenAI：转写会话参数](https://developers.openai.com/api/reference/resources/realtime/subresources/transcription_sessions/methods/create)：languages、keywords、delay 适用的模型。
- [OpenAI：价格](https://developers.openai.com/api/docs/pricing)：各模型每分钟价格；没有写断开时未提交的音频是否计费。
- [OpenAI：Your data](https://developers.openai.com/api/docs/guides/your-data)：各端点的留存和 ZDR。
- [OpenAI：Realtime WebSocket](https://developers.openai.com/api/docs/guides/realtime-websocket)、[WebRTC](https://developers.openai.com/api/docs/guides/realtime-webrtc)、[会话](https://developers.openai.com/api/docs/guides/realtime-conversations)：服务器端用 WebSocket、移动端建议 WebRTC、`OpenAI-Safety-Identifier`、会话时长上限。
- [OpenAI：企业隐私](https://openai.com/enterprise-privacy/)：隐私政策里现有的链接。
- [Caddy：reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)：WebSocket、`stream_close_delay`、`stream_timeout`。
- [Caddy 源码：encode.go](https://raw.githubusercontent.com/caddyserver/caddy/master/modules/caddyhttp/encode/encode.go)：WebSocket 请求不压缩。
