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

线上配置：官方 OpenAI 地址，`gpt-4o-mini-transcribe`，`COST_MARKUP_BPS=7143`；开发赠送接口关闭。`gpt-4o-mini-transcribe` 将于 2027-02-26 停用；代码默认值已改为 `gpt-transcribe`，线上切换在模型管理后台测试后保存（见 [OWNER_CONSOLE.zh-CN.md](OWNER_CONSOLE.zh-CN.md)）。用户使用余额与运营者的 API 账单是不同的账本。`/health/ready` 只检查密钥是否存在，不证明密钥有效或还有余额。

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

- 设置中的 “Learn from my corrections” 默认开启。关闭后 Edit & teach 只保存修改后的文字，不再给出建议；已保存的词和替换继续生效，直到用户删除。
- 在 History → Edit & teach 中修改一条转写时，App 按词比较前后文字（中文、日文、泰文等不用空格的文字由系统分词），找出改动片段。单字修改会扩展成整个名字：系统识别出人名、地名、组织名时取整个名字；系统不认识的中文名字会被拆成单字，此时连同相邻的单字名词一起学习（最多 4 个字），例如 “龚月” → “龚玥”。
- 建议分两种：“Fixes ‘工月’ in new transcripts” 同时记住正确写法和听错的写法，以后新转写中出现这个听错写法时整词替换；“Helps recognize this word” 只作为识别提示。只有听错的写法不是常用词，或是多词的人名、专有名词时才提供替换，避免把 their → there 这类普通改写变成全局替换。常用词按系统词表判断；设备没有中文词表时按系统分词判断，系统连不成词的单字名词组合（如 “工月”、“曲周”）视为非词。含 “在、了、吗、的、他们” 等虚词或代词的听错写法从不替换，所以 “在见” → “再见” 不会变成替换规则。系统不标注日文词性，日文汉字写法没有词表时只作为不默认勾选的识别提示。纯大小写、空格、标点改动不提示，但 GitHub 这类带内部大写的写法会提示。
- 人名、专有名词、系统词表里没有的词，以及中文等不用空格的文字中替换非词的修正（如 “曲周” → “衢州”）默认勾选。只有用户打开的项会保存，也可以手动补充一个词。单纯复制文字、普通转写成功或在其他 App 中修改文字不会触发学习。
- 替换在本机完成：新转写写入 History、交给键盘插入之前，按整词把听错写法换成正确写法。网址、邮箱、文件名和代码中的文字不改；中文按系统分词判断词边界，所以 “加工月饼” 里的 “工月” 不会被替换。每个词最多 5 个听错写法；同一个听错写法只归属最近一次纠正的词；已作为独立词保存的写法不会被换成别的词。听错写法不发送给服务器。
- Settings → Languages & vocabulary 中点开一个词，可以查看、添加、删除它修正的听错写法，或忘记这个词；左滑也可以忘记。
- 按账号保存在当前设备，不做跨设备云同步。最多 200 条，每条 2–40 字符；每次录音只发送最近最多 50 条正确写法作为识别提示，总长度不超过 1500 字符。重新教同一个词会移到前面，频繁说出某个词不会自动提高它的排序。识别提示仍不能保证每次同音词都正确，替换规则只修正用户确认过的写法。
- 保存修改只更新当前设备 History，不会改变已插入其他 App 的文本。失败录音重试使用当时的原始语言、词表提示和模型。

## 用户选择转写模型

- Settings → Transcription mode & model 先选模式：After recording（录完上传，转写完一次显示）、Streaming（默认，录完上传，边转写边显示，见下节）或 Live（边说边发送，说话时就出字，价格更高，见“Live 实时转写”）。键盘跟随同一设置。
- 模型默认为 Automatic，跟随服务默认模型（线上由运营者在模型管理后台设置）。也可以选择目录中的模型；每个模型显示按时长估算的每分钟额度，实际扣费以每条转写显示的金额为准。
- 模型目录来自无需登录的 `GET /v1/transcription/models`，App 缓存最近一次结果。已停用或不再列出的模型不会发送，录音自动回到 Automatic；服务端也会把已停用的模型换成服务默认模型，未知模型返回 400。
- 新录音使用当时的选择；失败重试沿用录音时的模型，保证幂等和计费一致。目录中的 `streaming` 表示该模型能否边转写边显示文字（见下节）。

