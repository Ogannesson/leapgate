# hbbs / hbbr 与中继分配（只读代码调研）

> Porta 是当时的工作名，2026-10-24 改名为 Leapgate（跃门）。

调研日期 2026-10-22。代码版本：
- 服务端 `rustdesk-server@873230e`（2026-10-10），下文简写 `srv:`
- 客户端 `rustdesk@bd92623`（2026-10-21），下文简写 `cli:`

标注：**[确认]** = 读代码确认；**[推测]** = 根据代码推断但未运行验证。
术语：A = 控制端（发起连接的一方）；B = 被控端（被连的一方，常驻跑 `rendezvous_mediator` 向 hbbs 注册）。

---

## 0. 一句话结论

**基本可以只改 hbbs，前提是被控端 B 的"中继服务器"一栏留空。** 中继地址的最终决定者是 **B**（`cli:src/rendezvous_mediator.rs` `fn get_relay_server`）：B 本地填了 `relay-server` 就用本地值，留空才用 hbbs 下发的值，两者都空就用 `hbbs主机:21117`。A 的本地 `relay-server` 选项在连接流程里**完全不参与**，A 只用 B 经 hbbs 传回来的值。hbbs 的选择函数 `get_relay_server(&self, _pa, _pb)` 本来就把双方 IP 传进来了，只是开源版没用（参数名带下划线），这里就是改造的挂载点。

---

## 1. hbbs 的中继分配

### 1.1 参数与列表 [确认]
- `-r, --relay-servers=[HOST]`，帮助文字写"separated by comma"（`srv:src/main.rs` 第 23 行）；环境变量 `RELAY_SERVERS`（`get_arg` 会把参数名转成大写、`_` 换 `-` 互查）。
- `srv:src/common.rs` `fn get_servers`：按逗号切分，逐个 `test_if_valid_server` 过滤。**可以填多个**。
- `srv:src/rendezvous_server.rs` `fn parse_relay_servers`：写入两份 `relay_servers0`（配置原表）和 `relay_servers`（当前可用表）。
- 运行时可以改：hbbs 在 NAT 测试端口（默认 21115）的 loopback 上收控制台命令，`rs a,b,c` 会重设列表（`fn check_cmd` 的 `"relay-servers" | "rs"` 分支）。

### 1.2 怎么选：纯轮询 + 粗粒度健康检查 [确认]
- `fn get_relay_server(&self, _pa: IpAddr, _pb: IpAddr) -> String`：
  - 列表为空，返回 `""`；只有 1 个，返回它；
  - 多个时用全局 `ROTATION_RELAY_SERVER.fetch_add(1) % len` **轮询**。两个 IP 参数没用。
- 健康检查 `fn check_relay_servers`：`io_loop` 里每 `CHECK_RELAY_TIMEOUT = 3000ms` 一次，**只在 `relay_servers0.len() > 1` 时跑**。对每个中继发起 TCP connect（3 秒超时，端口缺省补 21117），连得上的组成新表发回主循环替换 `relay_servers`；**全部连不上时不替换**（保留上一次的表）。只测 TCP 能否建连，不测延迟、负载、带宽。
- 控制台还有 `test-geo(tg) <ip1> <ip2>` 命令，直接调 `get_relay_server(a, b)` 打印结果；帮助里还列了 `reload-geo(rg)`，但开源版 `check_cmd` 没实现这个分支。这两个都是 Pro 版地理选择留下的接口痕迹 [推测：开源版与 Pro 共用这套框架，Pro 在 `get_relay_server` 里做了地理计算]。

### 1.3 各消息里的 `relay_server` 字段怎么填 [确认]

| 消息 | 方向 | hbbs 怎么处理 relay_server | 代码 |
|---|---|---|---|
| `PunchHoleRequest` | A→hbbs（TCP/WS） | 消息本身不带 relay；hbbs 调 `get_relay_server(A的IP, B的IP)` 选一个 | `fn handle_punch_hole_request` |
| `PunchHole` | hbbs→B（经 B 的注册通道，默认 UDP） | 填上面选出的值 | 同上 |
| `FetchLocalAddr` | hbbs→B（A、B 被判为同一内网时代替 PunchHole） | 同上 | 同上 |
| `PunchHoleSent` | B→hbbs（TCP） | **原样透传** `phs.relay_server` 给 A | `fn handle_hole_sent` |
| `PunchHoleResponse` | hbbs→A | 来自 `PunchHoleSent` 或 `LocalAddr` 里 B 填的值 | `fn handle_hole_sent` / `fn handle_local_addr` |
| `LocalAddr` | B→hbbs（TCP） | 原样透传给 A（并置 `is_local=true`） | `fn handle_local_addr` |
| `RelayResponse` | B→hbbs→A | 非空时：B 的地址在 `mask` 内网，改成 hbbs 的 `local_ip`；值等于 `local_ip`，改成 `get_relay_server(...)`；否则**原样透传** | `fn handle_tcp` 的 `RelayResponse` 分支 |
| `RequestRelay` | A→hbbs→B | **不碰 relay_server**，只把 A 的地址写进 `socket_addr` 后转给 B | `fn handle_tcp` 的 `RequestRelay` 分支 |

