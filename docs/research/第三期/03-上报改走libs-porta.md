# 第三期调研 03：心跳、sysinfo、审计改走 libs/porta 的新 API 客户端

> Porta 是当时的工作名，2026-10-24 改名为 Leapgate（跃门）。
> 2026-10-23 写。基线：客户端 `rustdesk@bd92623`（`porta-client` main 在 `ea74616`，`sync.rs`、`server/connection.rs` 和基线逐字相同），服务端 `porta-server@7c85b95`。
> 标记：【读码】读代码确认；【推测】推断或估算，未编译、未实测；没有【实测】结论。
> 设备签名的具体算法、要签哪些字段由同期的设备签名笔记定，本文只定它和 API 客户端的接口；路由第二级的测速和选路算法由路由笔记定，本文只定心跳怎么捎带它的数据。

## 0. 要回答的问题

1. 上游现状：心跳、sysinfo、策略下发、审计各有哪些调用点，什么时候调，请求体是什么，走的是哪套 HTTP 栈。
2. 挂钩：在 `sync.rs`、`connection.rs` 里怎么做到"加挂钩、关掉上游调用、不删"，最少几行；Porta 客户端连到原版 hbbs 或 rustdesk-api 时怎么退回上游调用。
3. 新 API 的形态：路径、请求和响应格式、和现有兼容接口怎么共存；心跳响应怎么带路由第二级的候选中继和策略版本；双方怎么知道对方是 Porta。
4. `libs/porta` 里 API 客户端的结构：HTTP 库、代理和 TLS、重试和退避、和设备签名怎么衔接。
5. 服务端第一期的上报限速、设备表行数上限、延迟补绑，新接口怎么复用。
6. 影响面：动哪些上游文件、大约多少行、和第二期改名换标有没有冲突。

## 1. 读码结论

### 1.1 心跳、sysinfo、策略下发：一个循环包办【读码】

全在 `rustdesk@bd92623:src/hbbs_http/sync.rs` 的 `start_hbbs_sync_async` 里，是一个独立线程上的 current_thread tokio 运行时。

- **启动**：`src/rendezvous_mediator.rs` `RendezvousMediator::start_all` 调 `crate::hbbs_http::sync::start()`，`start` 触发 `lazy_static SENDER` 初始化，后者起线程跑 `start_hbbs_sync_async`。只在被控服务所在的进程里跑（安装版是 `--server` 进程，便携版是主进程），被控端的连接（`Connection`）也在同一个进程里。iOS 不编译这段。
- **节拍**：`interval` 每 3 秒一次（`TIME_CONN`）。每次 tick：
  1. `heartbeat_url()`：`get_api_server(api-server, custom-rendezvous-server)` 加 `/api/heartbeat`；地址为空或是 RustDesk 公共服务器时返回空串，这一轮跳过，`PRO = false`。
  2. `stop-service` 为 Y 时跳过。
  3. 每次都调一遍 `crate::get_sysinfo()`（`src/common.rs`，刷新内存和 CPU 信息），拿当前系统用户名。
  4. **sysinfo 上传**，条件是"还没成功上传过，或者用户名变了"，并且距上次失败已满 120 秒（`UPLOAD_SYSINFO_TIMEOUT`）。请求体是 `get_sysinfo()` 的 `cpu`、`memory`、`os`、`hostname`、`username`，再加 `version`（`crate::VERSION` 字符串）、`id`、`uuid`（`encode64(get_uuid())`），以及一串预置选项：`preset-address-book-name/tag/alias/password/note`、`preset-user-name`、`preset-strategy-name`、`preset-device-group-name`（后三个读内置选项），`preset-device-username` 和 `preset-device-name` 会覆盖 `username`、`hostname`，`preset-note`。`POST {api}/api/sysinfo`。回 `SYSINFO_UPDATED` 算成功并置 `PRO = true`；回 `ID_NOT_FOUND` 下一轮重传；其他回应或出错等 120 秒。
     - sysinfo 去重那段（对 url + 请求体做 sha256，和 `Status` 里的 `sysinfo_hash` 比较，再问 `/api/sysinfo_ver`）包在 `if crate::is_public(&url)` 里，而 `heartbeat_url()` 对公共服务器返回空串，所以**自建服务器上这段永远不执行**：每次进程启动都会重传一次 sysinfo。
  5. **心跳**：有活动连接时每次 tick 都发（3 秒一次），没有连接时 15 秒一次（`TIME_HEARTBEAT`）。请求体 `{id, uuid, ver, conns?, modified_at}`：`ver` 是 `get_version_number(VERSION)` 的整数，`conns` 是 `Connection::alive_conns()`（连接号列表，没有连接时不带），`modified_at` 是 LocalConfig 的 `strategy_timestamp`。`POST {api}/api/heartbeat`。
  6. **心跳响应**只看键在不在：`sysinfo` → 清 `sysinfo_hash`、下一轮重传；`disconnect` → 经 `SENDER` 广播给各 `Connection`，断开这些连接号；`modified_at` → 写回 `strategy_timestamp`；`strategy` → `handle_config_options(strategy.config_options)`。未知键忽略。
- **策略应用** `handle_config_options`：增量合并进 `Config` 的 options（被控服务进程的 Config），空值且 `DEFAULT_SETTINGS` 里没有默认值时删键，否则写入。它是 `sync.rs` 的私有函数，只用到 `hbb_common::config`。
- **`is_pro()`**：sysinfo 成功后为真。基线里还剩两处用它：`src/ipc.rs` 的 `hide_cm`（`is_pro() || is_custom_client()`，Porta 是定制客户端，这里不受影响）和 `src/server/connection.rs` `try_start_cm_ipc` 里 CM 启动失败时是否弹错误（`!is_pro()` 才弹；只在 Windows 编译，另有"不在登录前""错误里不含 explorer.exe"两个条件）。
- 同文件里还有 `register_switch_grant`（`/api/switch-grant`），用设备私钥 `Config::get_key_pair().0` 对 `"switch-grant\0" id \0 verifier \0 timestamp` 做 Ed25519 签名，服务端拒绝时间戳就带回 `server_time`，客户端用它重签重试一次。这是上游现成的"设备签名 + 时钟偏差纠正"范例，设备签名笔记可以照着做。porta-server 第一期没实现这个接口。

### 1.2 审计：三个入口，一个出口【读码】

都在 `rustdesk@bd92623:src/server/connection.rs`，由被控端发出。地址是 `get_audit_server(api, custom, typ)` = `{api}/api/audit/{conn|file|alarm}`，公共服务器时为空、不发。