## 流式转写（边转写边显示）

- 录音结束后仍上传整段音频。支持流式的模型（`gpt-transcribe`、`gpt-4o-mini-transcribe`、`gpt-4o-transcribe`）在服务端转写的同时，把已识别的文字分段发回。App 首页和正在重试的 History 行显示这些文字（VoiceOver 读作 “Heard so far”）；键盘有完全访问时，在顶部品牌行显示预览，只保留最新的文字，键盘高度不变。`whisper-1` 不支持流式，App 按模型目录直接走普通上传；目录未加载时，服务端只在结束时发回结果。
- 预览是供应商的原始文字，没有经过标点规范化和个人替换。只有最终结果写入 History，并由键盘插入一次，预览从不插入。键盘预览通过 App Group 缓存文件 `Library/Caches/PartialTranscript/partial.json` 传递，带录音会话 ID，只有同一会话的键盘显示。转写完成、失败、取消和退出登录时删除；完成时先删预览，再发布最终结果。
- 协议：App 在 `POST /v1/transcriptions` 的表单中加 `stream=true`，请求头加 `Accept: text/event-stream`。未登录、参数无效、余额不足（402）、服务繁忙（503）、同一 key 仍在转写（409）等转写开始前发现的错误，仍是普通 HTTP 错误，处理方式不变。之后返回 200 `text/event-stream`：
  - `event: delta`，`data: {"delta":"…"}`：下一段文字，按顺序拼接。
  - `event: done`，`data:` 与非流式接口相同的 JSON（`id`、`transcript`、`model`、`charge`、`balance`）。
  - `event: error`，`data: {"status":422,"detail":"…","code":"no_speech"}`：非流式请求会返回的状态码和正文。App 照常处理：`no_speech` 删除录音，其他失败保存在 History。
  - 等待期间每 15 秒发一行注释 `: keepalive`，避免空闲连接被断开。
- 断开与计费：
  - 客户端中途断开（切换网络、信号中断等）不会中止转写。服务端照常完成，按实际费用扣一次，并保存结果。App 把这段录音保存在 History；用同一个 Idempotency-Key 重试时，服务端直接返回已保存的结果，不再调用供应商，也不重复扣费。服务端仍在转写时重试，会收到 409 和 `Retry-After`，录音继续保留。
  - 流中途供应商失败或超时：释放预留，不扣费，同一个 key 可以重试。
  - 服务端关闭（部署、重新创建容器）时，客户端已断开的流式转写最多再等 5 秒（Docker 默认 10 秒后强制停止进程）；仍未完成的被取消，释放预留，不扣费，App 重试时重新转写。与非流式请求一样，部署宜避开正在转写的时段。
- 代理：响应带 `Cache-Control: no-cache, no-transform` 和 `X-Accel-Buffering: no`。按 Caddy 2 源码，`reverse_proxy` 收到 `text/event-stream` 时每次写入立即转发，`encode zstd gzip` 遇到 `no-transform` 不压缩，所以线上 Caddyfile 无需修改，但尚未在线上实测。如果上线后预览要等转写结束才一次出现，先检查代理是否缓冲或压缩了响应。
- 兼容与发布顺序：旧服务端忽略 `stream`，返回 JSON，新版 App 照常使用最终结果，只是没有预览。代理对流式请求返回 404 或 405 时，App 用同一个 key 改发普通上传。旧版 App 不发 `stream`，行为不变。先部署服务端，再发布 App，用户升级后即可看到预览。
- 发布前在真机上用不含私人内容的短录音确认：预览逐步出现，最终文字只插入一次，只扣一次额度。再在转写中途断网，确认录音进入 History，重试后不重复扣费。
- 说话时就显示文字的 Live 模式见下节。