补充：
- `ALWAYS_USE_RELAY=Y`，或 A、B 中恰好一方在 `mask` 内网（`peer_is_lan ^ is_lan`）时，hbbs 把 `nat_type` 改成 `SYMMETRIC`，强制走中继；B 在内网时中继还会被换成 `local_ip`（rustdesk-server issue #24）。
- **2026-07 起 hbbs 不再处理 UDP 上来的 `PunchHoleRequest` / `PunchHoleSent` / `LocalAddr`**（`fn handle_udp` 里注释掉，commit `109d9a2` 2026-07-23 "fix more UDP reflection/amplification"，以及更早的同类改动）。影响见 §5。

### 1.4 hbbs 能拿到双方公网 IP 吗 [确认]
- A 的 IP：`PunchHoleRequest` 所在 TCP 连接的源地址 `addr`；WebSocket 端口（21118）会优先信任 `X-Real-IP` / `X-Forwarded-For`，这两个头不做校验（`fn handle_listener_inner` 的注释写明了伪造风险）。
- B 的 IP：`peer.socket_addr`，即 B 最近一次 `RegisterPeer` 的源地址（默认 UDP 注册，走 ws/代理时是 TCP）。
- 也就是说，hbbs 调 `get_relay_server(addr.ip(), peer_addr.ip())` 时**双方公网 IP 都在手**，可以据此做就近选择。
- 注意 [推测]：hbbs 跑在 Docker 桥接网络、端口经 userland-proxy 转发时，看到的源 IP 可能是网桥网关，而不是真实公网 IP，地理选择会全部失效。现有部署的 hbbs 是容器，要先确认它是 `network_mode: host`，或者日志里能看到真实 IP。

---

## 2. 客户端怎么决定用哪个中继

### 2.1 被控端 B 决定 [确认]
`cli:src/rendezvous_mediator.rs`：
```rust
fn get_relay_server(&self, provided_by_rendezvous_server: String) -> String {
    let mut relay_server = Config::get_option("relay-server");
    if relay_server.is_empty() { relay_server = provided_by_rendezvous_server; }
    if relay_server.is_empty() { relay_server = crate::increase_port(&self.host, 1); }
    relay_server
}
```
- 被 `fn handle_punch_hole`（收到 `PunchHole`）和 `fn handle_intranet`（收到 `FetchLocalAddr`）调用。**B 本地选项优先于 hbbs**。
- 两者都空时用"hbbs 地址 + 端口 +1"，即默认 hbbr 和 hbbs 同机。
- `fn handle_request_relay`（A 主动要中继时）**不调** `get_relay_server`，直接用 `rr.relay_server`，也就是 A 发来的值（这个值最初还是 B 给 A 的）。
- 自定义客户端（exe 名里带配置串）会在 `cli:src/core_main.rs` 第 505 行把 `lic.relay` 写进 `relay-server`，打包时塞了中继地址就等于 B 本地填了值。

### 2.2 控制端 A 只照搬 [确认]
- `cli:src/client.rs` `fn _start_inner`：`relay_server` 初值为空，只在收到 `PunchHoleResponse` 时 `relay_server = ph.relay_server`，或者收到 `RelayResponse` 时用 `rr.relay_server`。
- A 的本地 `relay-server` 选项在 `client.rs` 里没有被读。`hbb_common/src/websocket.rs` 里有一行注释也写明了这一点："for controlling side, relay server is passed from the controlled side, not related to local config"（那里只用本地选项来猜端口，好把地址改写成 ws 地址）。
- 所以**A 填不填中继无所谓**。不过 A 作为被控端被别人连时，它自己的这一栏同样适用 §2.1 的规则。

### 2.3 完整时序（默认自建配置：只开 TCP 打洞） [确认]

自建服务器下，UDP 打洞、IPv6 打洞、WebRTC **默认关**：`cli:src/common.rs` `fn get_local_option` 规定，这三项未设置且 rendezvous 不是官方公共服务器时返回 `"N"`。TCP 打洞是兜底，始终可用（`fn tcp_punch_allowed`）。

