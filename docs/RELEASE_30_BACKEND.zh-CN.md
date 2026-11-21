# VoiceType 后端 release 30 部署记录

记录日期：2026-11-20。范围：线上后端，即 GCP VM `voicetype-api` 上的 `gcp-vm-backend-1` 容器。App 构建、TestFlight 和 App Store 审核不在本文件内。本文件不含密钥、环境变量的值、用户数据和用量。时间均为 UTC。

## 现在线上运行的版本

- 自 2026-11-20 18:35 起，线上运行的是提交 `1d17483` 的 `backend/`。该提交的 23 个后端文件与发布包逐个哈希一致；容器内的 5 个运行文件（`main.py`、`dictation.py`、`provider_admin.py`、`realtime.py`、`admin/admin.js`）与发布清单一致。
- 镜像 `sha256:877d8e039fe3f8bb08b88911e857ad828ced158de005350b788fd1122157ed45`，标签 `gcp-vm-backend:latest` 和 `gcp-vm-backend:release30-20261120T182719Z`。
- 环境文件、Caddyfile、数据库结构和供应商设置没有改动。服务默认的上传模型仍是 `gpt-4o-mini-transcribe`。

## 两次部署

服务器上带成功记录（`success.json`）的 release 30 部署有两次。r2、r3 是发布包的编号。

| | r2 | r3 |
| --- | --- | --- |
| 日期 | 2026-10-26 | 2026-11-20 |
| 内容 | release 30 后端：模型选择、流式转写、Live 实时转写、多语言提示、静音录音不扣费 | 计费修复，见下节 |
| 提交 | `f080f96` | `1d17483` |
| 镜像 | `sha256:2cff4b8035b9…` | `sha256:877d8e039fe3…` |
| 换下的镜像 | `sha256:afb428c87a10…` | `sha256:2cff4b8035b9…` |
| 服务器发布目录 | `/opt/voicetype/releases/20261026-release30-r2` | `/opt/voicetype/releases/20261120-release30-r3` |
| 服务器备份目录 | `/opt/voicetype/backups/release30-20261026T173609Z` | `/opt/voicetype/backups/release30-20261120T182719Z` |

r2 一列来自服务器上留下的发布记录和镜像标签，不是部署当时的观察。2026-11-20 部署前核对过：当时运行的 5 个文件和服务器上的 23 个源码文件与 r2 发布包一致，提交 `f080f96` 的 `backend/` 也与它一致。

## r3 修了什么

- 同一个 request key 的整段上传接管还在进行的 Live 录音时，先释放 Live 的预留，再为自己预留。Live 会话随后要为已发送的音频付费，这笔费用原来按可用余额（账本余额减去所有预留）封顶。上传的预留占满余额时，封顶算出 0，已发给 OpenAI 的 Live 音频没有收费。
- 现在这笔费用按账本余额封顶。上传完成后再按剩下的可用余额封顶，两笔合计不超过账本余额。
- 可用余额不再因为预留变成负数。开发赠送接口的密钥改为恒定时间比较。
- 改动在 `backend/main.py` 的 `release_realtime_session`、`balance_for_user` 和开发赠送接口。回归测试是 `backend/tests/test_realtime.py` 的 `test_live_audio_is_paid_when_the_upload_that_took_over_holds_the_balance`。说明见 [REALTIME_TRANSCRIPTION.zh-CN.md](REALTIME_TRANSCRIPTION.zh-CN.md) 13.3 和 [OPERATIONS.zh-CN.md](OPERATIONS.zh-CN.md) 的“Live 实时转写”。
- 数据库结构没有变化。

## r3 的部署过程

发布脚本 `deploy_release30.py` 与 r2 用的是同一份，没有修改。它在服务器上作为一次性 systemd 单元运行，18:27:16 启动，退出码 0。切换前任何一步失败都不会动线上；切换后的检查失败会自动换回旧镜像和旧文件。