| 入口 | 调用时机 | 请求体 | 发送方式 |
|---|---|---|---|
| `post_conn_audit` | `on_open` 连接建立（`action:"new"`，带 `ip`、`conn_audit_ref`）；认证成功（无 action，带 `peer:[id,name]`、`type`、`primary_auth`、`two_factor`）；连接循环结束（`action:"close"`） | 公共字段 `id`、`uuid`、`conn_id`、`session_id`、`nonce` | 进 `tx_post_seq` 队列，`post_seq_loop` 按顺序逐条发（保证 new → 认证 → close 的顺序） |
| `post_file_audit` | 文件传输收发、剪贴板文件收发、打印，共 6 处（打印和文件发送共用一处） | `id`、`uuid`、`peer_id`、`conn_id`、`type`（0 发送、1 接收）、`path`、`is_file`、`info`（JSON 字符串：ip、name、num、最大的 10 个文件）、`nonce` | `tokio::spawn` 单发 |
| `post_alarm_audit` | IP 白名单、ID 白名单、密码试错 30 次、1 分钟 6 次、IPv6 前缀试错、终端登录退避和并发、会话越权，共 8 处（会话越权那处经 `post_session_scope_violation_alarm` 包一层） | `id`、`uuid`、`typ`、`info`（JSON 字符串）、`conn_id`、`nonce`、白名单类带 `conn_audit_ref` | `tokio::spawn` 单发 |

三者最后都进 `post_audit_async(url, v)`：调 `crate::post_request_with_status`，2xx 且空 body 算成功；2xx 带 `{"error"}` 或其他非空 body、5xx、408、429、网络错误算可重试；其他 4xx 放弃。重试间隔 10 秒、30 秒，总时限 120 秒（服务端 nonce 去重只记 5 分钟）。

控制端写备注的请求有两条，都发自控制端进程，不属于被控端（设备）上报（核对后更正，见 §5）。第一条不带任何凭据，第二条带登录令牌（第二轮核对更正，原写"身份是登录用户"，见 5.4）：

- 会话中工具栏"Note"（`flutter/lib/common/widgets/toolbar.dart` → `dialog.dart` `showAuditDialog` → `bind.sessionSendNote`）由 **Rust** 发：`rustdesk@bd92623:src/ui_session_interface.rs` `Session::send_note` → `send_note`，`POST {api}/api/audit/conn`，请求体 `{id, session_id, note}`（没有 `uuid`、`nonce`），用普通 `post_request`、header 传空串（不带令牌）、不重试，只有本地有 `access_token` 时 URL 才非空（`Session::get_audit_server`）。porta-server 兼容接口按"有 `note` 没 `uuid`"处理的就是这条。
- 连接结束弹的备注框由 Dart 发（`dialog.dart` `updateAuditNoteByGuid`），是 `PUT {api}/api/audit`、`{guid, note}` 加 Bearer，Pro 专有，porta-server 不实现（`PORTA.md` §1）。

原结论是"**不在本次范围**，随新界面轨道一起下沉"，理由是"它是 Dart 发的，不在 Rust 里"。**前提不成立，见核对记录**：第一条在 Rust 里。

### 1.3 HTTP 栈【读码】

全在主 crate（`src/common.rs`、`src/hbbs_http/http_client.rs`）里，**`libs/porta` 调不到**：`libs/porta` 只依赖 `hbb_common` 和 `base`，主 crate 依赖它，反过来调会成环。

- `post_request(url, body, header)` = `with_tcp_proxy_fallback(post_request_http, post_request_via_tcp_proxy)`：
  - 内置选项 `use-raw-tcp-for-api=Y`、没开 WebSocket、且目标主机就是 API 主机时，直接走 TCP 代理。
  - 否则先发 HTTP；出错或 5xx 时，如果没开 WebSocket、目标主机就是 API 主机，就改走 TCP 代理：连会合端口 21116、做 `secure_tcp`、发 `HttpProxyRequest`，总时限 `CONNECT_TIMEOUT + READ_TIMEOUT` = 36 秒。porta-server 第一期不实现 `HttpProxyRequest`（`PORTA.md` §1），所以这条回退在 Porta 部署里不会成功。不过它通常很快失败，不会白等 36 秒（核对后更正，见 §5）：porta-server 收到 `HttpProxyRequest` 时落进 `handle_tcp` 的 `_ => {}`、返回 false，连接随即关闭（`porta-server@7c85b95:src/rendezvous_server.rs` `handle_listener_inner`），客户端读到连接关闭就报错（`tcp_proxy_request` 的 `None` 分支）。只有 21116 也连不上（整机宕机、被丢包）时，才会等到建连超时 18 秒，整体最多 36 秒。另一种慢的情况是 porta-server 没持有私钥：它不先发 `KeyExchange`，客户端在 `key_exchange` 里等第一帧，要等 `READ_TIMEOUT` 18 秒（第二轮核对补充；按 `PORTA.md` §6 第 1 条，没有私钥时登录过的客户端本来就连不上，部署都会配私钥，所以这种情况只出在配错时）。
  - 4xx 原样返回。
- `post_request_`：reqwest 0.12，每次尝试超时 12 秒（含建连和 TLS）。`header` 参数只支持**一个** `Key: Value`。按"主机:端口"缓存 TLS 类型。请求阶段出错（`e.is_request()`，不限于 TLS 握手：reqwest 0.12.28 把连接被拒、DNS 失败、TLS 失败和 12 秒超时都归为这一类，第二轮核对补读）时的重试分两种情况（核对后更正，见 §5）。`http://` 地址不重试：TLS 类型直接取 `Plain`，只发一次。
  - **默认**（选项 `allow-insecure-tls-fallback` 没打开）：`hbb_common::tls::get_cached_tls_accept_invalid_cert` 直接返回 `Some(false)`，所以只是 rustls 失败后换 native-tls 重试一次，两次都严格校验证书，不会接受无效证书。
  - **用户在设置里打开 `allow-insecure-tls-fallback`**（界面提示文字 `allow-insecure-tls-fallback-tip`，默认关）：rustls 严格 → rustls 接受无效证书 → native-tls 严格 → native-tls 接受无效证书，最多 4 次。成功后按"主机:端口"把"接受无效证书"记进进程内缓存。这种情况下，中间人出示自己的证书就会让第一次校验失败，客户端随后接受它的证书。
  - 这个选项是普通 `Config` 选项，心跳下发的策略也能写它（见 §2.4 响应签名那条）。
- 代理：`configure_http_client!` 宏读 `Config::get_socks()`，经 `hbb_common::proxy::Proxy` 配成 reqwest 的 http/https/socks5 代理，`no_proxy()` 关掉系统代理。这些类型都在 `hbb_common` 里，`libs/porta` 能直接用。
- 另有 `create_http_client_async_with_url_strict`（异步，下载器 `downloader.rs` 用）和 `create_http_client_with_url_strict`（同步，更新器 `updater/` 用），只收 HTTPS、不接受无效证书。
- `post_request_with_status` 和 `post_request` 同规则，只是多返回状态码，审计用它。

### 1.4 libs/porta 能直接拿到的东西【读码】

经 `hbb_common`：`Config::get_id()`、`get_uuid()`、`Config::get_key_pair()`（设备 Ed25519 密钥对）、`Config::get_option`、`Config::get_options/set_options`、`LocalConfig`、`config::DEFAULT_SETTINGS`、`config::BUILTIN_SETTINGS`（`get_builtin_option` 就是读它）、`Config::get_socks()`、`hbb_common::proxy`、`get_version_number`、`sodiumoxide`。

拿不到、要由挂钩传进来的：`crate::get_sysinfo()`（要 `crate::platform::get_active_username`）、`Connection::alive_conns()`、`crate::VERSION`（编译时生成的 `src/version.rs`）、API 地址（`get_api_server` 在主 crate；但挂钩处 `heartbeat_url()` 和审计 URL 已经算好了，传进来就行）。