## Live 实时转写（边说边出字）

设计与取舍见 [REALTIME_TRANSCRIPTION.zh-CN.md](REALTIME_TRANSCRIPTION.zh-CN.md)。

- 用户在 Settings → Transcription mode & model 选 Live 后，App 和键盘从开始录音起就通过 WebSocket 把音频发到服务端；服务端用运营者的 OpenAI 密钥转发到 Realtime API，并把已识别的文字发回。预览的显示位置与流式转写相同，最终结果只插入一次。默认模式仍是 Streaming，Live 要用户自己选。
- 选 Live 时设置页还有 Live model（Automatic 跟随服务默认，或选目录中的实时模型）和 Upload model（Live 不可用或没有完成时上传用的模型）。Live 不可用时设置页说明原因，录音按 Streaming 上传。低数据模式下 App 不用 Live，直接上传。
- 模型与价格（已含 `COST_MARKUP_BPS=7143`；按发给 OpenAI 的音频时长计费，完成的录音最少按 1 秒）：

  | 模型 | 出字时机 | 每分钟 |
  | --- | --- | --- |
  | `gpt-live-transcribe`（服务默认） | 说话时 | 约 29,144 credits |
  | `gpt-transcribe` | 每次停顿后 | 约 7,715 credits |

  成本价在 `backend/main.py` 的 `REALTIME_PRICING`（每分钟 µUSD：17,000 和 4,500）。OpenAI 调价时改这里并重新部署。
- 模型目录 `GET /v1/transcription/models` 新增 `realtime`：`available`、`default_model`、`models`（`id`、`name`、`recommended`、`live_only`、`text_timing`、`retires_on`、`pricing_basis: "audio_minutes"`、`credit_units_per_minute`、`formatted_per_minute`）。目录请求不带账号，所以 `available` 只看开关和密钥，不看用户名单。旧版 App 忽略这个字段。
- 协议：`wss://voicetype.y.dog/v1/realtime/transcriptions`，子协议 `voicetype.realtime.v1`。
  - 握手带 `Authorization: Bearer …` 和 `Idempotency-Key`（与这段录音上传时用的 key 相同）。缺子协议或登录无效时在握手前以 1008 拒绝，App 当作旧服务端，直接上传。
  - App 先发 JSON `{"type":"start","format":"pcm_s16le_24000_mono", "model", "language", "preferred_languages", "vocabulary"}`（提示字段与上传表单相同，都是字符串），然后每 100 ms 发一帧二进制 PCM（24 kHz 单声道 16 位，4,800 字节）。停止时发 `{"type":"commit","audio_seconds":…}`，取消时发 `{"type":"cancel"}`。
  - 服务端发 `ready`（`session_id`、`model`、`text_timing`、`credit_units_per_minute`）、`partial`（到目前为止的文字，最多 500 字，带 `truncated`）、`done`（与上传接口相同的结果）或 `error`（`status`、`code`、`detail`，可能带 `retry_after`），然后关闭连接。
- 计费（运营者决定：按实时价收费；失败和取消的成本由用户承担；不申请零数据保留）：
  - 开始时预留 1 分钟费用（至少 20,000 credits），之后约每分钟追加一次，始终比已发送的音频多留 15 秒。余额不够开始时返回 `insufficient_credit`，中途用完返回 `credit_exhausted`。
  - 完成：按发送的音频秒数扣一次，结果写入 History 和账单，`model` 是实时模型。同一个 key 再上传时直接返回这条结果，不重复扣费。
  - 取消、App 断开、App 发来格式不对的消息（`protocol_error`）、供应商错误、超时、余额用完等没有完成的会话：已发给 OpenAI 的音频按 Live 价格扣费，账单描述为 `<模型> live transcription (unfinished)`，不保存文字。只有 `no_speech`、`server_restarting`（服务端收到停止信号之后才算）、`internal_error` 不扣费。
  - Live 没有完成时，App 用同一个 key 上传录音，按 Upload model 再扣一次，这段录音两次都计费。
  - 上传与 Live 争用同一个 key：Live 已 commit（App 已停止录音）时，上传收到 409 和 `Retry-After`，等 Live 结果；还没 commit 时上传接管，Live 会话结束。