```
A                         hbbs                          B (已 UDP 注册)
|--TCP connect 21116------>|                              |
|--PunchHoleRequest------->| 选 relay R0=get_relay_server(A_ip,B_ip)
|  (最多 3 次, 等待窗口      | 同一内网? 是→FetchLocalAddr  否→PunchHole
|   3s/6s/9s)              |---PunchHole{socket_addr=A, relay=R0, nat_type}-->|
|                          |                              | R = B.relay-server 非空 ? 它 : R0
|                          |                              | [分支 X] 需要中继(对端/自己 SYMMETRIC、
|                          |                              |   force_relay、B 走 ws/代理):
|                          |<--RelayResponse{uuid,R}------|   B 新建 uuid，先发 RelayResponse
|<--RelayResponse{uuid,R}--| (R==local_ip 时才改写)        |   再 TCP 连 R 发 RequestRelay{uuid}
|--TCP 连 R, RequestRelay{uuid}------------------> hbbr R 配对 -------------|
|                          |                              |
|                          |                              | [分支 Y] 打洞: B 从注册时的本地端口
|                          |                              |   向 A 的公网地址发 SYN 开 NAT 映射
|                          |<--PunchHoleSent{A,relay=R}---|   (TCP 连 hbbs 发)，随后在该端口 listen
|<--PunchHoleResponse{B_addr,R,nat_type}--|               |
| connect(): 用同一本地端口直连 B_addr，超时见 §5            |
| 成功 → 直连                                              |
| 失败 → request_relay(R):                                  |
|--新 TCP, RequestRelay{uuid', R}-->|--RequestRelay{socket_addr=A, R}-->|
|                          |                              | handle_request_relay: 用 rr.relay_server(=R)
|                          |<--RelayResponse--------------| 并 TCP 连 R 发 RequestRelay{uuid'}
|<--RelayResponse----------|                              |
|--TCP 连 R, RequestRelay{uuid'}----------------> hbbr R 配对 ------------|
| secure_connection (端到端密钥交换, 与中继无关)              |
```

同一内网的情况：hbbs 发 `FetchLocalAddr`，B 回 `LocalAddr`（填 B 的内网地址和 R）。A 拿到 `is_local=true` 后用 1 秒超时直连内网地址，失败再走 `request_relay(R)`。B 那边内网监听失败，会直接走分支 X 的中继。

---

## 3. 结论：只改 hbbs 行不行

### 3.1 能做到的部分 [确认]
- hbbs 是第一个选中继的人（`PunchHole` / `FetchLocalAddr` 里的 R0），并且手里有 A、B 双方 IP。把 `srv:src/rendezvous_server.rs` `fn get_relay_server` 改成按 IP→地理位置（GeoLite2，或自建的 IP 段→机房表），或按 ASN、运营商挑选，就能做到"按双方位置就近选 hbbr"。改动只在这一个函数，加上加载 IP 库的逻辑。社区已有现成实现：`EdwardLab/rustdesk-server` 号称"按双方地理位置选在线中继，兼容原版客户端"（https://github.com/EdwardLab/rustdesk-server ，未读其代码）。
- 健康检查已经有了（3 秒 TCP 探测），可以顺手加上 RTT 记录。

### 3.2 客户端必须满足的条件 [确认]
1. **被控端 B 的 `relay-server` 留空**。B 是常驻端，A 怎么填无所谓。打包的自定义客户端也不能在配置串里塞 relay。
2. hbbs 必须配了 `-r`。否则 R0 为空，B 回落到"hbbs 主机:21117"。

### 3.3 分支 Y 里 hbbs 还能"强行改写" [推测，逻辑上成立]
在打洞后再转中继的路径上，A 用的 R 来自 hbbs 转发的 `PunchHoleResponse`，B 在 `handle_request_relay` 里直接用 A 发来的 R。所以 hbbs 在 `handle_hole_sent` 里改写 `relay_server`，就能让双方一致地用 hbbs 选的中继，**即使 B 本地填了值**。分支 X 不行：B 用自己选的 R 直接去连 hbbr，hbbs 改写转给 A 的 `RelayResponse` 会造成双方去了不同的 hbbr、配对失败。所以 B 留空仍然是硬条件。

### 3.4 只改 hbbs 做不到的
- **真正按延迟选**：hbbs 只能量自己到各 hbbr 的延迟，量不了 A↔hbbr、B↔hbbr。要按端到端延迟选，得让客户端测量并上报，例如 B 定期测各 hbbr 的 RTT，随 `RegisterPeer` / `RegisterPk` 报上去，A 在 `PunchHoleRequest` 里带上自己的测量结果。这需要**新 proto 字段和客户端改动**。不改 proto 的折中是用地理位置或"IP 段→中继"静态表近似。
- 中途切换中继、多中继并发择优：见 §4。