### 1.5 服务端第一期现状【读码】

`porta-server@7c85b95`：

- 路由表 `src/api/mod.rs` `router`：`/api/sysinfo`、`/api/heartbeat`、`/api/audit/{conn,file,alarm}`。`is_report()` 给这几条 10 秒整请求超时；`internal_error_is_200()` 让审计的内部错误回 200 + `{"error"}`。
- `src/api/device.rs`：
  - `report_allowed(ip)`：心跳、sysinfo、三个审计合计每来源每分钟 1000 次，计数表最多 65536 个来源。
  - `uuid_matches(db, id, uuid)`：`peer` 表里有这个 id，且 uuid 逐字节相符。
  - `make_room(tx, id)`：设备表 1 万行上限，满了按 `last_seen_at` 淘汰可淘汰行。
  - `OWNER_FROM_TOKEN`：延迟补绑的子查询，绑定 `?1` = id、`?2` = uuid。
  - `sysinfo`、`heartbeat` 两个 handler 把"限速 → 解析 → 身份校验 → 写设备行"写在一起，心跳最后再算策略。`client_type` 只在 sysinfo 的 SQL 里写死为 `'rustdesk'`；心跳新建行时不写这一列，靠表默认值 `'rustdesk'`（`migrations/0001_init.sql`），更新时不碰它（核对后补充，见 §5）。
- `src/api/audit.rs`：`admit`（限速 + 解析）、`report(db, id, uuid, nonce, write)`（nonce 去重 → `uuid_matches` → 执行写入 → 登记 nonce）、`write_conn`、`file`/`alarm` 里的写入、`make_room`（每表 2 万行）。
- `src/strategy.rs` `effective(db, id) -> (rev, options)`：生效选项和版本号，和客户端用什么路径无关。
- `get_server_sk` 的私钥只在 `RendezvousServer` 的 `inner.sk` 里，API 侧拿不到（`PORTA.md` §3 写明以后要签名时再挪进 `AppState`）。

## 2. 设计

### 2.1 总体路线

**推荐：新路径 + 上游组包复用（方案甲）**

- 心跳和 sysinfo：`libs/porta` 自己实现一个 tick，挂在上游 tick 的开头；服务端支持 Porta API 时由它处理这一轮，上游那一轮直接 `continue`，否则照走上游。
- 审计：挂在 `post_audit_async` 开头。请求体沿用上游已经组好的 JSON（三个入口、17 个调用点都不用碰），只是改发到 Porta 路径、加签名、按 Porta 的规则重试。
- 服务端新增 `/api/porta/v1/` 下的两类接口（心跳、审计），内部复用第一期的限速、身份查询、行数上限和写库函数。

**备选：旧路径加签名头（方案乙）**

不加新路径。在上游 4 处 `post_request` 调用（3 处在 `sync.rs`，1 处在 `post_audit_async`）把 header 参数从 `""` 换成签名头，在心跳请求体里加 Porta 字段，在心跳响应处理里加一个钩子读 Porta 的键。

- 好处：服务端不加路由；"退出兼容"就是在原路径上强制要签名。
- 代价：挂钩分散在 5~7 处，每处都在上游会改的语句里；上游的约定值（`SYSINFO_UPDATED`、审计空 body、5xx 触发 TCP 回退、接受无效证书的 TLS 回退；后两条的实际代价比原文说的小，TCP 回退在 porta-server 上很快失败，TLS 回退默认不开，见 §5）在 Porta 客户端里永远留着，和 §3.1 兼容债务第 2、5 条"换成正式的能力协商、重新设计接口形态"相反；`post_request` 只能带一个请求头。

**不选：把审计组包也搬进 libs/porta。** 审计的字段来自 `Connection` 的私有状态（`lr`、`ip`、`controlled_context`、认证方式等），搬过去要么把这些状态一个个传出来，要么改上游的 17 个调用点，都违反 §3.3。

### 2.2 挂钩怎么下（问题 2）

一共两处，加起来 2 条语句；格式化后约 8 行。`porta::report` 是 `libs/porta` 新加的模块。

**① `src/hbbs_http/sync.rs` `start_hbbs_sync_async`，放在 `stop-service` 检查之后、`Connection::alive_conns()` 之前：**

```rust
                if porta::report::tick(&url, crate::get_sysinfo, Connection::alive_conns, crate::VERSION).await {
                    continue;
                }
```

- 放在这里，上游已经替 Porta 算好了 API 地址（`url`，公共服务器和空地址已经被过滤掉），也已经判断过 `stop-service`。注意 `url` 是 API 地址加上 `/api/heartbeat`，不是 API 根地址，`libs/porta` 要自己去掉这段后缀再拼 Porta 路径（第二轮核对补充）。
- 传函数指针而不是闭包，`libs/porta` 不依赖主 crate。
- 返回 `true` 表示这一轮已由 Porta 处理（成功或失败都算），上游这一轮整个跳过，包括每 3 秒一次的 `get_sysinfo()`。返回 `false` 时往下走上游原逻辑，上游的状态（`info_uploaded`、`last_sent`）一直原样保留。
- 不另建 glue 文件、也不改 `lib.rs`：四个参数够用。

**② `src/server/connection.rs` `post_audit_async` 函数体第一行：**

```rust
        if let Some(res) = porta::report::audit(&url, &v).await {
            return res;
        }
```

- `url` 末段就是 `conn`/`file`/`alarm`，前缀就是 API 地址。
- 返回 `None` 时走上游原有的发送和重试。
- 放在这里，`post_seq_loop` 的顺序保证不受影响。

**怎么判断走不走 Porta（含退回上游）**：

- `libs/porta` 按 API 地址缓存服务端能力，进程内一个 `static`。心跳和审计在同一个进程里，共用这份缓存。
- 能力未知时，先发 Porta 心跳（审计挂钩遇到能力未知，也先试 Porta 路径）：
  - 回 2xx 且是 Porta 格式的 JSON → 记为"支持"。
  - 回 404 或 405 → 记为"不支持"，返回 `false`/`None`，退回上游。porta-server 第一期对未知路径回 404（`api/mod.rs` `not_found`）【读码】；rustdesk-api 用 Gin，`NoRoute` 兜底回 404 + 纯文本 `404 not found`，`/api` 下没有通配路由【读码，核对时补读：`rustdesk-api@c5687e1:http/http.go`】。
  - 连不上 → 不改缓存，返回 `false`/`None`，让上游照常去试。这样在 API 根本不可达时，客户端的行为和上游完全一样（反正都失败），也不会对一个不支持的服务端每 3 秒多打一次请求。
- 记为"不支持"的地址每 10 分钟重新探测一次；地址变了就清空缓存。
- 能力已知为"支持"之后，遇到网络错误、5xx、401 都由 Porta 自己处理（重试或等下一轮），不退回上游的不签名路径。是否在服务端回 404 时退回，见 §3 问题 2（防降级）。

