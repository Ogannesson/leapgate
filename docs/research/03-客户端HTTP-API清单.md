# 03 · RustDesk 客户端 HTTP API 清单与 rustdesk-api 对照

- 调研日期：2026-10-22
- 客户端：`rustdesk@bd92623`（本地 `upstream/rustdesk`，2026-10-21）
- 第三方 API：`rustdesk-api@c5687e1`（本地 `upstream/rustdesk-api`，lejianwen，2025-09-29；`git ls-remote` 确认这仍是 GitHub master 最新提交）
- 标记：**[确认]** = 读代码确认；**[推测]** = 根据代码推断但未运行验证
- 本次只读，未编译、未运行。

---

## 0. 一页结论

1. 客户端调的 HTTP 接口共 **约 30 个路径**，分四类：账号（login / logout / currentUser / login-options / oidc）、地址簿（旧版 `/api/ab` 一套 + 新版 `/api/ab/*` 十几个）、设备与组（heartbeat / sysinfo / users / peers / device-group）、审计（audit/conn、file、alarm，及 Pro 才有的 conn/active、PUT audit、record、switch-grant、devices/deploy、devices/cli）。
2. **服务端没有任何"能力协商"接口**。客户端靠 HTTP 404、返回体是否含某字段、某个字符串常量（`SYSINFO_UPDATED`）来推断服务端能力。Porta 自己写服务端时必须原样复刻这些"暗号"。
3. rustdesk-api 覆盖了 OSS 客户端的日常功能（登录、OIDC、地址簿新旧两版、组、sysinfo、heartbeat、conn/file 审计），**没实现**：heartbeat 下发 `strategy`/`disconnect`/`sysinfo`、`audit/alarm`、`audit/conn/active`、`PUT /api/audit`、`/api/record`、`/api/switch-grant`、`/api/devices/deploy`、`/api/devices/cli`、邮箱/TOTP 二次验证。
4. 已发现一处**兼容性缺陷** [确认]：新客户端要求审计接口成功时返回**空 body**，rustdesk-api 返回 `{"code":0,"message":"success","data":""}`，客户端会当作"异常响应"重试 2 次（10s、30s 后），rustdesk-api 不按 `nonce` 去重，`action:new` 记录会被重复写 3 条。
5. 心跳 `/api/heartbeat` 的 `strategy.config_options` 是**通用的远程下发任意客户端选项**通道（直接写进 `Config::set_options`），Porta 的"智能路由（下发中继列表）"可以直接复用，无需改客户端协议。rustdesk-api 对心跳只回 `{}`，这条通道完全空着。
6. 设备侧接口（heartbeat、sysinfo、audit/*）**不带任何认证**，只靠请求体里的 `id` + `uuid` 标识设备；只有 `switch-grant` 用设备 Ed25519 私钥签名。Porta 服务端要考虑这一点（见第 7 节问题）。

---

## 1. api-server 地址怎么来

`rustdesk@bd92623:src/common.rs` `fn get_api_server` / `fn get_api_server_`，`src/ui_interface.rs` `fn get_api_server` [确认]

优先级从高到低：

1. `Config::no_register_device()` 为真 → 返回空串（所有 API 功能关闭）。
2. Windows：从 exe 文件名解析的 license（`platform::windows::get_license_from_exe_name`）里的 `api` 字段（定制客户端用）。
3. 用户/配置填写的 `api-server` 选项（Flutter 设置页 `flutter/lib/common.dart` 第 ~3634 行写入；要求以 `http://` 或 `https://` 开头）。
4. 从 `custom-rendezvous-server`（ID 服务器）推导：端口 **减 2**（`crate::increase_port(&s0, -2)`）。ID 服务器不带端口时用 `RENDEZVOUS_PORT - 2 = 21114`，**协议固定 `http://`**。例：`id.example.com` → `http://id.example.com:21114`；`id.example.com:21116` → `http://id.example.com:21114`。
5. 都没有 → `https://admin.rustdesk.com`（官方公共服务）。

后处理：去掉末尾 `/`；若是 `https://...:21114` 且内置选项 `allow-https-21114` ≠ `Y`，把 `:21114` 去掉（假设 HTTPS 走 443 反代）。

`fn is_public`：host 是 `rustdesk.com` 或 `*.rustdesk.com` 视为官方公共服务器。**heartbeat、sysinfo、audit、switch-grant 在公共服务器上全部禁用**（`heartbeat_url()`、`get_audit_server()` 返回空）。

UI 提示：API 服务器为 `http://` 且非 localhost 时提示不安全（`flutter/lib/common/widgets/api_server_warning.dart` `shouldWarnApiServer`）。改 api-server 后若已登录，会先用旧地址调 `/api/logout`（`common.dart` 第 ~3637 行）。

### HTTP 传输层
- Dart 侧 `flutter/lib/utils/http_service.dart` `HttpService.sendRequest`：默认用 Dart `http` 包；开了代理或选项 `enable-flutter-http-on-rust` 时转发给 Rust `main_http_request`（`src/ui_interface.rs` `fn http_request`）[确认]。
- Rust 侧 `src/common.rs` `post_request` / `post_request_with_status` / `http_request_sync`：先走 HTTP(S)，失败可回退到 "raw TCP proxy"（经 hbbs 隧道转发 API 请求，内置选项 `use-raw-tcp-for-api`，`fn should_use_raw_tcp_for_api`）。**这条回退依赖 hbbs Pro 的 TCP 代理能力**，OSS hbbs 无此功能 [推测：OSS hbbs 不处理该消息，需另查 rustdesk-server 源码确认]。
- TLS：`src/hbbs_http/http_client.rs` `create_http_client_with_url` 会用 `/api/login-options` 预热探测 TLS 实现（rustls / native-tls 回退）[确认，`account.rs` `ensure_client`、`record_upload.rs` `run`]。

---

## 2. 认证方式

### 2.1 token 获取与存储 [确认]
- 账号密码：`POST /api/login` → 返回 `access_token`。
- OIDC：`POST /api/oidc/auth` + 轮询 `GET /api/oidc/auth-query` → 返回同样结构。
- 存储：`LocalConfig` 选项 `access_token`（明文字符串）和 `user_info`（JSON：name/display_name/avatar/status）。Dart `user_model.dart` `_parseAndUpdateUser`、`login.dart` `handleLoginResponse`、Rust `account.rs` `auth_task`（`remember_me` 为真时写）。
- 请求头：`flutter/lib/common.dart` `getHttpHeaders()` → `Authorization: Bearer <access_token>`。所有用户态接口（currentUser、logout、ab、users、peers、device-group、PUT audit、audit/conn/active）带它。
- 失效：任一用户态接口返回 **401** → `userModel.reset(resetOther: true)`，清 token、清地址簿和组缓存。`/api/currentUser` 返回 400 也清 token（但不清其他）。
- 设备态接口（heartbeat、sysinfo、sysinfo_ver、audit/conn|file|alarm、record）**不带 Authorization**（header 参数传 `""`）；只在 body 里带 `id`、`uuid`（`uuid` = base64(机器 UUID)）。
- `devices/deploy`、`devices/cli`：`Authorization: Bearer <管理员在后台生成的 api_token>`，由命令行参数传入。

### 2.2 账号密码登录流程（含二次验证）[确认]
`flutter/lib/common/widgets/login.dart` `onLogin`、`verificationCodeDialog`；`flutter/lib/common/hbbs/hbbs.dart` `LoginRequest` / `LoginResponse`

请求体：
```json
{"username":"..","password":"..","id":"<本机ID>","uuid":"<base64 uuid>","autoLogin":true,
 "type":"account","deviceInfo":{"os":"windows","type":"client","name":"<hostname>"}}
```
响应 `type`：
- `access_token` → 成功，取 `access_token`、`user`。
- `email_check` → 需要验证码；`tfa_type` 为空或 `email_check` 表示邮件验证码，`tfa_check` 表示 TOTP。响应带 `secret`、`user`。
- 第二步再 `POST /api/login`，`type:"email_code"`，带 `verificationCode`、`tfaCode`（TOTP 时）、`secret`、`username`。
错误：HTTP 非 200 或 body 有 `error` 字段 → 显示 `error` 文本。

### 2.3 OIDC / 第三方登录流程 [确认]
`src/hbbs_http/account.rs` `OidcSession`；Dart `login.dart`（`mainAccountAuth` / `mainAccountAuthResult` 轮询 Rust 状态）
1. `GET /api/login-options` → 字符串数组。客户端优先找 `common-oidc/<JSON数组>`（如 `[{"name":"github"},{"name":"webauth"}]`），否则把每个 `oidc/<name>` 当成一个按钮（`user_model.dart` `queryOidcLoginOptions`）。
2. 用户点按钮 → `POST /api/oidc/auth`，body `{"op":"<name>","id":..,"uuid":..,"deviceInfo":{..},"apiDomain":"<api_server>"}` → 响应 `{"code":"<state>","url":"<浏览器授权地址>"}`，客户端打开浏览器。
3. 每 1 秒 `GET /api/oidc/auth-query?code=<code>&id=..&uuid=..`，最长 180 秒。响应 `{"error":"No authed oidc is found"}` 表示还没完成（**这个错误字符串是硬编码的继续轮询暗号**），其他 `error` 立即失败；成功返回与 `/api/login` 相同的 `AuthBody`（`access_token`、`type:"access_token"`、`user`）。
4. 浏览器回调页（`/api/oidc/callback` 等）完全是服务端自己的事，客户端不调。

### 2.4 用户信息结构（服务端需返回）
`account.rs` `UserPayload`（Rust 反序列化，`name` 和 `info` 必填，缺了会 `DataTypeFormat` 失败）、`hbbs.dart` `UserPayload`：
```
name, display_name, avatar(可为 "/avatar/xxx" 相对路径，ui_interface.rs resolve_avatar_url 补全), email, note,
status(1 正常 / 0 禁用 / -1 未验证), is_admin, info{email_verification, email_alarm_notification, login_device_whitelist[], other{}}, third_auth_type, verifier(仅 web)
```
注意 Rust 侧 OIDC 路径要求 `user.info` 存在 [确认]；`is_admin` Dart 存了但没有任何 UI 用到 [确认，grep 无引用]。

---

## 3. 接口清单（按功能）

记号：`[D]` Dart 调用，`[R]` Rust 调用。"RA" 列 = rustdesk-api 是否实现：✅ 实现 / ⚠️ 实现但行为有差 / ❌ 未实现。

### 3.1 账号

| 方法 路径 | 调用方 | 时机 | 请求关键字段 | 响应关键字段 | RA |
|---|---|---|---|---|---|
| GET `/api/login-options` | [D] `user_model.dart` `queryOidcLoginOptions`；[R] TLS 预热 | 打开登录框；OIDC/录像上传前探测 TLS | — | `["common-oidc/[...]","oidc/github",...]` | ✅ |
| POST `/api/login` | [D] `UserModel.login` | 账号密码登录、验证码第二步 | 见 2.2 | `access_token,type,tfa_type,secret,user` | ⚠️ 无二次验证，只回 `access_token` |
| POST `/api/currentUser` | [D] `UserModel.refreshCurrentUser` | 启动、刷新；有 token 时 | `{id,uuid}` + Bearer | UserPayload；401/400 清 token | ✅（`/api/user/info` 同处理） |
| POST `/api/logout` | [D] `UserModel.logOut` | 注销；改 api-server 时 | `{id,uuid}` + Bearer，2s 超时，失败忽略 | 任意 | ✅ |
| POST `/api/oidc/auth` | [R] `account.rs` `OidcSession::auth` | 点第三方登录 | `op,id,uuid,deviceInfo,apiDomain` | `code,url` | ✅ |
| GET `/api/oidc/auth-query` | [R] `OidcSession::query` | 每秒轮询，≤180s | `code,id,uuid`（query） | AuthBody 或 `error:"No authed oidc is found"` | ✅ |

### 3.2 地址簿 —— 旧版（legacy）
`flutter/lib/models/ab_model.dart` `class LegacyAb`；条件：`POST /api/ab/personal` 返回 **404** 时进入 legacy 模式 [确认]

| 方法 路径 | 时机 | 请求 | 响应 | RA |
|---|---|---|---|---|
| GET `/api/ab` | 拉地址簿 | Bearer，`Accept-Encoding: gzip` | `{"data":"<JSON字符串>","licensed_devices":N}` 或字面 `null`；data 内 `{tags:[],peers:[...],tag_colors:"<JSON>"}` | ✅ |
| POST `/api/ab` | 任何修改后整体推送 | `{"data":"<整本序列化JSON>"}` | 空 / `null` / 无 error 即成功 | ✅ |

`licensed_devices > 0` 时客户端截断条目数（`LegacyAb.isFull`）。

（Sciter 旧 UI `src/ui/ab.tis` 用 `POST /api/ab/get`，已废弃，不考虑。）

### 3.3 地址簿 —— 新版（多本、共享）
`ab_model.dart` `AbModel._getPersonalAbGuid` / `_getAbSettings` / `_getSharedAbProfiles`，`class Ab` [确认]。全部带 Bearer。

| 方法 路径 | 时机 | 请求 | 响应 | RA |
|---|---|---|---|---|
| POST `/api/ab/personal` | 每次拉列表第一步 | 空 body | `{"guid":"..."}`；**404 → legacy 模式**；无 guid（null）也会落入 legacy | ✅（`personal:0` 时回 `null`） |
| POST `/api/ab/settings` | 新模式且尚未取过 | 空 | `{"max_peer_one_ab":N}`（0=不限）；404 = 不支持共享 | ✅ 固定 0 |
| POST `/api/ab/shared/profiles?current=&pageSize=100` | 新模式 | 空 | `{"total":N,"data":[{guid,name,owner,note,info,rule}]}`；rule 1 只读 / 2 读写 / 3 完全控制；404 = 不支持共享 | ✅ |
| POST `/api/ab/peers?current=&pageSize=100&ab=<guid>` | 拉某本地址簿条目 | 空 | `{"total":N,"data":[Peer...]}`（id, hash, password, username, hostname, platform, alias, tags, note…） | ✅ |
| POST `/api/ab/tags/<guid>` | 拉标签 | 空 | `[{"name":..,"color":int}]`（**顶层是数组**） | ✅ |
| POST `/api/ab/peer/add/<guid>` | 添加设备 | Peer JSON（id, alias, tags, password?, note?, hash?） | 无 error 即成功 | ✅ |
| PUT `/api/ab/peer/update/<guid>` | 改标签/别名/备注/密码/从最近会话同步 | `{id, tags}` / `{id, alias}` / `{id, note}` / `{id, hash}`（个人本存密码哈希）/ `{id, password}`（共享本存明文）/ 同步时混合字段 | 同上 | ✅ |
| DELETE `/api/ab/peer/<guid>` | 删设备 | body 为 ID 数组 `["id1",...]` | 同上 | ✅ |
| POST `/api/ab/tag/add/<guid>` | 加标签 | `{name, color}` | 同上 | ✅ |
| PUT `/api/ab/tag/rename/<guid>` | 改名 | `{old, new}` | 同上 | ✅ |
| PUT `/api/ab/tag/update/<guid>` | 改颜色 | `{name, color}` | 同上 | ✅ |
| DELETE `/api/ab/tag/<guid>` | 删标签 | `["tag"]` | 同上 | ✅ |

另：新模式下地址簿菜单有"在 Web 控制台管理"，直接用浏览器打开 api-server 根地址（`common/widgets/address_book.dart` 第 ~437 行）[确认]。

### 3.4 组（"可访问的设备"面板）
`flutter/lib/models/group_model.dart` `GroupModel._pull`；条件：已登录、无网络错误、非 `disable-group-panel` 内置选项 [确认]

| 方法 路径 | 请求 | 响应 | 失败影响 | RA |
|---|---|---|---|---|
| GET `/api/device-group/accessible?current=&pageSize=100` | Bearer | `{total, data:[{name}]}` | 失败被忽略（"old hbbs doesn't support"） | ⚠️ 仅管理员有数据 |
| GET `/api/users?current=&pageSize=100&accessible=&status=1` | Bearer | `{total, data:[UserPayload]}` | 失败则整组面板报错；`error == "Admin required!"` 时提示"升级 Pro 到 1.1.10" | ✅（非管理员只看共享组） |
| GET `/api/peers?current=&pageSize=100&accessible=&status=1` | Bearer | `{total, data:[{id, info{username,os,device_name}, status, user, user_name, device_group_name, note}]}` | 同上 | ✅ |

### 3.5 设备同步（被控端后台线程）
`rustdesk@bd92623:src/hbbs_http/sync.rs` `fn start_hbbs_sync_async`（每 3 秒 tick，无连接时心跳间隔 15 秒）[确认]

| 方法 路径 | 时机 | 请求 | 响应与客户端行为 | RA |
|---|---|---|---|---|
| POST `/api/sysinfo` | 首次、用户名变化、服务端要求、失败后 120s 重试 | `crate::get_sysinfo()`（os, hostname, username, cpu, memory…）+ `version,id,uuid` + 可选预设字段 `preset-address-book-name/tag/alias/password/note`、`preset-user-name`、`preset-strategy-name`、`preset-device-group-name`、`preset-note`，以及 `username`/`hostname` 覆盖 | 纯文本 **`SYSINFO_UPDATED`** → 视为已上传，并**置 `PRO=true`**；`ID_NOT_FOUND` → 下次心跳重传；其他 → 120s 后重试 | ✅ 回 `SYSINFO_UPDATED`，忽略预设字段 |
| POST `/api/sysinfo_ver` | 理论上 sysinfo 哈希未变时 | 空 | 版本串 | ✅ 但**客户端实际不会调**：外层 `if crate::is_public(&url)` 而 `heartbeat_url()` 对公共服务器已返回空，该分支是死代码 [确认] |
| POST `/api/heartbeat` | 有连接时每 3s，无连接每 15s | `{id, uuid, ver(数字版本), conns:[conn_id...]?, modified_at:<strategy_timestamp>}` | JSON 可含：`sysinfo`（任意值 → 强制重传 sysinfo）、`disconnect:[conn_id]`（→ 广播断开这些连接，`connection.rs` 订阅 `signal_receiver`）、`modified_at:int`（存为 `strategy_timestamp`）、`strategy:{config_options:{k:v}, extra:{}}`（→ `handle_config_options` 直接写入客户端 `Config` 选项，值为空且无默认值时删除该键） | ⚠️ 只更新在线时间，永远回 `{}` |

### 3.6 审计
URL 由 `src/common.rs` `fn get_audit_server(api, custom, typ)` 生成：`<api>/api/audit/<typ>`；公共服务器为空。被控端发送均走 `src/server/connection.rs` `fn post_audit_async`（带重试，见 3.8）[确认]

| 方法 路径 | 调用方 / 时机 | 请求关键字段 | RA |
|---|---|---|---|
| POST `/api/audit/conn` | [R] 被控端 `Connection::on_open`（`action:"new"`, `ip`）、认证成功（无 action，`peer:[id,name]`, `type`, `primary_auth`, `two_factor`）、关闭（`action:"close"`）；都加 `id, uuid, conn_id, session_id, nonce`，可选 `conn_audit_ref`（来自 hbbs PunchHole 的 `ControlledContext`，Pro 才下发） | ⚠️ 存储正常，但响应体非空导致重试重复写（见 3.8） |
| POST `/api/audit/conn` | [R] 主控端 `ui_session_interface.rs` 第 ~592 行（会话结束写备注 note） | `id`, `session_id`, `note` 等 | ⚠️ 同上 [推测：该路径 body 未逐字段核对] |
| POST `/api/audit/file` | [R] `Connection::post_file_audit`：文件传输、打印 | `id, uuid, peer_id, conn_id, type, path, is_file, info(JSON字符串: ip,name,num,files[前10大]), nonce` | ⚠️ 同上 |
| POST `/api/audit/alarm` | [R] `Connection::post_alarm_audit`：IP 白名单拦截、ID 白名单拦截、登录失败退避、会话越权等 | `id, uuid, typ(int), info(JSON字符串), conn_id, nonce, conn_audit_ref?` | ❌ 404 → 4xx 不重试，静默丢弃 |
| GET `/api/audit/conn/active?id=&session_id=&conn_type=` | [D] 主控端 `models/model.dart` 第 ~1259 行，连接后查审计记录 GUID（开了"连接结束时询问备注"才调） | Bearer | 响应为 JSON 字符串 guid | ❌ |
| PUT `/api/audit` | [D] `common/widgets/dialog.dart` `updateAuditNoteByGuid`，连接结束填备注 | `{guid, note}` + Bearer | ❌ |

### 3.7 Pro 专属 / 部署类（OSS 服务端都没有）

| 方法 路径 | 调用方 / 时机 | 说明 | RA |
|---|---|---|---|
| POST `/api/record?type=new|part|tail|remove&file=&offset=&length=` | [R] `hbbs_http/record_upload.rs` `RecordUploader` | 录像上传。**`ENABLE` 静态变量从未被置 true，OSS 构建里是死代码** [确认：全仓只读不写] | ❌ |
| POST `/api/switch-grant` | [R] `sync.rs` `register_switch_grant`（`ipc.rs` 第 1092 行，"切换控制方向"时） | `{id, switch_code_verifier, timestamp, signature}`，Ed25519 设备私钥签名 `"switch-grant\0"+id+"\0"+verifier+"\0"+ts`；响应 `{accepted:bool, server_time?}`，时间偏差时用 server_time 重签一次。Fire-and-forget，不阻塞切换 | ❌ |
| POST `/api/devices/deploy` | [R] `ui_interface.rs` `deploy_device`（`--deploy --token`，安卓部署对话框） | `{id, uuid, pk}` + `Bearer <api_token>`；响应 `{"result":"OK"|"NOT_ENABLED"|"INVALID_INPUT"|"ID_TAKEN"}`。配合 hbbs 的"未部署设备拒绝注册"（`rendezvous_mediator.rs` NEEDS_DEPLOY） | ❌ |
| POST `/api/devices/cli` | [R] `core_main.rs` `--assign --token` | `{id, uuid, user_name?, strategy_name?, address_book_name/tag/alias/password/note?, device_group_name?, note?, device_username?, device_name?}` + Bearer；空响应 = Done | ❌ |

### 3.8 非 api-server 的外部 HTTP（顺带记录）
- Telegram 2FA 推送：`src/auth_2fa.rs` `send_2fa_code_to_telegram` / `get_chatid_telegram` → `https://api.telegram.org/bot<token>/...` [确认]。与 api-server 无关。
- 软件更新检查、下载器（`hbbs_http/downloader.rs`）走官方地址，Porta 改名时需另行替换 [推测，未逐一核对 URL]。

### 3.9 审计重试与 rustdesk-api 的冲突（详述）[确认]
`connection.rs` `fn post_audit_async`：
- 2xx 且 body **trim 后为空** → 成功。
- 2xx 且 body 含 `error` → 重试（认为服务端写库失败、已释放 nonce）。
- 2xx 且 body 非空但无 `error` → 记为 "unexpected response body"，**重试**。
- 5xx / 408 / 429 / 网络错误 → 重试；其他 4xx → 立即放弃。
- 最多 3 次（间隔 10s、30s），总时限 120s；注释写明服务端按 `nonce` 记 5 分钟去重。

rustdesk-api `http/controller/api/audit.go` `AuditConn` / `AuditFile` 成功时 `response.Success(c, "")` → `{"code":0,"message":"success","data":""}`（`http/response/response.go`），且不读 `nonce`。结果：每条 `action:new` 和每条文件审计写 3 次；`close` 是更新所以无害。参数错误时 rustdesk-api 回 400 → 客户端不重试。

---

## 4. 客户端里按"服务端能力 / Pro"切换的分支

| 分支 | 判据（服务端返回什么） | 代码位置 | 结论 |
|---|---|---|---|
| 地址簿 legacy vs 新版 | `POST /api/ab/personal` 404 → legacy；200 + `guid` → 新版 | `ab_model.dart` `_getPersonalAbGuid`，`legacyMode` | [确认] |
| 共享地址簿 | `/api/ab/settings`、`/api/ab/shared/profiles` 404 → 只有个人本 | `_getAbSettings` / `_getSharedAbProfiles` | [确认] |
| 地址簿容量 | 新版 `max_peer_one_ab`；旧版 `licensed_devices` | `Ab.isFull` / `LegacyAb.isFull` | [确认] |
| 共享本写权限 | profile `rule`（1/2/3） | `Ab.canWrite` | [确认] |
| "Web 控制台"菜单 | 非 legacy 且可写才显示 | `address_book.dart` | [确认] |
| 设备分组 | `/api/device-group/accessible` 失败被忽略；`/api/users` 报 `Admin required!` → 提示升级 | `group_model.dart` | [确认] |
| `PRO` 标志 | `/api/sysinfo` 回 `SYSINFO_UPDATED` 即置 true | `sync.rs` | [确认] |
| PRO 的用途 ① | Windows 上 CM（连接管理窗口）启动失败时**不弹错误**（`!is_pro()` 才发 `CmErr`） | `connection.rs` 第 ~2875 行 | [确认] |
| PRO 的用途 ② | IPC 返回 `hide_cm`（隐藏连接管理窗口，配合密码安全选项）仅在 Pro 或定制客户端生效 | `ipc.rs` 第 ~979 行 | [确认] |
| 策略下发 / 远程配置 | 心跳响应的 `strategy.config_options` → 覆盖任意客户端选项；`modified_at` 做版本 | `sync.rs` `handle_config_options` | [确认] |
| 远程断开连接 | 心跳响应 `disconnect:[conn_id]` | `sync.rs` + `connection.rs` 订阅 | [确认] |
| 强制重传 sysinfo | 心跳响应含 `sysinfo` 键 | `sync.rs` | [确认] |
| 审计 conn_audit_ref | hbbs PunchHole 里的 `ControlledContext.conn_audit_ref`（`libs/hbb_common/protos/rendezvous.proto`）；OSS hbbs 不下发 | `connection.rs` `conn_audit_ref` | [确认 proto；推测 OSS hbbs 不填] |
| 设备部署门禁 | hbbs 注册响应要求部署 → 客户端节流重试并提示 `--deploy` | `rendezvous_mediator.rs` | [确认存在；推测仅 Pro hbbs 触发] |
| API 走 hbbs TCP 隧道 | 内置选项 `use-raw-tcp-for-api` 或 HTTP 失败回退 | `common.rs` `should_use_raw_tcp_for_api` / `post_request` | [确认存在；推测仅 Pro hbbs 支持] |
| 客户端本地开关 | `disable-account` / `disable-ab` / `disable-group-panel`（内置选项，定制客户端用） | `flutter_ffi.rs` `is_disable_*` | [确认] |
| 定制客户端 | `is_custom_client()`（Windows license / 内置配置） | `common.rs` `fn is_custom_client` | [确认] |

---

## 5. 与 rustdesk-api 对照

rustdesk-api 路由以 `http/router/api.go` `ApiInit` / `PersonalRoutes` / `WebClientRoutes` 和 `http/router/admin.go` 为准 [确认]。

### 5.1 两边都有（23 个）
```
GET  /api/login-options        POST /api/login              POST /api/logout
POST /api/currentUser          POST /api/oidc/auth          GET  /api/oidc/auth-query
POST /api/heartbeat (⚠️只回{})  POST /api/sysinfo            POST /api/sysinfo_ver(客户端实际不调)
GET  /api/ab                   POST /api/ab
POST /api/ab/personal          POST /api/ab/settings        POST /api/ab/shared/profiles
POST /api/ab/peers             POST /api/ab/tags/:guid      POST /api/ab/peer/add/:guid
PUT  /api/ab/peer/update/:guid DELETE /api/ab/peer/:guid    POST /api/ab/tag/add/:guid
PUT  /api/ab/tag/rename/:guid  PUT  /api/ab/tag/update/:guid DELETE /api/ab/tag/:guid
GET  /api/users                GET  /api/peers              GET  /api/device-group/accessible
POST /api/audit/conn (⚠️重试重复) POST /api/audit/file (⚠️同)
```
行为差异：
- `/api/login`：不支持 `email_check`/`tfa_check` 二次验证；`disable-pwd-login` 时回 400 错误。
- `/api/heartbeat`：不下发 `strategy` / `disconnect` / `sysinfo`。
- `/api/sysinfo`：忽略 `preset-*` 字段（自动入地址簿、自动分配用户/组/策略都不生效）[确认：`PeerForm` 只取基本字段，未逐字段列出]。
- `/api/device-group/accessible`：非管理员不返回数据 [确认 `group.go` `Device` 首行 IsAdmin 判断]。
- `/api/audit/*`：成功响应体非空，见 3.9。
- `login-options` 在没配置任何 OAuth 且关闭 web-sso 时会回 `["common-oidc/null"]`，客户端 `jsonDecode("null")` 返回 null，`queryOidcLoginOptions` 的返回类型是 `List`，[推测] 会抛类型错误，登录框只是不显示第三方按钮。

### 5.2 客户端会调、rustdesk-api 没实现（8 个）
```
POST /api/audit/alarm            — 白名单拦截/爆破告警，丢失
GET  /api/audit/conn/active      — "连接结束填备注"功能不可用
PUT  /api/audit                  — 同上
POST /api/switch-grant           — 切换控制方向的服务端授权（客户端 fire-and-forget，缺了不影响切换本身）[推测：OSS hbbs 不校验该授权]
POST /api/record                 — OSS 客户端死代码，可忽略
POST /api/devices/deploy         — 设备部署（需配合 hbbs 门禁）
POST /api/devices/cli            — 命令行分配用户/地址簿/组/策略
心跳响应中的 strategy / disconnect / sysinfo 字段（接口在，语义缺）
```

### 5.3 rustdesk-api 有、客户端从不调
- `GET /api/`、`GET /api/version`、`GET /api/user/info`（`currentUser` 的 GET 别名）。
- OAuth 浏览器回调：`/api/oauth/callback|login|msg`、`/api/oidc/callback|login|msg`（服务端自用，浏览器访问）。
- Web Client 用：`POST /api/shared-peer`、`POST /api/server-config`、`POST /api/server-config-v2`，`/webclient-config/index.js`，静态目录 `/webclient`、`/webclient2`（已删内容）。
- 静态：`/upload`、`/_admin`（Vue 管理后台）、`/swagger`。
- 管理后台 `/api/admin/*`（约 120 个路由）：用户、组、设备组、标签、地址簿、地址簿集合与共享规则、peer、OAuth 配置、登录日志、审计列表、用户 token、配置、文件上传、分享记录、`/my/*` 个人视图，以及 `/api/admin/rustdesk/sendCmd` 等（转发命令到 hbbs/hbbr 控制端口，见 6）。

---

## 6. rustdesk-api 技术栈与部署形态

- 语言/框架：Go 1.23，gin、gorm、viper、cobra、swaggo、go-oidc、golang-jwt、go-ldap、go-redis（可选缓存）、base64Captcha、go-i18n [确认 `go.mod`]。
- 数据库：gorm 三选一，**默认 SQLite**（`conf/config.yaml` `gorm.type: sqlite`），可切 MySQL / PostgreSQL [确认]。
- 端口：单进程监听 `0.0.0.0:21114`，同时承担客户端 API、管理后台静态页、Web Client 静态页 [确认]。
- 镜像：`Dockerfile` 基于 alpine，只含 `apimain`；`Dockerfile_full_s6` 把官方 `rustdesk/rustdesk-server-s6` 的 hbbs/hbbr 一起塞进 s6-overlay 做 all-in-one [确认]。
- 内存：无实测数据；Go + SQLite 小规模部署通常几十 MB 级 [推测]。可直接在现网部署的机器上 `docker stats` 看实际值。
- **与 hbbs 的关系**：
  - 不改 hbbs、不读 hbbs 数据库；在线状态靠客户端心跳自己记（`LastOnlineTime`）[确认 `index.go` `Heartbeat`]。
  - 唯一主动连 hbbs/hbbr 的是管理后台"服务器命令"：`service/serverCmd.go` `SendSocketCmd` TCP 连 `127.0.0.1:21115`（hbbs）/`21117`（hbbr）发控制命令（relay-servers、ip-blocker、always-use-relay、blacklist…）[确认]。因此要和 hbbs 同机/同网络命名空间才可用。
  - 作者另有 fork `lejianwen/rustdesk-server`，README 称解决 API 连接超时、"强制登录后才能发起连接（`MUST_LOGIN`）"、客户端 websocket；配合时 rustdesk-api 设 `jwt.key`，hbbs 用同一 key 校验客户端 token [确认 README；hbbs fork 源码未读]。
- 活跃度：本地全部 409 个提交，按月：2024-09 115、10 月 73、11 月 65、12 月 40、2025-01 21、02 36、03 10、04 8、05 8、06 12、07 10、08 4、09 7，**2025-09-29 之后无提交**（截至 2026-10-22，`git ls-remote` 确认）[确认]。issue 区仍有人反馈（如 2026-06 的 #415 评论、2026-05 的 Discussion #516 Web Client 不可用）但作者未再发版 [确认，来源见下]。
- DMCA 事件 [确认，来源见下]：2025-09-25 GitHub 用户 `open-trade`（RustDesk 主要开发者的账号 [推测，未核实身份]）在 Discussion #409 指出 `resources/web2` 是从 RustDesk 官网下载的**闭源** Web Client v2 编译产物，未经授权自托管属侵权。作者 2025-09-27 承认并删除，发 v2.7（Breaking: Removed webclient2 because of DMCA），随后清理 README、wiki、Docker 镜像（提交 `04789e0`、`2227924`、`c5687e1`）。open-trade 还表示 rustdesk 仓库里的 web v1 也已移除、v1 的许可证"显然已不是 AGPL"，对 `resources/web1` 是否侵权不置可否。管理后台的 Web Client 按钮至今仍指向已删除的 `/webclient2`（issue #415、#495）。
  - 对 Porta 的含义：RustDesk 的 Web 客户端（`flutter/web/js/`）不在开源仓库里（上游 `AGENTS.md` 也写明 gitignored、在维护者本地），**Porta 不能打包官方 Web Client，任何浏览器端远控都要自己写**。

来源：
- https://github.com/lejianwen/rustdesk-api/discussions/409
- https://github.com/lejianwen/rustdesk-api/issues/415
- https://github.com/lejianwen/rustdesk-api/releases
- https://github.com/lejianwen/rustdesk-api/issues/495
- https://github.com/lejianwen/rustdesk-api/discussions/516

---

## 7. Porta 自建 API 的最小必需集合

### 7.1 P0：不做则核心账号/地址簿不可用
| 接口 | 不实现的后果 |
|---|---|
| `GET /api/login-options` | 登录框报错、不显示第三方登录；Rust 侧 TLS 探测失败会影响后续请求 TLS 选择 [推测影响程度] |
| `POST /api/login` | 无法账号登录（可只做 `type:access_token`，不做二次验证） |
| `POST /api/currentUser` | 启动时无法校验 token，地址簿/组面板不刷新 |
| `POST /api/logout` | 注销仅本地生效（客户端吞错误），服务端 token 不失效 |
| 地址簿二选一：**旧版** `GET/POST /api/ab`（2 个接口，整本 JSON 存取，最省事）**或新版** `/api/ab/personal` + `peers` + `tags` + `peer/add|update` + `DELETE peer` + `tag/add|rename|update` + `DELETE tag`（`settings`、`shared/profiles` 可回 404 退化为只有个人本） | 地址簿 Tab 报"拉取失败" |
| `POST /api/sysinfo`（回 `SYSINFO_UPDATED`）+ `POST /api/heartbeat`（回 `{}` 即可） | 不实现也不影响远控，但服务端不知道设备列表/在线状态；sysinfo 失败每 120s 重试、heartbeat 每 3~15s 一次请求打 404，只是噪音 |

### 7.2 P1：建议首版就做（成本低、收益明确）
- 心跳响应下发 `strategy.config_options` + `modified_at`：**Porta 智能路由的最佳下发通道**（可直接推 `relay-server`、`custom-rendezvous-server` 等选项）；`disconnect` 可实现后台踢连接。
- `POST /api/audit/conn` / `file` / `alarm`：**成功必须回空 body**，按 `nonce` 5 分钟去重。
- `GET /api/users`、`GET /api/peers`：组面板（"可访问设备"），个人用可只返回自己和自己的设备；`device-group/accessible` 可回 404（客户端忽略）。

### 7.3 可以先不做
- 新版地址簿的共享部分（`shared/profiles`、`settings` 回 404 即可）。
- 邮箱验证码 / TOTP 登录二次验证。
- OIDC（`oidc/auth`、`auth-query`）——个人项目可后补；需要时对接 Headscale 同一 IdP [推测可行]。
- `audit/conn/active` + `PUT /api/audit`（连接备注）。
- `switch-grant`、`devices/deploy`、`devices/cli`（需配合 hbbs 门禁，Porta 若改 hbbs 再议）。
- `record`（OSS 死代码）、`sysinfo_ver`（客户端不调）。
- 管理后台：首版可以没有 Web UI，用 CLI 管用户。

### 7.4 实现时必须复刻的"暗号"（任何一个写错，客户端就会走错分支）
1. `/api/ab/personal` 不支持时回 **404**（不是 200+error），否则地址簿整体报错而不是退回 legacy。
2. `/api/ab/settings`、`/api/ab/shared/profiles` 不支持时回 **404**。
3. sysinfo 成功回纯文本 `SYSINFO_UPDATED`；未知设备回 `ID_NOT_FOUND`。
4. OIDC 轮询未完成回 `{"error":"No authed oidc is found"}`（含该子串即可）。
5. 审计成功回 **空 body**。
6. token 无效回 **401**（客户端据此清登录态）；`/api/currentUser` 回 400 也会清 token。
7. `/api/ab/tags/<guid>` 顶层是数组；分页接口用 `current`/`pageSize`，返回 `{total, data}`；legacy `/api/ab` 的 `data` 是**字符串化的 JSON**。
8. Rust 侧解析 `UserPayload` 要求 `name`、`info` 字段存在（OIDC 路径）。

---

## 8. 需要架构拍板的方向性问题

1. **地址簿只做旧版还是新版**：旧版 2 个接口、整本覆盖写；新版 12 个接口、支持多本/共享/标签增量。个人自用旧版够用；要给朋友共享设备则需新版。
2. **设备态接口要不要加认证**：上游 heartbeat/sysinfo/audit 只凭 `id+uuid`，任何知道这两个值的人都能伪造设备上报、通过 `strategy` 拉取配置。Porta 既然改客户端，可以仿 `switch-grant` 用设备 Ed25519 私钥签名（服务端用 hbbs 注册时的公钥验）。代价：改客户端 `sync.rs`、`connection.rs`，偏离上游。
3. **智能路由的配置通道**：直接复用心跳 `strategy.config_options`（零协议改动，但只能下发"选项值"，粒度是整个客户端），还是另设专用接口（可下发多中继候选列表 + 延迟探测策略）。上游客户端只支持一个 `relay-server` 值，多中继选择无论如何要改客户端。
4. **API 服务端形态**：独立进程（同 rustdesk-api，监听 21114）还是并入 Porta 自己的 hbbs 进程。并入可共享设备公钥/在线状态（解决问题 2、省掉心跳记在线），但 hbbs 是 Rust、rustdesk-api 是 Go，决定了重写语言。
5. **是否兼容官方/第三方客户端**：若 Porta 服务端也要服务未改过的 RustDesk 客户端，第 7.4 节的暗号必须全保留，且不能强制签名认证。
6. **Web 客户端**：官方 Web Client 闭源且已有 DMCA 先例，Porta 若要浏览器远控只能自研；建议明确列入"首版不做"。