### 3.5 最小客户端改动（如果要客户端配合）[确认位置]
- 想让 hbbs 的值始终优先、不受 B 本地选项干扰：改 `cli:src/rendezvous_mediator.rs` `fn get_relay_server`，把优先级换成 hbbs 给的值优先、本地值兜底，三行左右。
- 想按延迟选：加在 `fn get_relay_server` 内部，或者加一个新函数让 B 从多个候选里挑 RTT 最低的。B 选定后经 `RelayResponse` / `PunchHoleSent` 告诉 A，A 无需改动（A 本来就照搬）。需要 hbbs 把多个候选下发给 B：现有 `relay_server` 是单个 string，可以塞逗号分隔列表（只有 Porta 的客户端认识），或者新增 repeated 字段。

---

## 4. hbbr：配对、限速、认证、能否切换

`srv:src/relay_server.rs`

- **配对** [确认] `fn make_pair_`：连接建立后 30 秒内必须收到首包 `RequestRelay`。用 `uuid` 在全局 `PEERS` map 里查：查不到就把自己存进去，等 30 秒后移除；查到了就取出对端，进入 `fn relay` 双向转发。两端都是原始 TCP（非 WS）时 `set_raw()` 透明转发。hbbr 不看 `id`，不认识 hbbs，**完全靠双方拿着同一个 uuid 去同一个 hbbr**。
- **认证** [确认]：`-k` / `KEY` 非空时比对 `RequestRelay.licence_key`，不符就断开。hbbr 的 key **默认空，不校验**；hbbs 的 key 默认 `"-"`，自动生成并强制校验（`srv:src/main.rs` `get_arg_or("key", "-")`）。多台 hbbr 要统一配 KEY，否则任何人都能拿你的 hbbr 当免费中继。
- **限速** [确认]，单位 Mb/s，环境变量或控制台命令可调：
  - `TOTAL_BANDWIDTH`：默认 1024 Mb/s，整个 hbbr 共用一个限速器。
  - `SINGLE_BANDWIDTH`：默认 128 Mb/s，每个配对一个限速器。
  - `LIMIT_SPEED`：默认 32 Mb/s，给黑名单 IP 和"降级"连接用。
  - `DOWNGRADE_START_CHECK`（默认 1800 秒）和 `DOWNGRADE_THRESHOLD`（默认 0.66）：连接持续 30 分钟后，平均速率超过 0.66×SINGLE 就降到 LIMIT_SPEED。
  - `blacklist.txt` 里的 IP 限速，`blocklist.txt` 里的 IP 拒绝；控制台 `u` 命令看各连接用量。
- 30 秒无数据断开（`fn relay` 的 timer）。
- **一个连接只走一个 hbbr，不能中途切换** [确认]：配对后就是两条 TCP 对拼，没有会话迁移、多路径、重绑定。客户端断线重连等于重新走一遍 §2.3，hbbs 会重新选。要做"无缝切换中继"得改协议和客户端会话层 [推测：工作量大]。

---

## 5. NAT 穿透现状

| 手段 | 位置 | 默认（自建） | 说明 |
|---|---|---|---|
| TCP 打洞 | A：`cli:client.rs` `fn connect` 用同一本地端口 `connect_tcp_local`；B：`cli:rendezvous_mediator.rs` `fn handle_punch_hole` 先向 A 发 SYN 开映射，再 `punch_tcp_until_connected` | 开（兜底） | 双方都是 SYMMETRIC 时跳过 |
| UDP 打洞 + KCP | A：`fn _start` 里 `new_direct_udp_for_unverified` + `test_udp_uat`，连接时 `fn udp_nat_connect`；B：`fn punch_udp_hole` / `udp_nat_listen` | **关** | 数据通道是 **KCP over UDP**（`KcpStream::connect`），即"有 KCP/UDP 数据通道" |
| IPv6 直连 | `crate::get_ipv6_socket`、`start_ipv6`，同样走 KCP | **关** | 地址通过 `socket_addr_v6` 字段交换 |
| WebRTC（ICE + DTLS） | `WebRTCStream`、`race_transports_prefer_webrtc`；B 侧 `spawn_webrtc_answerer` | **关** | 新功能；可配 TURN；信令要求 hbbs 支持加密 TCP（`secure_tcp_required`） |
| 局域网直连 | hbbs `same_intranet` → `FetchLocalAddr` → B `fn handle_intranet_` → `LocalAddr` → A `is_local` 时 1 秒超时直连 | 开 | 判定条件：双方公网 IP 相同，或都在 hbbs 的 `mask` 网段 |
| 按 IP 直连 | `fn _start` 中 peer 是 IP 或 `域名:端口` 时直接 TCP 到 21118 | 开 | 绕过 hbbs |
| 强制中继 | 对端选项 `force-always-relay`、ID 写成 `<id>/r`、使用代理、走 WebSocket 时 `force_relay=true`（`fn initialize`）；服务端 `ALWAYS_USE_RELAY=Y` | 关 | 强制中继时 A 发 `nat_type=SYMMETRIC`，B 直接走分支 X |