**`is_pro()` 不加挂钩**：走 Porta 路径时 `PRO` 一直为假，唯一可见的差别是 CM 启动失败时会弹错误（上游 Pro 用户不弹）。弹出来反而有用；而且 `hide_cm` 那一处已经被 `is_custom_client()` 覆盖。要和上游行为一致时，在 `is_pro()` 里加 1 行 `|| porta::report::is_porta()` 即可。

### 2.3 新 API 的形态（问题 3）

**路径**：前缀 `/api/porta/v1/`，大版本号写在路径里，小的增量能力用心跳响应里的 `features` 列表宣告。

| 接口 | 用途 | 替代的兼容接口 |
|---|---|---|
| `POST /api/porta/v1/heartbeat` | 心跳 + sysinfo + 策略下发 + 路由第二级数据 | `/api/heartbeat`、`/api/sysinfo`、`/api/sysinfo_ver` |
| `POST /api/porta/v1/audit/{conn,file,alarm}` | 被控端审计，请求体和兼容接口相同 | `/api/audit/{conn,file,alarm}`（备注那条除外） |

**推荐把 sysinfo 并进心跳**，不单设接口：请求里带 `sysinfo_hash`，服务端发现和库里不一致（或库里还没有）时回 `need_sysinfo: true`，客户端下一次心跳带完整 `sysinfo` 对象。这样 `SYSINFO_UPDATED`、`ID_NOT_FOUND`、`sysinfo_ver`、120 秒冷却这几套约定都不需要了。备选是单独一个 `/api/porta/v1/sysinfo`，多一个接口、多一套重试状态。

**不设单独的 hello/能力接口**：第一次心跳本身就是协商，响应里带 `api` 版本、`features` 和服务器时间。

**心跳请求**（JSON）：

```json
{
  "id": "123456789",
  "uuid": "<base64>",
  "ver": 1005001,
  "porta": "0.3.0",
  "conns": [3, 4],
  "strategy_rev": 812345678901,
  "routing_rev": 17,
  "sysinfo_hash": "<base64 sha256>",
  "sysinfo": { "cpu": "…", "memory": "…", "os": "…", "hostname": "…", "username": "…", "version": "1.5.1", "preset-…": "…" },
  "probes": [ { "relay": "relay1.example.com:21117", "rtt_ms": 23 } ]
}
```

- `ver`、`uuid` 和兼容接口同义，服务端的写库函数原样复用。
- `porta` 是 Porta 自己的版本号，`crate::VERSION` 保持上游格式不动（第一期笔记 01 §6.2 第 1 条）。
- `strategy_rev` 就是兼容接口里的 `modified_at`。客户端继续存在 LocalConfig 的 `strategy_timestamp` 里，不另起键：服务端两条路径算出来的 `rev` 相同，所以 Porta 路径和上游路径来回切换时不会重推一遍策略，"首次接入时清一次 `relay-server`"的语义也不变。
- `sysinfo` 只在服务端要求或本地哈希变了时带；字段和上游 sysinfo 请求体相同（含预置选项）。哈希只对 sysinfo 对象算，不含 url。
- `probes` 和 `routing_rev` 的具体内容归路由笔记，这里只占位。

**心跳响应**（JSON，可选键不出现就是没有，不给 null）：

```json
{
  "api": 1,
  "features": ["sysinfo-in-heartbeat"],
  "time": 1761200000,
  "need_sysinfo": true,
  "strategy": { "rev": 812345678901, "options": { "relay-server": "" } },
  "routing":  { "rev": 17, "probe_interval_secs": 300, "relays": [ { "host": "relay1.example.com:21117" } ] }
}
```

- `strategy` 只在请求的 `strategy_rev != rev` 时出现，规则和兼容接口相同（`PORTA.md` §10）；`options` 由 `libs/porta` 按 `handle_config_options` 同样的合并规则应用（约 15 行，只用 `hbb_common`）。
- `routing` 同理，只在 `routing_rev` 变了时出现：候选中继列表、测速间隔，内容由路由笔记定。这就是方案 §3.7 第二级说的"服务端把候选中继列表下发给客户端"。
- `time` 是服务器的 unix 秒，给签名做时钟校正用（见 §2.4）。
- `disconnect` 第一期没做，这里先不定义（见"明确不做"）。

**审计**：请求体就是上游 `post_audit_async` 收到的那个 JSON，原样发出。响应：成功 200 + `{}`；重复 nonce 同样回 200 + `{}`。

**错误码**：Porta 客户端没有 TCP 代理回退，所以 Porta 路径可以用正常的 HTTP 状态码，不受 `PORTA.md` §9.1 第 1 条"不回 5xx"约束：

| 状态码 | 含义 | 客户端怎么做 |
|---|---|---|
| 400 | 请求格式错误 | 不重试 |
| 401 | 签名无效、设备未注册、时间戳超窗口（响应带 `time`） | 带 `time` 的按服务器时间重签、立即重试一次；其余等下一轮 |
| 413 | 请求体过大 | 不重试 |
| 429 | 超出来源限速 | 心跳等下一轮，审计按退避重试 |
| 503 | 内部错误或整请求超时 | 同上 |

错误体统一是 `{"error": "<机器可读的码>", "message": "…"}`。

**和兼容接口的关系**：

- 两套路径并存，写同一批表（`device`、三张审计表），共用同一个来源限速额度，算出同一个策略 `rev`。
- `device.client_type`：经 Porta 路径写的是 `porta`，经兼容路径写的是 `rustdesk`，按"最近一次走的路径"覆盖。这满足 §3.1 退出机制第 1 条"命令行能列出还在用原版的设备"。
- 退出兼容时按 §3.1 的两步走：先由开关让兼容的上报路径拒绝请求（心跳回 `{}`、sysinfo 回 403、审计回 200 但不入库），稳定后删掉兼容 handler。Porta 路径不用改。

**双方怎么认出对方**：

- 客户端认服务端：§2.2 的能力缓存（心跳响应里的 `api` 字段）。
- 服务端认客户端：请求走的是 Porta 路径并且签名验证通过。会合层的 `client_info` 字段（第一期笔记 01 §6.2 第 3 条）是另一条线，由设备签名笔记或路由笔记决定要不要做，本文不依赖它。

### 2.4 libs/porta 里 API 客户端的结构（问题 4）

```
libs/porta/src/
  api/mod.rs        HTTP 客户端：建 reqwest Client（代理、TLS）、post_json、错误分类
  report/mod.rs     能力缓存、tick()、audit() 两个挂钩入口
  report/heartbeat.rs  心跳组包、sysinfo 哈希、响应处理、策略应用
  report/audit.rs   审计发送与重试
```

预计约 500~600 行（含单元测试另计）【推测】。

**HTTP 库：推荐 libs/porta 自己用 reqwest 0.12。**