1. 核对线上镜像和源码就是 r2，在旧镜像上只替换运行文件，构建候选镜像。
2. 在候选镜像里跑后端测试：无网络，去掉全部 capabilities，内存上限 768 MB。结果是 `320 passed, 1 warning`，其中包含上面的回归测试。
3. 在隔离的临时 PostgreSQL 16 上检查：迁移执行两次、账户与账本隔离、按用户的行锁、已完成请求的重放、并发重复请求只扣一次、重启后重放、欢迎额度的补发与删除重建、并发退款与撤销、删除账号级联等。
4. 媒体检查：上传超限返回 413，Apple 登录、StoreKit 交易和 V2 通知的 JSON 请求体有大小限制，2 个并行解码时第 3 个任务返回 503，内存峰值约 324 MB。
5. Live 检查：迁移两次、模型目录、首分钟预留与追加、只扣一次、上传重放、取消的录音按已发送音频付费、静音不扣费、上传接管、重启只释放 Live 预留。
6. 备份（见“备份与证据位置”），并把数据库备份恢复到无网络的临时 PostgreSQL 16 里比对：全表数据和序列一致，约束和索引有效。线上数据库没有被恢复或替换。
7. 等到数据库里没有任何预留，即没有进行中的转写，再安装文件、切换镜像。
8. 切换后检查：`/health/ready` 的 13 项全部通过；8 个公开地址返回 200；`GET /v1/transcription/models` 返回 200，未登录的 `POST /v1/transcriptions` 返回 401；环境文件、Caddyfile、供应商设置未变；其他容器没有被改动。

## 部署后的独立核对

18:38，在脚本之外另行检查：

- 运行中的容器用的是新镜像，状态 healthy，重启次数 0，以非 root 用户 `appuser` 运行。
- 容器内的 5 个运行文件、服务器源码目录的 23 个后端文件，哈希都与 r3 发布清单一致。
- 其他容器没有重启。
- 数据库里没有预留，也没有未完成的 request key。
- 后端启动以来的日志里没有警告、错误或异常堆栈。
- 从外部访问：`/health/ready` 返回 200 且 13 项通过，模型目录返回 200，未登录的转写请求返回 401。

## 没有验证的

- 修复没有在线上用真实扣费验证。线上的开发赠送接口是关闭的，也没有动任何真实账户的余额。证据是候选镜像里通过的回归测试，加上运行中的 `main.py` 与发布包哈希一致。隔离数据库里的“上传接管”检查用的是充足的余额，不覆盖余额被占满的情形。
- 本次没有做真机验证。流式转写和 Live 经过 Caddy 的行为，仍以 [OPERATIONS.zh-CN.md](OPERATIONS.zh-CN.md) 里“真机待验证”的清单为准。
- 切换开始时没有进行中的转写，所以强制停止对进行中请求的影响（见下节）是按代码得出的，没有在线上实测。

## 切换过程与停止信号

- 18:33:01 新容器创建，旧容器收到 SIGTERM。
- 18:35:31 旧容器在发布脚本设定的 150 秒等待期满后被强制停止（SIGKILL，退出码 137），新容器随即启动。18:35:40 前就绪检查已通过。
- 原因：镜像的启动命令是 `sh -c "uvicorn …"`，容器里 1 号进程是 `sh`，uvicorn 是它的子进程（在新容器里实测；新旧镜像的启动命令相同）。`sh` 作为 1 号进程没有处理 SIGTERM，信号被忽略，也不会转给 uvicorn。
- 所以这 150 秒里旧后端照常服务，真正的中断是强制停止到新进程就绪之间的不到 10 秒。Compose 文件没有设置停止等待时间，用 Docker 默认设置重新创建 backend 时是等 10 秒后强制停止。
- 没有上传被打断：被强制停止的上传会在数据库里留下预留和未完成的 request key，切换后两样都没有。Live 会话无法从记录确认：发布脚本开始切换前确认过没有任何预留（包括 Live），但之后 150 秒里新开始又被打断的 Live 会话不会留下痕迹，新进程启动时会清掉它的预留和 request key，旧容器的日志也随容器删除了。代理日志在 18:32:30–18:37:00 之间没有警告或错误；代理没有开启访问日志。