- 限制：单段最长 600 秒；连接后 10 秒内要收到 `start`；OpenAI 会话 10 秒内要就绪；15 秒没有任何消息就断开；会话最长 660 秒；commit 后 30 秒内要出结果。单帧不超过 32 KB；发送速度不能超过实时的 1.5 倍（连接期间缓冲的最多 15 秒音频可以一次补发）；OpenAI 会话就绪前最多缓存 20 秒音频。App 端积压超过 10 秒，或停止后 15 秒仍没有结果，就改为上传。
- 环境变量（都有默认值，`backend.env` 不设也能运行；修改后重新创建 backend 才生效，会结束进行中的会话）：

  | 变量 | 默认 | 说明 |
  | --- | --- | --- |
  | `REALTIME_TRANSCRIPTION_ENABLED` | `true` | `false` 时目录显示不可用、拒绝新会话，App 改为上传。 |
  | `REALTIME_TRANSCRIPTION_MODEL` | `gpt-live-transcribe` | Live 的服务默认模型（Automatic）。填的不是实时模型时按 `gpt-live-transcribe`。 |
  | `MAX_CONCURRENT_REALTIME_SESSIONS` | `8`（限 1–32） | 本进程同时进行的 Live 会话上限，超出返回 `busy`，App 改为上传。 |
  | `REALTIME_ALLOWED_USER_IDS` | 空，即所有人 | 逗号分隔的用户 ID。名单外的用户开始时收到 `realtime_unavailable`，App 上传，本次运行中不再尝试 Live；目录仍显示可用。 |
  | `REALTIME_RATE_LIMIT_PER_WINDOW` | `30` | 每个账号每 `RATE_LIMIT_WINDOW_SECONDS`（默认 60 秒）最多开始的 Live 会话数。 |
- 资源：每个会话一条 App 到服务端、一条服务端到 OpenAI 的 WebSocket，进约 3 MB/分钟，出约 4 MB/分钟（base64）。不用 ffmpeg，不占 `MAX_CONCURRENT_TRANSCRIPTIONS` 的名额。没有压测过并发上限。
- 数据库：启动时自动执行幂等迁移，给 `transcription_requests` 加 `realtime_committed_at` 列（Postgres 和 SQLite 相同），无须手动 SQL。每个进行中的 Live 会话在 `credit_reservations` 占一行 `kind = 'realtime'`。
- 查看进行中的 Live 会话（健康检查不显示）：

  ```sh
  cd /opt/voicetype/app
  sudo docker compose -f deploy/gcp-vm/docker-compose.yml exec postgres \
    psql -U voicetype -d voicetype -c "SELECT kind, count(*) FROM credit_reservations GROUP BY kind;"
  ```

  `realtime` 行是进行中的 Live 会话，其他行是正在转写的上传。部署前等这些都归零；Live 会话最长 11 分钟。