- 主 crate 已经依赖 `reqwest 0.12`（`rustls-tls`、`socks`、`native-tls` 等），`libs/porta` 声明同一版本、特性取子集，Cargo 会特性合并，不新增要编译的包。前提是 `libs/porta` 也写 `default-features = false`：reqwest 0.12.28 的默认特性会带进 `h2`、`encoding_rs`，而现在的 `Cargo.lock` 里没有这两个包（第二轮核对补读，见 5.4）。
- 代理照抄 `configure_http_client!` 里读 `Config::get_socks()` 那一段（约 30 行），保证配了代理的被控端照样能上报。
- **TLS 用严格校验**：不做"握手失败就接受无效证书"的回退。理由见下一条和 §3 问题 3。（**前提不成立，见核对记录**：上游默认本来就严格校验，只有用户打开 `allow-insecure-tls-fallback` 才回退。这里真正要定的是 Porta 路径是否无视这个选项。）
- 没有 TCP 代理回退：porta-server 不实现 `HttpProxyRequest`，上游那条回退没有用。21116 可达时它很快失败，多出一次 TCP 建连和密钥交换；21116 也不可达时最多多等 36 秒（核对后更正，见 §5）。
- 超时 12 秒，和上游一致；服务端上报类整请求超时 10 秒（`PORTA.md` §9.4），两边对得上。
- 备选是由主 crate 在启动时注入一个发送函数（`porta::api::set_transport(...)`，再多一处挂钩），复用 `post_request_with_status`。好处是 TLS 缓存和代理配置只有一份；坏处是连同接受无效证书的回退、白等 36 秒的 TCP 回退一起继承下来。不推荐。（**前提不成立，见核对记录**：无效证书回退默认关；TCP 回退在 porta-server 上通常很快失败。这个备选剩下的坏处是：选项一开就继承回退、不可达时多一次建连，另外 `post_request_with_status` 只能带一个请求头。）

**重试和退避**：

- 心跳不重试：下一次 tick 就是重试。连续失败时把间隔从 3 秒退到最多 60 秒，成功后复位，免得服务端宕机时每台设备每 3 秒打一次【推测：上游是固定间隔，这一条是 Porta 自己加的，可以不做，见 §3 问题 5】。
- 审计照搬上游的规则：间隔 10 秒、30 秒，总时限 120 秒，nonce 不变；**每次重试重新签名**（时间戳要新）。
- 心跳节拍照上游：有连接时 3 秒、无连接时 15 秒。sysinfo 由 tick 调 `get_sysinfo` 算，但 Porta 只在发心跳那一轮算，不像上游每 3 秒算一次。

**和设备签名怎么衔接**：

- 签名由设备签名笔记定算法和被签内容；API 客户端只调一个函数，比如 `porta::sign::auth_header(method, path, body, server_time_offset) -> String`，把结果放进 `Authorization: Porta-Device …` 请求头。私钥用 `Config::get_key_pair().0`，`libs/porta` 能直接拿到；服务端用 `peer.pk`（设备在 hbbs 注册时上报的公钥）验签。
- 时钟偏差：照 `register_switch_grant` 的办法，401 响应带服务器时间，客户端记下偏移量、重签重试一次；心跳响应的 `time` 也随时更新这个偏移量。
- 建议同时让服务端**给心跳响应签名**（用会合服务器的私钥，客户端本来就配了它的公钥 `key`）。原因：Porta 默认推出来的 API 地址是 `http://<会合主机>:21114`（`libs/porta` `brand::default_api_server`；这是构建没注入 `PORTA_API_SERVER`、用户也没填 `api-server` 时的结果。用户只填了自定义会合服务器时，上游 `get_api_server_` 同样推出 `http://<主机>:21114`），明文 HTTP 上任何中间人都能往 `strategy.options` 里塞选项，而这些选项会直接写进被控服务的 Config。核对时补充：能塞的选项包括 `allow-insecure-tls-fallback=Y`，写进去之后，上游 HTTP 栈遇到证书校验失败就会改为接受无效证书再试（不是直接关掉校验，第二轮核对改了措辞）【读码】。请求签名只防伪造上报，防不住篡改下发。要做的话，服务端得把 `inner.sk` 挪进 `AppState`（`PORTA.md` §3 已预留）。这一条交给设备签名笔记一起定，见 §3 问题 3。

### 2.5 服务端复用第一期逻辑（问题 5）

原则：**新接口只换"身份校验"和"响应格式"两层，中间的限速、建行、补绑、写审计全部调用同一批函数**。为此要把现在写在 handler 里的中间层抽成函数，兼容 handler 也改成调用它们，两边不各存一份。

| 第一期逻辑 | 现在在哪 | 新接口怎么用 |
|---|---|---|
| 来源限速 | `device::report_allowed(ip)` | 原样调用，两条路径共用一份额度 |
| 身份校验 | `device::uuid_matches` | Porta 路径换成验签（查 `peer.pk`，先查内存里的 `PeerMap`，再查主池），兼容路径不变。验签通过后不再比 uuid，但请求里的 uuid 照样存、照样用于补绑 |
| 设备行写入 + 行数上限 + 延迟补绑 | `device::heartbeat` 里那段 select / update / `make_room` + insert，和 `device::sysinfo` 里那段 insert | 抽成 `device::touch(db, id, uuid, ver, ip, client_type) -> Option<bool /*没有 sysinfo*/>` 和 `device::store_sysinfo(db, id, uuid, raw, fields, client_type) -> bool`，`make_room`、`OWNER_FROM_TOKEN` 都在里面；SQL 里写死的 `'rustdesk'` 改成参数 |
| 策略 | `strategy::effective` | 原样调用 |
| 审计去重、写库、行数上限 | `audit::report(db, id, uuid, nonce, write)`、`write_conn` 等 | `report` 的 `uuid` 参数换成一个"身份已校验"的入参（例如枚举：`Uuid(&str)` 或 `Verified`），`write_conn`、file、alarm 的写入和 `make_room` 不动 |
| 字段截断 | `clip`、各 `MAX_*` 常量 | 原样调用 |

另外要改的几处小地方：

- `api/mod.rs` `router` 加 4 条路由；审计那 3 条挂 `AUDIT_BODY_LIMIT`（64 KB）；心跳用默认的 16 KB（sysinfo 原文上限 8 KB，加上几十条测速结果也够）。
- `is_report()` 加上 `/api/porta/v1/` 前缀，拿 10 秒超时。
- `internal_error_is_200()` 不认 Porta 路径；超时和 panic 的兜底响应在 Porta 路径上改回 503 + `{"error"}`。
- 验签放在一个 axum 提取器里（例如 `DeviceAuth`），心跳和审计共用。
- 服务端 `heartbeat` 在 Porta 路径上判断要不要 sysinfo：比较请求的 `sysinfo_hash` 和库里存的哈希。要不要给 `device` 表加一列 `sysinfo_hash`：**推荐不加**，用 `sha256(device.sysinfo)` 当场算（8 KB 以内，开销可忽略）。前提是客户端对"sysinfo 对象序列化后的原文"算哈希，服务端也存这份原文【推测：要在实现时确认两边序列化一致，或者改成服务端算好哈希回给客户端，客户端只比对】。

预计服务端改动 300~400 行（不含测试）【推测】。

### 2.6 影响面（问题 6）