按代码，强制停止意味着：

- [OPERATIONS.zh-CN.md](OPERATIONS.zh-CN.md) 里写的正常关闭不会执行：Live 会话收不到 1012，流式转写也没有 5 秒的收尾等待。
- Live 会话：连接直接断开。启动时清理 Live 预留和未完成的 Live request key，不扣费，App 改为上传。
- 进行中的上传：扣费和结果在同一个事务里写入，没写完就不扣费。但预留和 request key 留在数据库里：同一个 key 重试先收到 409，处理租约（`TRANSCRIPTION_PROCESSING_LEASE_SECONDS`，默认 300 秒）过后才重新转写并释放旧预留；没有重试时，预留在 `CREDIT_RESERVATION_TTL_SECONDS`（默认 1800 秒）后过期。上传预留在重启后保留这一点，隔离检查里的“重启只释放 Live 预留”验证过。
- 发布脚本在切换前等预留归零，但旧后端在随后的 150 秒里还会接新请求，这些请求可能被强制停止打断。

建议的后续，尚未做，需要所有者决定：把启动命令改成 `sh -c "exec uvicorn …"`，让 uvicorn 成为 1 号进程并收到 SIGTERM。这样正常关闭才会生效：不再接新请求，进行中的请求收尾后退出。这会改变线上的停止行为，要重新构建镜像，并单独验证关闭过程：Live 的 1012 与 `server_restarting`、流式的 5 秒等待，以及停止等待时间要长于最长的进行中请求。

## 回滚

回滚是线上变更，由所有者决定。回滚到 r2 会把上面的计费问题带回来。r2 与 r3 的数据库结构相同，不需要动数据库。

1. 把备份目录 `files/backend/` 下的 `main.py` 和 `tests/test_realtime.py` 放回 `/opt/voicetype/app/backend/` 的对应位置。
2. 把旧镜像标回 `latest`：

   ```sh
   sudo docker tag gcp-vm-backend:before-release30-20261120T182719Z gcp-vm-backend:latest
   ```

3. 重新创建 backend（按上节，旧容器会在等待期满后被强制停止，先确认没有进行中的转写）：

   ```sh
   cd /opt/voicetype/app
   sudo docker compose --project-name gcp-vm -f deploy/gcp-vm/docker-compose.yml up -d --no-deps --no-build backend
   ```

4. 确认 `https://voicetype.y.dog/health/ready` 返回 200 且各项通过，运行中的镜像是 `sha256:2cff4b8035b956461281586fc4ef65248dc310d8be01e95413a0cdfec552f47d`。

镜像标签被删掉时，备份目录里的 `backend-image.tar` 可以用 `docker load` 恢复旧镜像。

## 备份与证据位置

- 服务器备份目录 `/opt/voicetype/backups/release30-20261120T182719Z`（目录权限 700，文件 600）：切换前的 `backend.env`、`db.env`、`Caddyfile`，源码包 `source.tar.gz`，旧镜像 `backend-image.tar`，数据库备份 `database.dump`，被替换的两个文件在 `files/`。里面有密钥和用户数据，不要复制到仓库、聊天或日志。
- 服务器发布目录 `/opt/voicetype/releases/20261120-release30-r3`：发布包、清单 `manifest.json`、脚本输出 `deploy.out`、结果 `success.json`，以及各项检查的日志 `*.private.log`（权限 600）。
- 发布包和发布脚本在本机被 Git 忽略的 `build/release30/release-r3/`，不在仓库里。`deploy_release30.py` 和 `verify_postgres_realtime.py` 只在这里和服务器发布目录里；另外三个检查脚本与仓库的 `scripts/verify_postgres_release.py`、`scripts/verify_backend_media_release.py`、`scripts/verify_backup_restore20.py` 相同。
- 没有清理：服务器上的旧镜像、旧备份和旧发布目录都保留，磁盘剩余约 11 GB。服务器源码目录里有几个 macOS 打包留下的 `._*` 文件，不参与运行。