- 重启、部署与代理：
  - Live 会话保存在进程内，只支持单个 backend 实例。启动时删除所有 `kind = 'realtime'` 的预留和没有完成的 Live request key，不扣费。
  - 进程收到 SIGTERM 或 SIGINT 后，uvicorn 以 1012 关闭 WebSocket，服务端记为 `server_restarting`，不扣费，App 改为上传（服务端还没恢复时录音保存在 History）。没有收到停止信号时，App 自己发来的 1012 按 App 断开（`disconnected`）扣费。镜像用 `sh -c` 启动 uvicorn；如果 SIGTERM 没有传到 uvicorn，Docker 10 秒后强制停止，连接直接断开，启动清理后同样不扣费。
  - Caddy 的 `reverse_proxy backend:8080` 自动转发 WebSocket 升级，`encode` 不处理 WebSocket，线上 Caddyfile 无须修改，但尚未在线上实测。Caddy reload 默认立即关闭已升级的连接（`stream_close_delay` 默认 0）：服务端看到 App 断开，按已发送音频扣费，App 再上传。所以 reload Caddy 也宜避开有 Live 会话的时候。
  - 服务端用 `websockets` 包连接 OpenAI，uvicorn 也用它处理 App 的 WebSocket（`uvicorn[standard]` 自带，线上 websockets 17.1）。部署后确认：

    ```sh
    cd /opt/voicetype/app
    sudo docker compose -f deploy/gcp-vm/docker-compose.yml exec backend \
      python -c "import websockets, uvicorn.protocols.websockets.auto as a; print(websockets.__version__, a.AutoWebSocketsProtocol)"
    ```

  - 新增文件 `backend/realtime.py`。只覆盖改动的 `.py` 文件时必须带上它，否则 `import realtime` 失败，后端无法启动。`Dockerfile` 的 `COPY` 已加上它，重新构建镜像时会包含。
- 回滚：设 `REALTIME_TRANSCRIPTION_ENABLED=false` 后重新创建 backend。选了 Live 的用户看到 “Live isn't available right now”，录音按 Streaming 上传，不需要回滚 App。也可以先只对 `REALTIME_ALLOWED_USER_IDS` 中的 TestFlight 测试账号开放。
- 日志：`realtime_completed`（`audio_seconds`、`turns`、`cost_usd_micros`）、`realtime_ended`（`code`、`audio_seconds`、`cost_usd_micros`）、`realtime_provider_error`、`realtime_upstream_closed`、`realtime_failed`。账单中带 `(unfinished)` 的是没有完成、按已发送音频扣费的会话。
- 隐私：Live 经 OpenAI Realtime API，OpenAI 可能保留音频和文字最多 30 天用于滥用监控。设置页的 Live 说明和 `docs/PRIVACY_POLICY.md` 已写明；公开隐私页（apeonwheels.com/voicetype/privacy/）要在含 Live 的版本上架前用 `website/build_company_pages.py` 重建并发布。
- 发布顺序：先部署服务端，确认 `GET /v1/transcription/models` 返回 `realtime.available: true`，再上传 TestFlight。旧版 App 不用 Live，不受影响；新版 App 遇到没有 Live 的服务端会直接上传。
- 真机待验证：录音同时用 AVAudioEngine 取 24 kHz 音频（与 AVAudioRecorder 并行、在后台启动）；WebSocket 子协议头；Caddy 转发 WebSocket；低数据模式改为上传；OpenAI 的真实事件和延迟；名单外的账号第一次录音会先连接再上传。用不含私人内容的短录音确认：预览随说话出现，最终文字只插入一次，账单只有一条 Live 记录。

## 转写失败与静音录音

- 转写失败（网络、超时、供应商错误等）会释放预留额度，录音保存在 History 等待重试。键盘回到就绪状态，并提示 “Couldn't transcribe — saved in History”；录音无法保存（如存储空间不足）时提示 “Couldn't transcribe — try again”。
- 识别结果为空时，服务端返回 422，正文为 `{"detail": "No speech was detected in this recording. Nothing was charged.", "code": "no_speech"}`，同样释放预留、不扣费。App 收到 `code: "no_speech"` 后直接删除这段录音，不放进 History，因为重试结果相同，还会再次调用供应商。键盘提示 “No speech detected — nothing charged”。在 History 中重试旧录音时收到 `no_speech`，也会删除这条录音。
- 键盘提示只在键盘可见时显示一次，约 4 秒后消失；失败 60 秒后仍未显示的提示不再出现，录音仍按上述规则保留或删除。
- 其他 422（例如参数无效）不带 `code`。旧版 App 只读 `detail`，照常显示同一句说明。旧版服务端不返回 `code`，新版 App 会把静音录音当作普通失败保存在 History，所以先部署服务端，再发布 App。

Apple 参考：[TestFlight 内购测试](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight)。