| 文件 | 改动 | 行数 | 冲突风险 |
|---|---|---|---|
| `src/hbbs_http/sync.rs`（上游） | §2.2 ① 一处挂钩 | +3 | 低。tick 开头几行近一年少有改动；`register_switch_grant` 那块近期新增过，但不在挂钩附近【推测：没统计这一文件的提交频率】 |
| `src/server/connection.rs`（上游热点） | §2.2 ② 一处挂钩 | +3 | 中。这个文件改得最多，但挂钩在 `post_audit_async` 的函数体第一行，函数签名不变就不冲突；上游重写这个函数的重试逻辑时也只会撞到相邻行 |
| `libs/porta/Cargo.toml` | 加 `reqwest`、`serde`、`serde_json`、`sha2`（主 crate 已有的同版本） | +4 | 无（Porta 自己的文件） |
| `libs/porta/src/` | 新模块 `api`、`report` | +500~600 | 无 |
| `Cargo.lock` | 依赖边变化 | 少量 | 每次合并本来就会冲突，机械处理 |
| porta-server | §2.5 | +300~400，含抽函数 | 无（硬分叉） |
| porta-cardo | 不动（本主题不需要新 proto 字段） | 0 | 无 |

**和第二期改名换标的冲突点**：第二期动过 `src/common.rs`（API 默认地址、IPv6 打洞默认值、`using_public_server`）、`src/rendezvous_mediator.rs`、`src/updater.rs`、`src/lib.rs`、`src/platform/windows.rs` 等，**没碰 `sync.rs` 和 `server/connection.rs`**，所以本次改动和它不重叠。唯一的联系是 API 地址：本方案用挂钩处上游算好的 `url`，而 `url` 经 `get_api_server_` 已经用上了第二期的 `porta::brand::default_api_server()`，两者自动一致，不用另算。

### 2.7 明确不做

- 控制端写审计备注（Dart，`dialog.dart`）：随新界面轨道下沉，本期不动。（**前提不成立，见核对记录**：会话中的备注由 Rust 的 `ui_session_interface.rs` `send_note` 发；只有连接结束那条 `PUT /api/audit` 是 Dart 发的。）
- 心跳下发 `disconnect`：第一期服务端没做，Porta 路径也先不定义；以后要做时 `tick` 多传一个发送函数即可。
- `/api/record`（录屏上传，`record_upload.rs`）、`/api/switch-grant`：porta-server 都没实现，Porta 路径也不接。
- 审计落盘队列（进程重启后补发）：上游没有，120 秒内的重试已经够用。
- 单独的能力协商接口：第一次心跳就是协商。
- 让 Porta 路径支持 TCP 代理回退、WebSocket 代发：porta-server 不实现 `HttpProxyRequest`。
- 改上游 `heartbeat_url()`、`handle_config_options`、三个审计组包函数：一律不动，Porta 需要的逻辑在 `libs/porta` 里重写。

## 3. 需要维护者拍板的问题

1. **总体路线**：方案甲（新路径 `/api/porta/v1/`，2 处挂钩，推荐）还是方案乙（旧路径加签名头，5~7 处挂钩，客户端永远背着上游约定值）。
2. **防降级**：服务端在某个 API 地址上回过一次"支持"之后，后来又回 404 时，要不要退回上游的不签名路径？推荐**不退**：同一地址记住"支持"（存进 Config，换地址才重新探测），否则中间人回一个 404 就能把客户端降回不签名的上报。代价：真把服务端回滚到不支持 Porta API 的版本时，要在客户端清掉这个记录（或者换个地址）才会恢复上报。
3. **TLS 和下发完整性**（和设备签名笔记一起定）：
   - (a) Porta 路径的 TLS 严格校验，不做接受无效证书的回退（推荐）。代价：用自签证书的部署要么换成正规证书，要么走明文 HTTP。（**前提不成立，见核对记录**：上游默认同样严格校验，只有打开 `allow-insecure-tls-fallback` 才回退。所以这一问实际是：Porta 路径要不要无视这个选项。代价只落在靠这个选项接自签证书的部署上。）
   - (b) 服务端用会合服务器的私钥给心跳响应签名（推荐）。没有它，明文 HTTP 或 TLS 被降级时，中间人能往被控服务的 Config 里写任意选项。代价：私钥要挪进 `AppState`，客户端要多一步验签。
   - 两条都不做时，Porta 路径在下发这一侧和上游一样不设防。
4. **sysinfo 并进心跳**（推荐），还是保留单独的 `/api/porta/v1/sysinfo`。
5. **心跳失败退避**：连续失败时把间隔退到最多 60 秒（推荐，上游没有），还是照上游固定 3/15 秒。
6. **`is_pro()` 要不要加 1 行挂钩**，让 Porta 路径下 CM 启动失败时和上游 Pro 一样不弹错误。推荐不加。
7. **`device.client_type` 的语义**：推荐"最近一次走的路径"。备选是"只要验签成功过一次就一直记 `porta`"，这样能看出设备装的是 Porta、但当前在退回上游路径（例如服务端临时不支持）。

## 4. 风险

- **两条上报路径并存期间的状态切换**【推测】：设备在 Porta 路径和上游路径之间切换时，上游那套 `info_uploaded` 状态是旧的，切回去后会重传一次 sysinfo；策略 `rev` 两边共用，不会重推。影响小，但测试要覆盖"porta-server 升级或回滚"的场景。
- **sysinfo 哈希两边算法不一致**【推测】：客户端和服务端对 sysinfo 原文的序列化如果不一致，服务端会每次都要求重传。实现时要么约定服务端存原始字节并对原始字节算哈希，要么由服务端回哈希、客户端只比对。
- **上游改 `post_audit_async` 签名或改成别的出口**：挂钩会编译失败（这是好事，合并时能发现）；但如果上游另加一个不经过 `post_audit_async` 的审计出口，新出口会悄悄走上游路径。每次合并上游后 `grep get_audit_server` 核对一遍，写进冒烟清单。
- **上游改 tick 结构**（比如把 sysinfo 拆成独立任务）：挂钩要跟着挪。`sync.rs` 不在方案 §3.3 的热点清单里，频率应该不高【推测】。
- **验签增加服务端开销**：每次心跳一次 Ed25519 验签（约几十微秒）加一次 `peer.pk` 查询。`uuid_matches` 现在本来就每次查一次 `peer` 表，查询次数不变；先查内存里的 `PeerMap` 还能省掉这次查库【推测】。
- **能力探测的边角**：API 地址背后是反代、反代对未知路径回 200 的 HTML 页（而不是 404）时，客户端要能识别"不是 Porta 格式的 JSON"并当作不支持，否则会一直卡在 Porta 路径上失败。实现时判断条件要写成"2xx 且 JSON 里有 `api` 字段"。
- **明文 HTTP 默认地址**：见 §3 问题 3。不做响应签名时，Porta 路径对下发的保护和上游一样弱；这不是本次改造引入的问题，但改造是修它的时机。

## 5. 核对记录

> 2026-10-23 独立核对，只核标【读码】的结论，没有改设计推荐；推荐所依据的事实被证伪的地方，在推荐旁注明"前提不成立，见核对记录"。
> 对照的代码：
> - `upstream/rustdesk@bd92623`。
> - `porta-client@ea74616`：`main`、`p2/brand`、`p2/build` 三个分支的 `sync.rs`、`server/connection.rs` 都和基线相同。文首说"逐字相同"成立，只差检出时的换行符：upstream 检出是 CRLF，porta-client 是 LF。
> - porta-cardo 当前检出（`6521d14`），以及 `upstream/hbb_common`。
> - `porta-server@c79181b`：代码和 `7c85b95` 相同，只多了 `PORTA.md` 的 6 行说明。
> - 补读了 `upstream/rustdesk-api@c5687e1`。