**UDP 打洞与新版 hbbs 不兼容** [确认服务端行为，影响为推测]：B 在 `fn punch_udp_hole` 里经 UDP 把 `PunchHoleSent` 发给 hbbs，而 `srv@873230e` 的 `fn handle_udp` 已经丢弃 UDP 的 `PunchHoleSent`。结果是开了 UDP 打洞时 A 收不到这次回应，要靠并行的纯 TCP fallback 请求（`fn _start` 里的 `fallback_fut`）兜底。Porta 如果要用 UDP 打洞，服务端要么恢复这条路径（注意反射放大风险），要么让 B 改走 TCP 发送。

**直连失败到转中继的耗时** [确认公式，数值为推测]：
- 打洞握手：A 等 hbbs 回应，最多 3 次，窗口分别为 3、6、9 秒（`attempt_deadline = i*3000ms`）。正常情况下首次几百毫秒内就有回应。
- 直连超时 `connect_timeout`（`fn connect`）：
  - 对端 SYMMETRIC 或 `is_local`：1 秒。
  - 中继为空：`CONNECT_TIMEOUT` = 18 秒。
  - 其余：`punch_time_used × 6`（该对端历史直连失败过，`direct_failures>0` 时 ×3），最少 1 秒。
- 典型值：打洞往返 150~300ms，直连等待 0.9~1.8 秒，之后 `request_relay`（新开 TCP 到 hbbs，再连 hbbr，各 1 个 RTT 量级）。从点连接到中继建立，**大约 1.5~3 秒**。直连失败的结果会按对端记住，下次超时更短。

---

## 6. 上游历史与外部资料

- `srv:src/rendezvous_server.rs` 的 `fn get_relay_server` 最后一次改动是 `1142cf1`（2023-12-01，"Fix #324 to remove unsafe"），更早是 2022 年。**近两年开源版中继选择逻辑没有实质改动** [确认，`git log -L`]。近期改动集中在安全方面：UDP 反射放大（2026-07）、WS 头伪造注释（#634）、punch 请求记录上限（#713）。
- **Pro 版有地理就近选中继**（官方文档，2026-10-22 查）：https://rustdesk.com/docs/en/self-host/rustdesk-server-pro/relay/ 。功能是在 Web 控制台加多台 relay，配 MaxMind GeoLite2-City，可以 Geo Override 手填机房经纬度；hbbs 每隔几秒检查在线，只选在线中继。文档说 hbbr 和开源版相同、不需要 license。控制台说明：https://rustdesk.com/docs/en/self-host/rustdesk-server-pro/console/
- Pro 的相关 issue：
  - https://github.com/rustdesk/rustdesk-server-pro/issues/425 ：用户反映总是轮询、不选最近的。原因是被控端 IP 是内网地址时 geo 失效，退化成轮询，1.4.5 加了按网段指定中继的选项。维护者还表示"按延迟选"暂无实现。
  - https://github.com/rustdesk/rustdesk-server-pro/issues/954 ：GeoLite2 不准，靠手工覆盖坐标解决。
  - https://github.com/rustdesk/rustdesk/discussions/7934 ：MaxMind 定位偏差；维护者说以后 Pro 会"重新评估所有设备到所有中继的延迟"，至今没有下文。
- 开源版的多中继讨论：https://github.com/rustdesk/rustdesk/discussions/1959
- 社区 fork：https://github.com/EdwardLab/rustdesk-server （声称按双方地理位置选健康中继，兼容原版客户端；未读代码，[推测]可参考）。

---

## 7. 调研过程备注
- 运行 `git log -S` 时触发了 rustdesk-server 仓库的 git 自动 gc（"Auto packing the repository"），只重打包了 `.git` 对象，没有改工作区文件。
- 网页和仓库内容里没有遇到要求执行命令或外发文件的指令。