### 5.1 核对属实

1. **§1.1 心跳循环**：
   - 启动链：`RendezvousMediator::start_all` → `sync::start` → `SENDER` → 线程。只在 `start_server(is_server=true)` 的进程里跑，`is_outgoing_only` 时不启动。
   - 3 秒节拍；`heartbeat_url` 过滤空地址和公共地址；`stop-service` 跳过；每个 tick 都 `get_sysinfo()`（内部 `refresh_memory`、`refresh_cpu`）。
   - sysinfo 上传条件、请求体字段和 8 个预置键名（`base/src/config/keys.rs`）；`SYSINFO_UPDATED` / `ID_NOT_FOUND` / 120 秒冷却。
   - 自建服务器上去重代码永不执行：`is_public` 只认 `rustdesk.com` 及其子域，而这种地址已被 `heartbeat_url` 滤成空串。
   - 心跳 3/15 秒节拍和请求体；响应四个键的处理；`handle_config_options` 的合并规则。
   - `is_pro` 的两处用法：connection.rs 那处补了"只在 Windows 编译"等条件。
   - `register_switch_grant` 的签名内容，以及收到 `server_time` 后重签一次。
2. **§1.2 审计**：
   - 三个入口的触发时机、公共字段和发送方式：conn 走 `tx_post_seq` + `post_seq_loop` 顺序发，file 和 alarm 用 `tokio::spawn`。
   - `get_audit_server` 的拼法和对公共服务器的过滤。
   - `post_audit_async` 的成功、重试、放弃判据，以及 10 秒、30 秒、120 秒的时间表。
3. **§1.3 HTTP 栈**：
   - `post_request` 就是 `with_tcp_proxy_fallback(post_request_http, post_request_via_tcp_proxy)`；4xx 原样返回。
   - TCP 代理连的是 `check_port(rendezvous, 21116)`，总时限 18 + 18 = 36 秒（`hbb_common::config::CONNECT_TIMEOUT`、`READ_TIMEOUT`）。
   - reqwest 0.12（主 crate `default-features = false`）；每次尝试 12 秒；`header` 只按 `": "` 拆出一个。
   - `configure_http_client!` 的代理设置和 `no_proxy()`；`post_request_with_status` 同规则。
   - `libs/porta` 只依赖 `hbb_common` 和 `base`，主 crate 依赖它，反过来调会成环。
4. **§1.4**：
   - 所列 `hbb_common` 接口都存在且公开：`Config::get_id/get_key_pair/get_option/get_options/set_options/get_socks`、`get_uuid`、`get_version_number`、`DEFAULT_SETTINGS`、`BUILTIN_SETTINGS`、`proxy`、`tls`、`sodiumoxide`。
   - `get_builtin_option` 读的就是 `BUILTIN_SETTINGS`；`get_sysinfo` 依赖 `platform::get_active_username`；`VERSION` 来自 `build.rs` → `hbb_common::gen_version` 生成的 `src/version.rs`。
5. **§1.5 服务端**：
   - 路由表、`is_report` 的 10 秒（`listen::REPORT_TIMEOUT`）、`internal_error_is_200`、`not_found` 回 404。
   - `report_allowed` 每来源每分钟 1000 次、最多 65536 个来源；`uuid_matches`；`make_room` 1 万行；`OWNER_FROM_TOKEN` 的 `?1`/`?2`。
   - 审计：`admit` 先限速后解析；`report` 先 nonce 去重、再 `uuid_matches`、再写库、最后登记 nonce；每表 2 万行。
   - `strategy::effective` 的签名。
   - 私钥只在 `inner.sk`，`PORTA.md` §3 写明以后要签名时再挪进 `AppState`。
   - `peer.pk` 列存在（迁移 0001），客户端 `RegisterPk` 上报的是 `Config::get_key_pair().1`。
6. **§2.2、§2.6**：
   - porta-server 对未知路径回 404。
   - 第二期改动没碰 `sync.rs` 和 `server/connection.rs`。
   - 挂钩处 `url` 的兜底分支确实走 `porta::brand::default_api_server()`。

### 5.2 更正

1. **控制端备注不是 Dart 发的（§1.2、§2.7，前提不成立）**：
   - 会话中工具栏"Note"由 Rust 的 `src/ui_session_interface.rs` `Session::send_note` 发 `POST /api/audit/conn` `{id, session_id, note}`，porta-server 兼容接口里免校验的备注分支处理的就是它。第一期笔记 `03-账号设备审计接口.md` §5.2.4 本来就是这么写的。
   - `updateAuditNoteByGuid` 是连接结束弹框，走的是另一个接口 `PUT /api/audit`（Pro 专有，porta-server 不实现）。
   - "不在本次范围"本身仍然可以成立：这条请求发自控制端进程，不属于被控端上报。它本身不带任何凭据（第二轮核对更正，原写"身份是登录用户"；第一期笔记 03 §7 第 9 条也写了"会话备注没有任何身份信息"）。但原来的理由不成立，而且有一个后果原文没提，见 5.3 第 1 条。
2. **上游默认不接受无效证书（§1.3、§2.4、§3 问题 3(a)，前提不成立）**：
   - `get_cached_tls_accept_invalid_cert` 在选项 `allow-insecure-tls-fallback` 没打开时直接返回 `Some(false)`（`hbb_common/src/tls.rs`）。`option2bool` 对 `allow-` 开头的选项只认 `"Y"`，所以默认关；界面提示文字也写明"默认校验证书，打开后校验失败时跳过"。
   - 默认情况下 `post_request_` 只在 rustls 失败后换 native-tls 重试一次，两次都严格校验。
   - 原文"中间人只要让第一次握手失败，客户端就会接受它的证书"只在用户打开这个选项时成立。打开后最多试 4 次，并把"接受无效证书"记进进程内缓存。选项关掉后，`get_cached_tls_accept_invalid_cert` 直接返回 `Some(false)`，缓存不再起作用。
   - 推荐 (a) 的实际含义因此变成"Porta 路径要不要无视这个选项"。
   - 补充一条支持 (b) 的事实：心跳下发的策略能把这个选项写成 `Y`。
3. **TCP 代理回退不会白等 36 秒（§1.3、§2.1、§2.4）**：
   - porta-server 的 `handle_tcp` 对 `HttpProxyRequest` 落进 `_ => {}` 并返回 false，`handle_listener_inner` 随即关闭连接；客户端 `tcp_proxy_request` 读到 `None`，马上报错。
   - 所以 21116 可达时，这条回退只多一次 TCP 建连和密钥交换；21116 不可达时才会等到建连超时 18 秒，整体最多 36 秒。
   - 推荐"Porta 路径不做 TCP 回退"不受影响，因为这条回退本来就没有用；只是代价的说法夸大了。
4. **调用点数量**：
   - `post_file_audit` 是 6 处（connection.rs 927、3439、3498、3761、5384、5514 行），原文写 7 处。
   - `post_alarm_audit` 直接调用 8 处，原文写约 9 处。
   - 三个入口合计 17 处（conn 3 + file 6 + alarm 8），原文写"二十来个"，§2.1 两处已改。
5. **严格 HTTPS 客户端有两个**：异步的 `create_http_client_async_with_url_strict` 给下载器用，同步的 `create_http_client_with_url_strict` 给更新器用。原文只写了异步那个，并说它两边都用。
6. **§1.5 handler 的步骤顺序和 `client_type`**：
   - 实际顺序是先限速、后解析。
   - 只有 sysinfo 的 SQL 写死 `'rustdesk'`；心跳靠列默认值，更新时不写这一列。所以 §2.5 让 `touch` 带 `client_type` 参数时，心跳的 insert 和 update 都要加上这一列，否则做不到"记最近一次走的路径"。
7. **`use-raw-tcp-for-api`**：直接走 TCP 代理还要求目标主机就是 API 主机（`is_tcp_proxy_api_target`），已补上。
8. **默认 API 地址**：`http://<会合主机>:21114` 只在构建没注入 `PORTA_API_SERVER`、用户也没填 `api-server` 时成立。已在 §2.4 补上适用条件。
9. **rustdesk-api 对未知路径回 404**：从【推测】改为【读码】（`http/http.go` 的 `NoRoute`）。

### 5.3 仍存疑或需要维护者定

1. **会话备注的去向**（5.2 第 1 条带出来的问题）：§2.3 说退出兼容时"删掉兼容 handler"，这会把 Porta 自己的客户端发的会话备注一起断掉。两种处理：
   - 退出兼容时保留 `/api/audit/conn` 的备注分支；
   - 把 `send_note` 也挂到 `libs/porta`，在 `ui_session_interface.rs` 加一处挂钩。它跑在控制端进程里，用不上被控进程里的能力缓存；现在它不带任何凭据，要加认证也只能用登录令牌，不能用设备密钥。
   
   原文没讨论这一点，交主会话决定是否列进 §3。
2. ~~**`e.is_request()` 覆盖哪些错误**~~：第二轮已核实，见 5.4 第 2 条。
3. ~~**§2.4"Cargo 特性合并，不新增要编译的包"**~~：第二轮已读 reqwest 的特性表和 `Cargo.lock` 核实，见 5.4 第 3 条；仍没编译验证。
4. **行数估计**（服务端 300~400 行、`libs/porta` 500~600 行）是推测，没有核。
5. **顺带发现，不在本笔记范围**：`PORTA.md` §9.4 说"HTTPS 下还没缓存 TLS 设置的客户端会把同一个请求重发最多 4 次"。按上面第 5.2 条第 2 项，这只在打开 `allow-insecure-tls-fallback` 时成立，默认最多 2 次；上游 `post_audit_async` 注释里的"up to four times"同样是按选项打开算的。`PORTA.md` §9.1 第 1 条说"白等最长 36 秒"，作为上限没错。

### 5.4 第二轮核对（2026-10-23）

> 第一轮核对的后台任务中途可能被网络中断打断，所以重新独立核了一遍：正文所有标【读码】的结论，加上第一轮在 5.1、5.2 里的判断，都回到代码逐条对照。对照的代码同 §5 开头，另外补读了本机 cargo 缓存里的 `reqwest-0.12.28` 源码，和 porta-client 的 `Cargo.lock`。

**重新核实属实**（和 5.1、5.2 的结论一致，不再逐条重复）：§1.1 心跳循环全部细节；§1.2 三个审计入口、17 个调用点（conn 3、file 6、alarm 8）和 `post_audit_async` 的重试规则；§1.3 TCP 回退、TLS 重试（默认 2 次都严格、打开选项后 4 次）、代理和两个严格客户端；§1.4 所列接口；§1.5 服务端全部条目；§2.2 两个 404（porta-server、rustdesk-api）；§2.4 默认 API 地址的推导；§2.6 第二期没碰 `sync.rs`、`server/connection.rs`（`main`、`p2/brand`、`p2/build` 和三个 worktree 都没有改动）。第一轮的 9 条更正都成立。

**本轮更正和补充**（正文对应位置已改，带"第二轮核对"字样）：

1. **会话备注不带身份**（§1.2、5.2 第 1 条、5.3 第 1 条）：第一轮把两条备注请求都写成"身份是登录用户"。实际 `send_note` 调 `post_request(url, body, "")`，header 是空串，不带令牌，只是本地登录过才发；只有连接结束那条 `PUT /api/audit` 经 `getHttpHeaders()` 带 Bearer。
2. **`e.is_request()` 的范围**（原 5.3 第 2 条，已核实）：reqwest 0.12.28 `async_impl/client.rs` 把 hyper 客户端的所有错误（连接被拒、DNS、TLS、连接被重置）都映射成 `crate::error::request`，`PendingRequest::poll` 的整请求超时也是 `request(TimedOut)`，所以这些错误都会触发重试。默认情况下，连不上的 HTTPS 地址每次调用最多 2 × 12 秒；`http://` 地址不重试（`get_cached_tls_type` 对明文地址直接返回 `Plain`，`post_request_` 走"已缓存"分支）。
3. **reqwest 默认特性**（原 5.3 第 3 条，§2.4 已补前提）：0.12.28 的 `default = ["default-tls", "charset", "http2", "system-proxy"]`。`Cargo.lock` 里 reqwest 的依赖没有 `h2`，整个锁文件里也没有 `h2`、`encoding_rs`。所以 `libs/porta` 必须写 `default-features = false`，不然会新增要编译的包。没编译验证。
4. **TCP 回退的慢路径还有一种**（§1.3）：porta-server 没持有私钥时不先发 `KeyExchange`，客户端在 `key_exchange` 里等 `READ_TIMEOUT` 18 秒才失败。只在配错时出现。
5. **挂钩 ① 的 `url` 不是 API 根地址**（§2.2）：是 `{api}/api/heartbeat`。不影响推荐，只是提醒实现时要去掉后缀。
6. **措辞**（§2.4）：`allow-insecure-tls-fallback=Y` 的效果是"证书校验失败后改为接受无效证书"，不是"直接关掉校验"。结论（中间人能借此接受自己的证书）不变。

**没有发现被证伪的设计前提**：第一轮已在 §2.4、§2.7、§3 问题 3(a) 标注"前提不成立"的三处，本轮核对后维持原判；其余推荐所依据的【读码】事实都成立。

**仍存疑或本轮没核**：

- 行数估计（5.3 第 4 条）、§2.6"tick 开头几行近一年少有改动"都是【推测】，本轮没统计提交历史。
- 顺带发现，不在本笔记范围：
  - 连接结束弹备注框之前，Dart 还会 `GET {api}/api/audit/conn/active` 查审计 GUID（`flutter/lib/models/model.dart` `_queryAuditGuid`）。porta-server 不实现这个接口（`PORTA.md` §1），所以 `allowAskForNoteAtEndOfConnection` 永远为假，那个弹框在 porta-server 上根本不会出现，`PUT /api/audit` 也就不会发出。
  - `PORTA.md` §9.3 把免校验的那条备注写成"控制端会话结束写备注"，实际它来自会话中的工具栏 "Note"。服务端逻辑不受影响，只是描述不准。
