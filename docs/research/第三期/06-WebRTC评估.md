# 第三期调研 06：上游 WebRTC/ICE 路径评估（第一部分：读码、上游历史、实测方案）

> 2026-10-24 写。起因：笔记 05 发现，在"路由器透明代理只代理 TCP、本机开 TUN 代理"的环境里，网易 UU 远程能稳定局域网直连，靠的是 Google libwebrtc 的标准 ICE：两端交换全部候选地址，由客户端逐对实测。上游 RustDesk 1.5.0 起也带了一条 WebRTC 路径。维护者 2026-10-23 决定把契约 04 §3.6 的评估项提前到第三期最前面做，结果决定 03（局域网判定与候选）、04（UDP 打洞与 NAT 探测）两块怎么做。维护者的原则：**兼容性要考虑全面，不能假定任何运行环境，规则必须对所有环境都适用。**
> 本文是评估的前半：读码和上游历史，以及给维护者照着做的实测方案。实测结果和最终建议等实测完补进来（§9 留空）。
> 对照基线改成"现有 Porta 路径"：局域网多候选（只有 IPv4、只有 TCP）+ TCP 打洞 + IPv6 打洞 + hbbr 中继。KCP-UDP 打洞还没实现（04 块搁置），不在对照里。
> 代码基线：`porta-client@6bb19b190`（基于上游 `rustdesk@bd92623`）、`porta-cardo@df76a0c`、`porta-server@d8403ad`；上游 `rustdesk@bd92623`、`hbb_common@ed07431`（`bd92623` 实际钉的是 `5d52530`，`webrtc.rs`、`stream.rs` 两版逐字相同，行号按 `ed07431` 引用）、webrtc-rs 的 rustdesk 分支 `rustdesk-org/webrtc@49c89bd8`（本机 cargo 缓存里的源码）。
> 标记：【读码】读代码确认（read_code）；【官方】上游官方页面、官方提交说明（official）；【旁证】第三方或社区（third_party）；【推测】推断，后面写依据（inferred）；【待实测】只能靠实测回答。网页查证日期都是 2026-10-23 或 10-24。每条结论都经过独立复核，被复核削弱的按复核后的说法写，被推翻的不用。

术语：
- **ICE**（Interactive Connectivity Establishment，RFC 8445）：两端把所有可能的地址（"候选"）交给对方，对每一对候选实际发探测包（"连通性检查"），哪对通就用哪对。
- **候选的三种类型**：host 是本机网卡上的地址；srflx（反射候选）是向 STUN 服务器问来的、本机在 NAT 外面的映射地址；relay 是 TURN 中继服务器分配的地址。
- **offer / answer / SDP**：WebRTC 双方交换的会话描述（SDP 格式），发起方的叫 offer，应答方的叫 answer，里面有 DTLS 证书指纹和 ICE 用户名、密码。
- **trickle**：候选不放进 SDP，收集到一个就单独发一个。
- **offerer / answerer**：建 offer 的一方（RustDesk 里是控制端）和回 answer 的一方（被控端）。

## 0. 要回答的问题

照契约 04 §3.6：上游现成的 WebRTC 路径能不能直接拿来，替代或补充局域网多候选、IPv6 打洞（以及将来的 KCP-UDP 打洞）；能不能补上"两端 UDP 走不同代理出口、服务端判不出同网"那个缺口（04 §2.5.8）。具体看四件事：成熟度、porta-server 要改什么、STUN/TURN 怎么办、在维护者网络里的预期。

## 1. 结论先行

- **初步判断：值得实测，现在还不能定为替代。** 代码在 Porta 现有二进制里已经全部带着，和上游逐字相同。设计正好对准维护者的场景：全部候选交给对方，由客户端逐对实测，会话全程 UDP，不靠服务端判同网，路由器只代理 TCP 碰不到它【读码，§2】。缺的只是服务端转发。
- **服务端工作量**：评估用的临时转发约 60~100 行，1 天能做完；正式实现还要补防伪造、限速、记录，约 300~500 行、2~3 天，满足 §3.6 条件 (c)"不超过一周"【推测，§3】。有一处协议上的硬缺口：服务端判成同一内网时发的是 `FetchLocalAddr`，这个消息没有 offer 字段，所以**带 offer 的请求必须改发 `PunchHole`**，否则 WebRTC 在最想测的局域网场景里根本不会启动【读码，§3.1】。
- **最大的三个风险**：
  1. **成熟度早期**（约 2/5，§4）。正式版里只有约 3 周；上游只在自家公共服务器上默认开，维护者在 issue 里说开它是为了"鼓励测试 WebRTC"；开源服务端不支持；依赖停在 webrtc-rs 0.13，靠 rustdesk 自己维护的分支；SCTP 调参有过回退，模拟测试里尾延迟仍落后 RustDesk 自己的 KCP。
  2. **比 UU 少三样，正好落在维护者的环境里**（§5.1）。一是所有 host 候选优先级相同，经 TUN 或 Tailscale 的候选对可能被选中；二是没有续选和持续收集，选中的那对断了，约 8 秒后整次重连；三是只有 UDP（没有 ICE-TCP，TURN 也只支持 UDP），UDP 被封的网络里这条路直接失效、回落 hbbr。所以 §3.6 条件 (a) 里的"换网不断"按代码不成立，只能靠"能直连而现有路径不能"来满足。另有一个未实测的隐患：Windows 上 ICE 的 UDP socket 收到 ICMP 端口不可达后可能静默失效（§4.3）。
  3. **隐私**（§5.2）。密码之前，被控端就自动应答任意 offer，发出全部网卡地址（含 TUN、Tailscale、虚拟机网卡、全局 IPv6）；服务端到被控端那一段是明文 UDP；默认每次连接都访问 4 个第三方 STUN。上游设计如此，正式启用前要在服务端转发层做权限控制。
- **实测要维护者配合**（§6）：在测试机部署临时分支的 porta-server；MacBook 换装官方 1.5.x（现在的 1.4.2 没有 WebRTC，不能参与）；台式机、笔记本用 Porta，按三组开关各测一轮；四类场景（同一局域网含两端 UDP 走不同出口、外网连回家、家里连外网、IPv6）每组 5~10 次，外加换网、性能、50 次连接断开。

## 2. 上游 WebRTC 路径怎么工作

### 2.1 开关和前提

| 结论 | 出处 | 等级 |
|---|---|---|
| 开关是 `enable-webrtc`，存在 LocalConfig（每个用户本地的配置）里，只有控制端界面进程读它。连官方公共服务器（`rustdesk.com` 及子域）时默认开，自建服务器且用户没设过时默认关。上游里 `enable-udp-punch`、`enable-ipv6-punch` 规则相同；**Porta 把自建服务器下的 `enable-ipv6-punch` 改成默认开**，另外两个仍默认关 | `rustdesk@bd92623:src/common.rs` `get_local_option` L1308-1319、`get_webrtc_enabled` L1301；`hbb_common@ed07431:src/config.rs` `option2bool` L2826；`porta-client@6bb19b190:src/common.rs` L1317、`libs/porta/src/options.rs` `self_hosted_punch_default` | 读码 |
| 界面上是"Enable WebRTC P2P connection"勾选项，下面缩进一个"Relay fallback delay in seconds"（`relay-fallback-delay`，默认 2.5 秒）。官方文档写的默认值是 `selfhost:N, otherwise:Y`，1.5.0、Server Pro 1.8.7 起可用 | `flutter/lib/desktop/pages/desktop_setting_page.dart` `webrtcOptions` L929-975；https://rustdesk.com/docs/en/self-host/client-configuration/advanced-settings/ | 读码；官方 |
| 怎么预置：`enable-webrtc`、`relay-fallback-delay` 是 LocalConfig，只能构建时用 `DEFAULT_LOCAL_SETTINGS`/`OVERWRITE_LOCAL_SETTINGS` 预置或让用户勾，心跳策略改不到；`ice-servers`、`allow-webrtc-congestion-control` 是 Config，可以构建时预置，也可以由服务端心跳响应的策略下发 | `hbb_common@ed07431:src/config.rs` `LocalConfig::get_option` L2200-2208；`libs/base/src/config/keys.rs` L133-134、L219-333；`rustdesk@bd92623:src/hbbs_http/sync.rs` `handle_config_options` L292-309 | 读码 |
| 控制端建 offer 要三条同时成立：`enable-webrtc` 为真；没配代理（`Config::is_proxy()`，指客户端设置里填了任何 proxy-url，socks5 或 http 都算；**开 TUN 不算**），因为 ICE 会绕过代理暴露真实 IP；不是"对端被设成强制中继、却没配 TURN"。offerer 在连会合服务器之前就建好，建失败打 warn `webrtc offerer setup failed` 并放弃 WebRTC | `rustdesk@bd92623:src/client.rs` `_start` L526-539、`should_create_webrtc_offerer` L604-621；`hbb_common@ed07431:src/config.rs` L1546 | 读码 |
| 发 offer 前必须和服务端完成会合端口上的 TCP 密钥交换（KeyExchange）。做不到就丢掉 offer、打 warn `WebRTC signalling to … cannot be encrypted, punching without WebRTC`、换一条新连接照常打洞，绝不明文发信令 | `client.rs` `_start_inner` L861-886；`common.rs` `secure_tcp_required` L2341-2350；上游 `f4808b71`（#16224）提交说明 | 读码；官方 |
| 密钥交换用客户端配置的 Key 验服务器签名；Key 为空时用内置的 `RS_PUB_KEY`。上游的内置值是官方公共服务器的公钥；**Porta 改成构建时注入 `PORTA_RS_PUB_KEY`，没注入时为空，交换立即失败**。也就是说，客户端的 Key（或构建注入的公钥）必须是所连 porta-server 的公钥，否则 offer 只留一条 warn 就被丢掉 | `common.rs` `get_key` L2111-2131、`key_exchange` L2259-2263；`porta-cardo@df76a0c:src/config.rs` `RS_PUB_KEY` | 读码 |
| 服务端完全不发 KeyExchange 时（比如 porta-server 只拿到公钥、没有私钥），带 offer 的那条请求要先等满 `READ_TIMEOUT` 18 秒才降级。porta-server 部署时必须持有私钥（`server/PORTA.md` §6 第 1 条本来就这样要求） | `common.rs` `key_exchange` 里的 `timeout(READ_TIMEOUT, …)`；`hbb_common@ed07431:src/config.rs` L46 | 读码 |
| 走 WebSocket（21118）时不做密钥交换，直接放行：offer 和后续候选在控制端到服务端那一段只靠 wss 加密；服务器地址写成 IP 时客户端拼出的是明文 `ws://` | `common.rs` `secure_tcp_required` L2345-2349；`server/PORTA.md` L285；`porta-cardo@df76a0c:src/websocket.rs` `check_ws` | 读码 |
| 被控端**不查** `enable-webrtc`（LocalConfig 不经 IPC 同步到服务进程，上游有意去掉了这道检查）。只要 offer 非空、本机没配代理、不是"只走中继却没有 TURN"、同时在进行的应答不超过 16 个，就回 answer | `rustdesk@bd92623:src/rendezvous_mediator.rs` `handle_punch_hole` L1063-1076、`spawn_webrtc_answerer`、`MAX_WEBRTC_ANSWERERS` L74；上游 `ae6af2de`（#15684 合并提交）说明 | 读码；官方 |

### 2.2 一次连接怎么走

```mermaid
sequenceDiagram
    participant A as 控制端
    participant S as 会合服务器
    participant B as 被控端
    A->>A: 建 offerer，开始收集候选（先排队）
    A->>S: PunchHoleRequest（UDP 端口、IPv6、offer；不做 TCP 打洞）[TCP，已加密]
    A->>S: 另一条 PunchHoleRequest（只做 TCP 打洞，不带 offer）
    S->>B: PunchHole（带 offer，约 1 KB）[明文 UDP]
    B->>S: PunchHoleSent 或 RelayResponse（带 answer）[新建的短 TCP，已加密]
    S->>A: PunchHoleResponse 或 RelayResponse（带 answer）[发请求的那条 TCP，不能关]
    A->>S: IceCandidate（id=被控端，逐个，400 ms 后补发一次）[同一条 TCP]
    S->>B: IceCandidate [明文 UDP]
    B->>S: IceCandidate（socket_addr=控制端地址）[专用长 TCP，已加密]
    S->>A: IceCandidate [发请求的那条 TCP]
    A-->>B: ICE 连通性检查 → DTLS → SCTP 数据通道 → RustDesk 身份握手
```

1. **控制端起两条请求竞速**【读码，`client.rs` `_start` L541-597、`request_allows_tcp_punch` L350-354】。有 offerer 时，preferred 请求带 UDP-NAT 端口、IPv6 地址和 offer；fallback 请求只做 TCP 打洞。带 offer 的那条固定 `allow_tcp_punch=false`，因为它的会合连接要留着当 ICE 信令通道。以下任一情况不发 fallback：强制中继（含 WebSocket）、`tcp_punch_allowed()` 为假（`enable-tcp-punch` 关了且 UDP、IPv6、WebRTC 至少开一个）。offer 是 `webrtc://` 加 base64 的 JSON（`type`、`sdp`、`ice_policy`），SDP 里去掉了候选行，约 700 字节；每轮打洞都重发，最多 3 轮，第 i 轮等 i×3 秒【读码，`client.rs` L925-987；`webrtc.rs` `trickle_endpoint` L993-1004、`encode_endpoint` L1010-1024】。
2. **服务端经 UDP 把 offer 交给被控端**。被控端只用 UDP 注册（porta-server 不支持 TCP 注册），带 offer 的 `PunchHole` 约 0.8~1.1 KB，低于 1280 字节，常见链路上不会分片【读码，`porta-server@d8403ad:src/rendezvous_server.rs` `handle_tcp_punch_hole_request` L1303-1317；`webrtc.rs` `UDP_ENDPOINT_BUDGET` L973-984】。
3. **被控端回 answer 的路有两条**【读码，`rendezvous_mediator.rs` `handle_punch_hole` L1098-1171、`create_relay` L716-724】。一般情况：新建一条短 TCP，加密成功才发 `PunchHoleSent{answer}`，被控端不做 TCP 打洞；加密失败就什么都不发。`relay_v4` 时（任一端 NAT 判成对称、强制中继、本机配了代理或用 WebSocket、禁用 TCP 监听且 `udp_port<=0`），answer 放在 `RelayResponse` 里，同样要加密，失败就去掉 answer 只走中继。笔记 05 推测开 TUN 时 NAT 类型多半被测成对称，那么维护者环境里走的多半是后一条。
4. **候选交换（trickle）**【读码，`client.rs` `spawn_webrtc_ice_bridge` L673-793、L1267-1291；`rendezvous_mediator.rs` `spawn_webrtc_answerer` L926-991、`handle_resp` L561-584】：
   - 控制端在设好 answer 之后，才在发请求的那条 TCP 上逐个发 `IceCandidate{id=被控端 ID, session_key, candidate}`，`session_key` 是 offer 的 DTLS 证书指纹。每个候选 400 ms 后补发一次，因为服务端到被控端那一段是 UDP。这条连接不重连（它的地址就是回程路由），竞速结束或连接出错就退出。
   - 被控端为整段 trickle 懒建一条专用 TCP（必须加密），发 `IceCandidate{socket_addr=控制端经服务端看到的地址, session_key, candidate}`，期望服务端不断开它。
   - 控制端在 answer 到达前收到的对端候选先缓存，最多 64 个，满了丢最旧的。
   - 这和上游 PR #15684 写的"服务端要求"一致：转发 SDP 字段、双向路由 `IceCandidate`、保持携带候选的 TCP 连接不断开【官方，https://github.com/rustdesk/rustdesk/pull/15684】。
5. **连上以后**：ICE 选出一对，接着 DTLS 握手、SCTP 建联、打开数据通道，再跑 RustDesk 自己的身份握手（§2.4）。

### 2.3 和其他路径怎么竞速、怎么回落

| 结论 | 出处 | 等级 |
|---|---|---|
| 两条请求用 `race_transports_prefer_webrtc` 竞速：谁先拿到直连结果就立刻用谁；拿到的是中继结果（hbbr，或经 TURN 的 WebRTC）时，只要还有直连尝试没结束，就压住等 `relay-fallback-delay`（默认 2.5 秒），到期或直连全部失败再用中继。两边都失败只报一个错误。WebRTC 算不算直连，看选中的候选对里有没有 relay 类型，查不出来按中继算 | `client.rs` `race_transports_prefer_webrtc` L215-338、`RELAY_FALLBACK_DELAY_MS` L634、L1155、L1515 | 读码 |
| preferred 请求内部，打洞路径（收到 `PunchHoleResponse`）里 UDP-KCP、IPv6、WebRTC 三者竞速，WebRTC 的超时 = max(`connect_timeout`, `relay-fallback-delay`)。`connect_timeout`：`is_local` 或对端对称 NAT 时 1 秒；没有中继服务器时 18 秒；对端 ASYMMETRIC 时，本端也是 ASYMMETRIC 用 18 秒（直连失败过则用打洞耗时×6），本端对称用 1 秒；其余用打洞耗时×6（失败过则×3），最少 1 秒。全部失败就 `request_relay` 新开中继 | `client.rs` `connect` L1428-1574 | 读码 |
| 中继路径（收到带 answer 的 `RelayResponse`）里 IPv6、hbbr、WebRTC 三者竞速，WebRTC 等 18 秒；hbbr 结果压 2.5 秒等直连。**这条路上不管谁赢，中继都会建起来** | `client.rs` L1051-1193 | 读码 |
| WebRTC 连上但身份握手失败：打 warn `WebRTC secure handshake failed (…), falling back to relay`，关掉这个连接，用新 uuid 重开中继（前提是有中继服务器） | `client.rs` L1207-1252、L1584-1627 | 读码 |
| **和 Porta 局域网多候选的关系**：`porta_hooks::lan_connect` 在 `allow_tcp_punch` 为假、强制中继、或对端签名验不过时清空候选，所以开着 WebRTC 时，局域网多候选只在 fallback 那条里跑；它成功就在顶层竞速里立刻胜出、压过 WebRTC。竞速只保留第一个直连结果，不会两边都跑完，所以局域网里 Porta 的 TCP 连接通常先赢，WebRTC 失败与否被掩盖。**要单独量 WebRTC，得在控制端关掉 `enable-tcp-punch`**，这样就没有 fallback 请求 | `porta-client@6bb19b190:src/client.rs` L1371-1381、`src/porta_hooks.rs` `lan_connect` L19-48；`client.rs` `tcp_punch_allowed` L361-366 | 读码 |

### 2.4 会话数据怎么走、身份怎么校验

- **一条连接里的全部消息都走 WebRTC**：视频、音频、输入、剪贴板、会话内控制消息。对上层它和 TCP、WebSocket 是同一个 `Stream` 接口。文件传输、端口转发、终端这些是独立连接，每条各自建 offer【读码，`hbb_common@ed07431:src/stream.rs`；`rustdesk@bd92623:src/client/io_loop.rs` L203-219；`src/port_forward.rs` L178/L419】。
- **底层是一条有序、完全可靠的 SCTP 数据通道**（名字 `bootstrap`，被控端拒绝无序或不可靠的通道），每条消息切成 60000 字节的片，加 1 字节片头；没有 RTP 媒体通道，编解码仍是 RustDesk 自己的【读码，`webrtc.rs` L139-159、`on_data_channel` L735-774、`send_bytes_inner` L1388-1424；官方博客 https://rustdesk.com/blog/rustdesk-1-5-0-webrtc-qos/ 】。所以它和 TCP 一样有队头阻塞【推测：单条有序可靠流的必然结果】。
- **加密只有 DTLS**，RustDesk 自己的 secretbox 层不用，但身份握手照样跑：被控端在签名过的 `IdPk` 里带上自己的 DTLS 证书指纹，控制端要求它等于实际协商到的指纹，不等就判为可能的中间人、中止并回落中继。没有可信身份（没配 Key、或签名验不过）时不做绑定，界面弹"不安全连接"确认【读码，`client.rs` `secure_connection` L1653-1785；`common.rs` `decode_id_pk_dtls` L2381-2394；`rendezvous.proto` `IdPk` L4-13；`server.rs` L262-290】。

### 2.5 候选怎么收集（直接关系到 TUN 和透明代理）

| 结论 | 出处 | 等级 |
|---|---|---|
| 只收集 UDP 候选（udp4、udp6），三种类型 host、srflx、relay；没有 ICE-TCP | fork `ice/src/network_type/mod.rs` `supported_network_types` L15-22；`ice/src/agent/agent_gather.rs` `gather_candidates_local` | 读码 |
| host 候选来自**所有网卡**：Windows 上用 `GetAdaptersAddresses` 枚举，不看网卡状态和类型；默认排除回环，RustDesk 只再滤掉 `fe80::/10`。TUN（`198.18.0.1`）、Wintun、Tailscale、VMware、Hyper-V/WSL 的 vEthernet、`169.254` 都会成为候选，每个候选一个绑在该 IP 上的 UDP socket | fork `util/src/ifaces/ffi/windows/mod.rs` `map_adapter_addresses` L324-367、`ice/src/util/mod.rs` `local_interfaces_with` L116-170；`webrtc.rs` `new_inner` L642-648 | 读码 |
| Windows 上网卡名取的是 GUID，不是"Mihomo"这类友好名，所以 webrtc-rs 的按网卡名过滤认不出 TUN；要过滤只能先自己按网卡类型映射出 IP 白名单，再用 `set_ip_filter` | fork `util/src/ifaces/ffi/windows/mod.rs` `adapter_name()` L384-393 | 读码 |
| mDNS 关闭：局域网地址以明文 IP 发给对端。打开也不实用：webrtc-rs 的 mDNS 只回 A 记录，表示不了 IPv6 host 候选，上游对端也会丢弃 `.local` 候选 | `webrtc.rs` L635；fork `mdns/src/conn/mod.rs` `send_answer` L388-425 | 读码 |
| IPv6 host 候选：每块网卡每个 /64 及更短的前缀只留一个，即系统会用作源地址的那个（开了隐私扩展时通常是临时地址）；判断不了就保留整组。这是 2026-09-19 的隐私收敛（#16263）。Windows 上 IPv6 地址字节反转的修复更早，随 #15684 首次合入时就带上了 | fork `ice/src/util/mod.rs` `ipv6_one_per_prefix`；上游 `7a367f7c`；fork `56d097c5` 说明；`rustdesk@ae6af2de:Cargo.toml` L219-220 | 读码；官方 |
| srflx：每个地址族、每个配置的 ICE 地址（包括 TURN 地址）各开一个绑 `0.0.0.0:0` 或 `[::]:0` 的 socket 发 STUN，出口由系统路由决定，开 TUN 时进隧道 | fork `agent_gather.rs` `gather_candidates_srflx` L603-738 | 读码 |
| 默认 4 个第三方 STUN：Cloudflare、Google、antisip、nextcloud。`ice-servers` 里没有任何 STUN 时会自动把它们加到前面，所以想不碰第三方，必须显式列一个自己的 STUN。另外，IPv6 打洞探测本机公网 IPv6 用的是写死的同一组，`ice-servers` 管不到 | `webrtc.rs` `DEFAULT_ICE_SERVERS` L160-169、`parse_ice_servers` L525-555；`porta-client@6bb19b190:src/common.rs` `test_ipv6` L2762-2850 | 读码 |
| TURN 只支持 UDP、只有 IPv4，必须带凭据（`turn://user:pass@host:port`）。TURN over TCP、TURNS（TLS）在 webrtc-ice 0.13 里没实现，走到就打 `Unable to handle URL`；`stuns:` 也被当成普通 UDP STUN。`has_turn_server()` 却把 `turns:` 算作有 TURN，只配 turns 时会建出注定失败的连接。没有默认 TURN | fork `agent_gather.rs` `gather_candidates_relay` L740-806；`webrtc.rs` `has_turn_server` L486-499 | 读码 |
| 所有 UDP 候选的本地偏好相同，所以 host 候选不分网卡（物理、TUN、Tailscale、VMware）优先级一样；控制端对 host 对不等待，有可用对就提名最优的，平局按检查顺序。libwebrtc（UU）则按网络代价排序（以太网 0、WLAN 10、TUN 50、Tailscale 2050，笔记 05 §3.3） | fork `ice/src/candidate/candidate_base.rs` `local_preference` L326-386；`ice/src/agent/agent_selector.rs` L228-270 | 读码；"会选中 TUN 对"是推测 |
| 检查间隔 200 ms；提名等待 host 0、srflx 500 ms、prflx 1 s、relay 2 s；被控端每对最多 74 次绑定请求（约 14.8 秒），控制端用默认 7 次。注释说被控端这个参数还在做"持久性实验" | fork `ice/src/agent/agent_config.rs` L13-38；`webrtc.rs` L557-566、L634-641 | 读码 |
| 没有续选（renomination）和持续收集，RustDesk 也从不触发 ICE 重启。选中的对断了：ICE 5 秒后进 Disconnected，控制端 io_loop 再等 3 秒没收到数据就拆掉会话，经 `restarting-show` 自动整次重连，也就是约 8 秒后可见地重连；30 秒的 Failed 只是兜底。UU 同类情况 0.02~0.31 秒就切回去了（笔记 05 §3.2） | fork `agent_selector.rs`、`agent_config.rs`（保活 2 s、Disconnected 5 s、Failed 25 s）；`webrtc.rs` L673-678；`porta-client@6bb19b190:src/client/io_loop.rs` `WEBRTC_SUSPECT_GRACE` L24、L343-367；`flutter/lib/models/model.dart` L949-952 | 读码 |

## 3. porta-server 要改什么

### 3.1 现状：走不通

| 结论 | 出处 | 等级 |
|---|---|---|
| 转发 `PunchHole` 时故意不带 `webrtc_sdp_offer`（和 `udp_port`），测试断言 offer 为空；`server/PORTA.md` 把"WebRTC 信令转发"列为第一期不做 | `porta-server@d8403ad:src/rendezvous_server.rs` L1188 注释、测试 L2219-2221；`server/PORTA.md` L22、§6 第 2 条 | 读码 |
| `handle_hole_sent` 新建的 `PunchHoleResponse` 没拷 answer，等于丢掉；`RelayResponse` 分支把整个消息（含 answer）原样转发 | `rendezvous_server.rs` `handle_hole_sent` L963-1006、`handle_tcp` L832-872 | 读码 |
| 回完响应就把控制端的连接从 `tcp_punch` 表里取走（`send_to_tcp` L1264、`send_to_tcp_sync` L1292 都 `remove`），之后没法再往这条连接写 | 同上 | 读码 |
| 不认识 `IceCandidate`：`handle_tcp` 走到 `_ => {}` 返回 false，连接断开；客户端注释说的正是"不认识的服务器收到第一个候选就断开" | `rendezvous_server.rs` L903-906、L1662、L1716-1726；`client.rs` L757-761 | 读码 |
| **同一内网时发的是 `FetchLocalAddr`**，它没有 offer 字段（回的 `LocalAddr` 也没有 answer 字段），被控端的 `handle_intranet` 完全不碰 WebRTC。只补字段转发的话，局域网场景里 WebRTC 根本不会启动 | `rendezvous_server.rs` `handle_punch_hole_request` L1176-1202；`porta-cardo@df76a0c:protos/rendezvous.proto` L203-215；`rendezvous_mediator.rs` `handle_intranet` L754-809 | 读码 |

现状下这些都不会被触发：offer 不转发，被控端就不回 answer，控制端由 guard 关掉 offerer，preferred 那条只剩 IPv6 打洞和中继（`client.rs` L1336-1340）【读码】。

### 3.2 评估用的最小临时转发（临时分支，不合并、不审查）

全在 `src/rendezvous_server.rs`【推测：按读码逐个函数估行数】：

| # | 位置 | 改动 | 估计行数 |
|---|---|---|---|
| ① | `handle_punch_hole_request`（L1059-1232） | 给 `PunchHole` 填 `webrtc_sdp_offer`；offer 非空时跳过 `same_intranet`、改发 `PunchHole`。`udp_port` 继续不转发（否则被控端会走明文 UDP 回 answer，而服务端丢弃 UDP 来的 `PunchHoleSent`） | 约 5 |
| ② | `handle_hole_sent`（L963-1006） | 给 `PunchHoleResponse` 填 `webrtc_sdp_answer`；answer 非空时不把控制端的 sink 从 `tcp_punch` 取走 | 约 10 |
| ③ | `handle_tcp` 的 `RelayResponse` 分支（L832-872） | answer 非空时同样保留 sink | 约 5 |
| ④ | `handle_tcp` 新增 `IceCandidate` 分支 | `socket_addr` 非空表示来自被控端：找 `tcp_punch` 里控制端的 sink 就地发送，不取走；否则来自控制端：按 `id` 用 `pm.get_in_memory` 找被控端，`send_udp` 转发。两种都返回 true，保持连接 | 30~40 |
| ⑤ | 新辅助函数 | "就地发送、不取走 sink"（`Sink` 不能 Clone，临时可以持锁发送） | 约 15 |
| ⑥ | 日志 | 在 ①~④ 各打一行 info：offer 已转发、answer 经哪条路转发、两个方向各转了几个候选。实测要靠它核对（`conn_tracker` 判不出 WebRTC，见 §3.3） | 约 10 |

合计 60~100 行，不含测试。现有测试 `punch_hole_forwards_v6_both_ways` 会失败，临时分支上无妨。客户端一行不改。只用 21116/TCP，不碰 WebSocket。

### 3.3 正式实现还要补的

| 项 | 做法 | 依据 |
|---|---|---|
| 防伪造 | 转发带 offer 的 `PunchHole` 时，从 offer 里解析出 DTLS 指纹，登记一条待定会话 {控制端地址, 被控端 ID, session_key, 过期时间}。被控端发来的 answer 和 `IceCandidate` 只有 session_key 对得上、没过期才转发；控制端发来的 `IceCandidate` 只能发往它自己请求过的被控端。**不按来源 IP 校验**：被控端的 TCP 和 UDP 可能从不同代理出口出去，正常请求会被误拒 | session_key 每次连接一个新值：webrtc-rs 在没给证书时为每个连接新生成 ECDSA P-256 密钥对（fork `webrtc/src/peer_connection/mod.rs` L281-289）【读码】。它挡得住看不到流量的伪造者，挡不住链路上的观察者（offer 经明文 UDP 发给被控端）。伪造最多造成拒绝服务，不能中间人，前提是服务端持私钥、下发签名的 pk（§2.4）【读码】 |
| 上限 | 每条连接的 `IceCandidate` 条数（两个方向各约 64，和客户端缓冲一致），candidate 字符串约 1 KB，session_key 约 128 字节；转 UDP 已受 `UDP_SEND_QUEUE` 约束 | 仿现有 `MAX_RELAY_REQUESTS`（L230）【推测】 |
| `tcp_punch` 改共享句柄 | 每条连接一个 `Arc<Mutex<Sink>>` 或 mpsc，避免持全表锁发送；连接结束按地址删条目时只删自己的（现在按地址删，会误删同一键下别的连接的条目；WebSocket 反代下端口记成 0，同 IP 多个控制端互相覆盖，候选连接活得更久会更容易撞） | `rendezvous_server.rs` L283、L1724-1726、`ws_client_addr` L1812-1828【读码】 |
| 强制中继 | 服务端强制中继（`ALWAYS_USE_RELAY` 或网段掩码）时去掉 offer。否则 offer 声明了 `ice_policy=all`，被控端照样做完整 ICE，服务端挡不住直连。上游 PR #15684 的表 A 第 7 行也是"hbbs 清空 offer，连 TURN 也不走" | `rendezvous_mediator.rs` L1065-1076；`webrtc.rs` `encode_endpoint`；`rendezvous_server.rs` L1165-1175【读码】；PR #15684【官方】 |
| 同一内网分支 | 带 offer 时改发 `PunchHole`、让 ICE 决定（符合"不假定运行环境"），还是扩展 `FetchLocalAddr`。前者的代价是：跨网时 host 候选也照样发出去（见下一行） | §3.1【读码】；取舍待定 |
| 隐私 | host 候选只转给通过认证、有权限的请求方（登录的设备主人、地址簿授权，第三期签名上线后是验签通过的设备），其他人只转 srflx/relay。不改客户端 | §5.2【推测】 |
| 连接记录 | `conn_tracker` 现在判不出 WebRTC：WebRTC 赢了可能被记成 `direct_tcp`、`direct_tcp_or_v6`、`relay`、`relay_or_v6`、`direct_lan`，看合并进来的 fallback 请求做了什么（两条请求按同一来源 IP 和被控端 ID、2 秒内合并成一次）。要加"带了 offer""answer 非空"两列（要 sqlx 迁移），真实赢家（连接类型、是否经 TURN、是否 IPv6）只有客户端知道，挂在 01 块 `/api/porta/v1/` 的上报上 | `porta-server@d8403ad:src/conn_tracker.rs` `outcome` L288-307、L397-430【读码】 |
| STUN（可选） | porta-server 的 UDP 端口回 STUN Binding（04 §3.6 原估几十行），客户端 `ice-servers` 指过去；IPv6 探测那条路径要另改客户端代码才能不碰第三方 | §2.5【读码】 |
| 明文 UDP 段 | 服务端转给被控端的 `PunchHole`（含控制端的 ICE 用户名、密码、指纹）和控制端的候选（含全部网卡地址）走明文 UDP；被控端的 UDP 会合 socket 还不检查来源地址，知道它映射地址的人能伪造带 offer 的 `PunchHole` 占满 16 个应答名额。放到第三期设备签名或加密方案里一起处理，或明确接受 | `rendezvous_mediator.rs` `start_udp` L423；`rendezvous_server.rs` `send_udp` L1339-1351【读码】 |

### 3.4 工作量

- 临时转发：60~100 行，1 天（含部署到测试机）【推测】。
- 正式实现：300~500 行含测试，2~3 天；不含 STUN 和客户端上报（那两项分别约几十行和挂在 01 块上）【推测】。满足 §3.6 条件 (c)。临时分支的实际耗时可以用来校准这个估计。
- 社区有一份开源实现可以参考：`rxxozqfoe/rustdesk-server#35`（"WebRTC signalling for RustDesk 1.5.0 clients"，2026-10-08 合进那个分支）【旁证，没审过】。闭源的 Server Pro 1.8.7 也有，无从参考。

## 4. 成熟度

### 4.1 时间线

| 时间 | 事件 | 出处 | 等级 |
|---|---|---|---|
| 2025-05-14 | webrtc-rs 0.13.0 发布（上游至今钉在这个版本） | https://crates.io/api/v1/crates/webrtc/versions | 官方 |
| 2025-11 | hbb_common 里出现 `WebRTCStream` 雏形和示例，没接入客户端；rustdesk `5b214418` 只改了构建参数和子模块指针 | `hbb_common` `git log -- src/webrtc.rs`；`rustdesk@5b214418` | 读码 |
| 2026-05~08 | PR 审查期迭代：大量提交的作者日期落在这段（trickle 5 月、各类泄漏和取消安全修复 7~8 月） | `hbb_common` 提交的 author 日期 | 读码 |
| 2026-07-26 / 09-05 | PR #15684 创建 / 合并（UTC），+3109/-539，71 个文件；主线提交 `ae6af2de` 日期 09-06 | https://github.com/rustdesk/rustdesk/pull/15684；`rustdesk@ae6af2de` | 官方；读码 |
| 2026-09-04 | hbb_common 的 WebRTC 数据面一次性 rebase 进主线；之后到 09-17 只有 6 个提交（其中 WebRTC 专属修复 2 个：`166bb3d` 不复用 ICE 已失联的缓存会话、`daf84c2` 绑定请求上限），10-20 的头 `ed07431` 之前再没改过 | `hbb_common` `git log -- src/webrtc.rs` | 读码 |
| 1.5.0 之前 | 补了：信令必须加密否则不发（#16224，`f4808b71`）、被控端应答上限 16（#16225，`4df7404a`，因为伪造的 offer 在密码和接受提示之前就能让被控端跑 ICE）、静默对端约 8 秒恢复（#16117，`f164c9a9`）、IPv6 隐私收敛（#16263） | 各提交说明 | 官方 |
| 2026-09-30 | **1.5.0 发布**（GitHub release，UTC），第一个带 WebRTC 的正式版；1.4.x 都没有 | https://api.github.com/repos/rustdesk/rustdesk/releases/tags/1.5.0 ；`git show <tag>:src/client.rs` | 官方；读码 |
| 2026-10-01 | Server Pro 1.8.7："add Webrtc support" | https://github.com/rustdesk/rustdesk-server-pro/releases/tag/1.8.7 | 官方 |
| 2026-10-14 | 官方博客介绍 1.5.0 的 WebRTC：只有定性描述，自建要手动开 `enable-webrtc=Y`，没有成功率或稳定性数据 | https://rustdesk.com/blog/rustdesk-1-5-0-webrtc-qos/ | 官方 |
| 2026-10-15 | #16563（两条竞速腿都失败时报一个错误，`c0750fb5`），不在 1.5.0 里，Porta 基线有 | `git merge-base --is-ancestor` | 读码 |
| 2026-10-21 | Porta 客户端基线 `bd92623`（版本号 1.5.1） | — | 读码 |

到 Porta 基线时，这条路径在主线上约 6.5 周，在正式版里约 3 周。

### 4.2 代码规模和测试

- `webrtc.rs` 2844 行，L1541 起是测试，共 31 个单元测试；生产代码约 1540 行。客户端侧逻辑在 `src/client.rs`（236 处提到 webrtc）、`src/rendezvous_mediator.rs`（55 处）、`src/client/io_loop.rs`（12 处）【读码】。
- `webrtc.rs` 文件头有一份升级检查清单，列出依赖 webrtc-rs 0.13 内部行为的地方，例如 `is_relayed`、`is_remote_ipv6` 靠解析 0.13 的 Display 字符串实现【读码，`webrtc.rs` L1-17】。
- Porta 的 `webrtc.rs`、`stream.rs` 和上游逐字相同；`client.rs` 只多了第三期局域网多候选的 3 处挂钩，另把 `secure_connection` 改成 `pub(crate)`；`client.rs` 和 `rendezvous_mediator.rs` 里没有任何涉及 WebRTC 的改动【读码，`git diff bd92623..6bb19b190`】。

### 4.3 依赖：webrtc-rs 0.13 和 rustdesk 的分支

| 结论 | 出处 | 等级 |
|---|---|---|
| 钉 0.13 的原因：0.14 起要 rustc ≥1.87，上游 CI 用 1.75（为 Win7 和 sciter）。Porta 不支持 Win7，不受这条限制 | `hbb_common@ed07431:Cargo.toml` L70-74；AGENTS.md | 读码 |
| webrtc-rs 官方：0.17.0（2026-01-31）是旧 Tokio 架构的最后一个功能版，0.17.x 只修 bug（0.17.2，2026-07-20）；主线改写为 Sans-I/O 核心，0.20.0（2026-07-31）是新架构第一个正式版，现在推荐 0.21.x（0.21.1，2026-10-11）。0.13 不在任何维护线上 | https://webrtc.rs/blog/2026/01/31/webrtc-v0.17.0-feature-freeze-sansio-shift.html ；https://webrtc.rs/blog/2026/07/31/announcing-webrtc-v0.20.0.html ；crates.io；README | 官方 |
| 升级有三条路：留在 0.13 分支跟上游 RustDesk；升 0.17.x（同架构、有维护，不用重写，但分支的 33 个补丁要移植）；升 0.20+（API 改成 trait 事件处理，等于重写 `webrtc.rs`） | 同上；`webrtc.rs` L16-17 写着"0.17+ exposes them" | 官方；"等于重写"是推测 |
| rustdesk 分支 `49c89bd8` = 0.13.0 加 33 个提交（2026-08-25~09-18）：SCTP（dcsctp 的定时、IPv6 安全 MTU 1191、默认不用拥塞窗口、重排窗口、尾丢恢复、SACK 不超过 MTU）；Windows 网卡枚举（IPv6 字节反转、网卡名和掩码、结构体布局）；ICE（每前缀一个 IPv6、暴露绑定请求次数和检查间隔） | https://github.com/rustdesk-org/webrtc/commits/49c89bd8d30e6e62e4c1a96cee38fdc11f79ef63 ；`rustdesk@bd92623:Cargo.toml` L229-256 | 官方 |
| SCTP 改动有过一次两天内的回退：09-06 合入的 T3-rtx 探测恢复让突发加静默负载的 p99 变成 2~4 倍，09-08 被 #16121 回退。上游自测（分支自带的链路模拟器，sparse 负载两行）里 KCP 的 p99 仍更好：RTT 70 ms 时 138/130 对 200/208 ms，RTT 150 ms 时 257/250 对 407/507 ms。`Cargo.toml` 的补丁注释还停留在回退前的描述，不能当现状看 | `rustdesk@691830fe` 提交说明；分支 `db3b07a9` | 官方（模拟数据，非实网） |
| 0.13 之后官方修过的 bug，分支都没合：0.17.2 的 #799、#803（ICE consent 检查）、#812、#818。但 #807 的 MTU 1191 分支已独立实现；#818（mDNS 已禁用）、#812（`ListenConfig` 不在 ICE 路径上）与 RustDesk 的用法基本无关。官方承认旧回调模型会泄漏（#772，not_planned），上游 `webrtc.rs` 用弱引用规避 | https://github.com/webrtc-rs/webrtc/releases/tag/v0.17.2 ；#772 | 官方 |
| **未实测的隐患**：分支里 ICE 候选的接收循环遇到任何 `recv_from` 错误都直接退出，而且返回值被丢掉、不打日志，这个候选从此静默失去接收能力。Windows 上未连接的 UDP socket 会因先前发出的包收到 ICMP 端口不可达，在下一次 `recv_from` 上报 `WSAECONNRESET`（10054）；分支里没有关掉 `SIO_UDP_CONNRESET`。ICE 会向对端每个候选发检查，不可达的地址（对端 TUN 地址、别的网段）可能让本端某个 host 候选死掉。上游知道 10054 "也发生在 UDP 上"，只给 KCP 和打洞 socket 处理了，ICE socket 没处理 | fork `ice/src/agent/agent_internal.rs` `recv_loop` L1116-1150、`start_candidate` L1043-1046；`rustdesk@bd92623:src/rendezvous_mediator.rs` L325-327；PR #15684"KCP/UDP robustness"一段 | 读码；会不会命中是推测 |

### 4.4 官方态度和使用面

- **只在公共服务器上默认开**。维护者在 #16372 里说公共服务器只是演示，为了鼓励用户在 1.5.0 里测 WebRTC 关掉了公共服务器的 IPv6，测完可能恢复但不保证【官方，https://github.com/rustdesk/rustdesk/issues/16372 】。代码和界面里没有"实验性"字样【读码】。
- **开源服务端不支持**：`rustdesk-server` 到 `873230e`（2026-10-10）没有任何 WebRTC 相关提交或 PR【官方，https://github.com/rustdesk/rustdesk-server/commits/master 】。自建环境里只有 Server Pro 用户（1.8.7 起，约 3 周）可能用上，而客户端对自建服务器默认关。
- **issue 很少，但说明不了稳定**：GitHub 上提到 webrtc 的 issue 一共 17 条，2026-09 以来 5 条，WebRTC 专属的只有 #16653（防火墙环境连不上，被关为 invalid）和讨论 #16613（0 回复）；#16676、#16605 是 TCP 打洞的问题【旁证】。用到它的人本来就少。
- 上游官方服务器在同一内网时怎么处理带 offer 的请求（改发 `PunchHole` 还是放弃 WebRTC），闭源看不到【待确认】。

### 4.5 小结

早期、公测级，5 分制约 2 分（1 = 原型，5 = 长期默认开、多版本验证）【推测，综合上面各条】。
- 减分：正式版里只有约 3 周；只在自家公共服务器默认开；开源服务端不支持；依赖靠 rustdesk 单方面维护的 0.13 分支；SCTP 调参回退过、模拟里尾延迟落后 KCP；被控端参数还在做实验；Windows 上 ICE socket 有静默失效的隐患。
- 加分：PR 审查期长（2026-05~08），设计文档完整（传输组合矩阵、安全模型），31 个单元测试，DTLS 指纹签进身份、验证失败就中止，失败自动回落原有路径，合入后的 WebRTC 专属修复不多。
- 所以 §3.6 条件 (b)（50 次循环无崩溃、无卡死）必须实测，不能拿上游现状代替。

## 5. 复杂网络、隐私、性能的预期

### 5.1 复杂网络

| 环境 | 预期 | 依据 | 等级 |
|---|---|---|---|
| 路由器透明代理只代理 TCP | ICE 全程 UDP，不受影响。被控端收到 offer 后发出全部 host 候选，两端自己做连通性检查；物理网卡对物理网卡的 host 对（socket 绑物理 IP，Windows 强主机模型加直连网段路由，从物理网卡出去）不需要服务端判同网就能通 | `handle_punch_hole` L1060-1103；`on_ice_candidate` L679-703；笔记 04 §3.2 | 推测（代码部分已读码） |
| 两端 UDP 走不同代理出口（04 §2.5.8） | 服务端看到两个不同的 UDP 地址，现有路径判不出同网；ICE 的 host 对照样能通。srflx 各是各的代理出口 | 同上；前提是临时分支对带 offer 的请求改发 `PunchHole`（§3.2 ①） | 推测，待实测 |
| 本机开 TUN：TUN 对 TUN | 两端 TUN 默认都是 `198.18.0.1`，目的地是本机地址，检查失败；即使到了自己的 ICE，也过不了 STUN 短期凭据校验，DTLS 指纹也对不上，不会误连。可能触发上面的 10054 隐患，但只弄死 TUN 那个候选，无害 | RFC 8445 §7.2.2；`webrtc.rs` `set_key` L1245-1252；笔记 04 §3.3 | 推测 |
| 本机开 TUN：本端 TUN 对 对端物理局域网 IP | 强主机模型下进 TUN。mihomo 对私网段是 DIRECT 时会从物理网卡代发，对端学到一个 prflx 候选并回包，这一对能通，但经过 mihomo 的用户态转发。因为 host 优先级相同（§2.5），它**可能被选中**；之后关掉 TUN 就断，约 8 秒后整次重连。私网段走代理或被 `route-exclude-address` 排除时，这一对失败，只是白费几次检查。UU 日志里同类 socket 被淘汰（笔记 05 §3.1），但 UU 是靠网络代价选的物理对 | 笔记 04 §3.3 表；笔记 05 §3.3、§4 | 推测，待实测 |
| 本机开 TUN：srflx | srflx 的 socket 绑通配地址，进 TUN 交给 mihomo。STUN 域名经系统 DNS 解析（fake-ip 下是假地址，mihomo 再映射回域名按规则走）：DIRECT 时拿到家宽出口；走支持 UDP 的代理时拿到代理节点的出口，对端能连上的话就是一条"经用户自己代理服务器的直连"，类型是 srflx，`is_relayed` 返回假，界面显示直连；代理不支持 UDP 时这台 STUN 拿不到 srflx。不同 STUN 可能命中不同规则 | fork `gather_candidates_srflx`；笔记 05 §3.3 | 推测 |
| UDP 被封的网络 | 没有 ICE-TCP，TURN 只支持 UDP，WebRTC 整条失败，回落 hbbr（TCP）。不比现在差，但 UU 这时还有 ICE-TCP 和 TURN over TLS 443 | §2.5 | 读码 |
| 会话中换网（开关 TUN、切 Wi-Fi、ULA 出现又消失） | 选中的对断了约 8 秒后整次重连，期间画面中断；UU 是无感切换。维护者路由器的 ULA 每隔 20~75 分钟变一次（笔记 05 §7 第 4 项），如果选中的是 ULA 对，会反复重连 | §2.5 末行 | 读码；ULA 影响是推测 |
| 多网卡、虚拟网卡 | VMware、vEthernet、Tailscale 的地址也发出去并参与检查。Tailscale 对如果通了（两端都在同一个 tailnet），可能被选中，经 DERP 的话界面仍显示直连 | §2.5 | 推测 |
| Windows 防火墙 | 被控端以 SYSTEM 服务运行，入站 UDP 检查能不能进来，取决于安装时按程序路径加的放行规则是否覆盖 UDP；便携版第一次会弹提示 | 笔记 04 §11 | 待实测 |

### 5.2 隐私

- **暴露什么、何时暴露**【读码，`handle_punch_hole` L1065-1076、`spawn_webrtc_answerer` L864-890、`on_ice_candidate` L679-703】：一旦服务端转发信令，被控端对到达的任意 offer 都建连接、回 answer、立即 trickle 候选，发生在连接认证和密码之前。暴露的是所有网卡的私网 IPv4（含 TUN、Tailscale 100.x、VMware、vEthernet、169.254）、ULA、每个前缀一个临时全局 IPv6、srflx 公网地址（可能是代理出口）。控制端的候选同样发给被控端。对比现状：认证前控制端本来就能拿到被控端的公网 IPv4 和（经 IPv6 打洞）全局 IPv6；Porta 的局域网候选只在服务端判成同网之后才发。
- **谁能看到**：控制端到服务端、被控端到服务端两段是加密 TCP；服务端能读到候选内容；服务端到被控端那段是明文 UDP，链路上的人能看到控制端的 ICE 凭据和全部候选（§3.3 末行）【读码】。
- **第三方 STUN**：开了 `enable-webrtc` 后，每次连接控制端（以及收到 offer 的被控端）都向所有配置的 ICE 地址发请求；没配自己的 STUN 时就是那 4 个第三方，暴露使用时间和真实 IP（或代理出口）。另外，和 WebRTC 无关，Porta 默认开的 IPv6 打洞本来就在访问同一组写死的 STUN【读码，§2.5】。
- **缓解，按价值排序**【推测】：
  1. 服务端转发层做权限控制：只把 offer 和 host 候选转给通过认证、有权限的请求方，其他人剥掉 host 候选。不改客户端，也不重新引入"按网络判断"。
  2. 客户端用 `set_ip_filter` 加白名单，去掉 TUN（`198.18.0.0/15`）、`100.64.0.0/10`、虚拟网卡、169.254，保留物理网卡的 ULA 和全局 IPv6。既少暴露，又避开 §5.1 的 TUN、Tailscale 平局。但要新写网卡分类：现有 `lan.rs` 的 `is_physical` 只管 IPv4，也不排除 VMnet、vEthernet（它们靠 `select_candidates` 的"有网关"条件排除）；而且要改 `webrtc.rs`，偏离"评估不改上游代码"。
  3. `ice-servers` 指向自己的 STUN（porta-server 回 STUN Binding），IPv6 探测路径另改。
  4. mDNS 不推荐（§2.5）。
  5. 只走中继能去掉全部暴露，但也就没有直连了。
  - "等密码通过再发 host 候选"不可行：RustDesk 的认证跑在已经建好的数据通道上。

### 5.3 性能

| 结论 | 出处 | 等级 |
|---|---|---|
| 一条有序可靠的 SCTP 流承载全部消息，队头阻塞和 TCP 一样 | §2.4 | 读码；队头阻塞是推测 |
| 分支默认不用拥塞窗口（`allow-webrtc-congestion-control=Y` 才打开）。在途数据上限 1 MiB 或 1024 个块，对端通告的接收窗口 1 MiB，吞吐上限约 1 MiB/RTT：30 ms 约 280 Mbps、70 ms 约 120 Mbps、150 ms 约 56 Mbps（计算）。1080p60 够用；长 RTT 链路上的高码率 4K60（几十到约 100 Mbps）可能被窗口卡住 | fork `sctp/src/association/mod.rs` L54-105；`webrtc.rs` L650-653 | 读码；吞吐是计算 |
| 不用拥塞窗口时，RTO 下限 100 ms、方差下限 10 ms，每个数据块都要求立即确认；初始 RTO 500 ms。拥塞控制打开时才用 dcsctp 的 400 ms 下限 | fork `sctp/src/timer/rtx_timer.rs` L62-63、L91-97 | 读码 |
| 上游合并提交里的模拟（单程 35 ms、1% 丢包、30 fps 每帧 12 KB）：开窗口时 9.9 秒的视频拖成 20.7 秒、平均延迟 5.5 秒；不开窗口保持实时、平均 113 ms。代价是拥塞时不退让，靠应用层 QoS（按测得延迟调码率和帧率），和 KCP 路径一样 | `rustdesk@ae6af2de` 提交说明（约第 828~847 行） | 官方（模拟数据） |
| 0.13 的数据通道吞吐和 CPU 没有公开测量。webrtc-rs 2026-07-31 宣布的大幅提升（有序可靠单流默认 184、专用 reactor 575）属于重写后的 0.20，不是 0.13 | https://webrtc.rs/blog/2026/07/31/announcing-webrtc-v0.20.0.html ；https://github.com/webrtc-rs/webrtc/issues/101 | 官方 |
| 进程内全部 WebRTC I/O（ICE、DTLS、SCTP）跑在一个 2 线程的 tokio 运行时上，所有会话共用。1080p60 10~30 Mbps 约每秒 1~3 千个包，4K60 80 Mbps 约每秒 8.5 千个（单向，按 MTU 1191 算），每包都要用户态 SCTP 加 DTLS（AES-GCM）。CPU 要实测，也要看多个被控会话同时在线时 2 个线程够不够 | `webrtc.rs` `WEBRTC_RT` L172-194 | 读码；包速是计算 |
| 建连耗时：ICE 检查间隔 200 ms（UU 弱连接时 8 ms），连通后还有 DTLS 握手、SCTP 四次握手、数据通道打开、RustDesk 身份握手；控制端把已建好的中继压 2.5 秒等 WebRTC | §2.3、§2.5 | 读码 |

## 6. 实测方案（给维护者照着做）

### 6.1 设备和角色

| 设备 | 客户端 | 角色 | 说明 |
|---|---|---|---|
| Windows 台式机（家里局域网，开 TUN） | Porta 评估构建 | 控制端和被控端都要做；主要日志来源 | |
| MacBook（家里局域网） | **官方原版 1.5.x**（官方 1.5.0 有 aarch64 和 x86_64 的 dmg） | 同网场景的对端，做被控端（不用开开关）或控制端（要勾 `enable-webrtc`） | 现在装的 1.4.2 不能参与：WebRTC 从 1.5.0 才有，1.4.2 的 proto 里没有这些字段，收到 offer 当未知字段忽略，也发不出 offer【读码：按 tag 查 `src/client.rs`、hbb_common 指针】。1.5.0 不含 #16563，只影响控制端的报错文本 |
| Windows 笔记本（外地网络） | Porta 评估构建 | 外网一端 | 如果能带回家一次，可以补测"两台 Porta 同网"，这是最理想的同网对照 |
| Windows 沙盒（台式机上） | Porta（便携方式运行） | 只在需要两台 Porta 同时在场时用（稳定性补测） | 沙盒在台式机后面多一层 NAT，经 Hyper-V 虚拟交换机和台式机直接互通，ICE 会走 vEthernet 那一对，**结果不代表真实局域网**，不进场景统计【推测】 |
| Linux 测试机 | 临时分支的 porta-server + hbbr | 会合服务器和中继 | porta-server 必须持有私钥；hbbr 照常配 `-k` |

### 6.2 准备

1. **服务端**：按 §3.2 做临时分支，部署到测试机。客户端都用 21116/TCP 连，不用 WebSocket。
2. **客户端配置**（每台）：
   - ID 服务器指向测试机；**Key 填测试机 porta-server 的公钥**（Porta 构建里注入的公钥如果不是测试机的，必须手填；Mac 原版一定要填）。填错或不填，offer 和 answer 会被静默丢掉（§2.1）。
   - 客户端设置里不要配代理（TUN 不受影响）。
   - 先确认 Mac 的 1.5.x 能在测试机上注册上线【待确认：上游 rustdesk-server 1.1.16 出过丢弃 1.5.0 注册包的问题（#733），porta-server 是否受影响没核对】。
3. **日志**：
   - 控制端日志在 Porta 客户端日志目录（`%APPDATA%\<应用名>\log`）；被控端服务进程不以当前用户运行，日志不在这里（笔记 05 §7 第 6 项）。Mac 原版的日志目录待核对。
   - 日志里有真实 IP 和设备信息，只在本地分析，入库只写分类结果。
   - 选中候选对在默认日志里看不到（§6.5）。二选一：(a) 给控制端设环境变量 `RUST_LOG=debug,webrtc_ice::agent::agent_internal=trace` 后重启 Porta【推测：flexi_logger 的环境变量能盖过内置过滤串，没在 Porta 构建上实测，界面进程是否继承也要确认】；(b) 评估构建里临时加一行 info 日志，在连上后打印 `get_selected_candidate_pair()`（只用于评估，不合并）。推荐 (b)，更可靠。
4. **冒烟**：台式机连 Mac 一次，确认控制端日志里有 `UDP+IPv6+WebRTC punch attempt`（或含 `WebRTC` 的 punch_type）、服务端日志里有 offer、answer、候选的转发记录，再开始正式测。

### 6.3 三组开关（都设在控制端，被控端没有开关）

| 组 | 设置 | 回答什么 |
|---|---|---|
| A 基线 | `enable-webrtc` 关，其余用 Porta 默认（TCP 打洞开、IPv6 打洞开、UDP 打洞关，局域网多候选照常） | 现有 Porta 路径的结果 |
| B 只测 WebRTC | `enable-webrtc` 开；`enable-tcp-punch`、`enable-ipv6-punch`、`enable-udp-punch` 关；`relay-fallback-delay` 改成 10 | ICE 到底能不能连通、选中哪一对。关 TCP 打洞后没有 fallback 请求，Porta 的局域网 TCP 不会抢先；中继结果压 10 秒，给 ICE 足够时间 |
| C 实际组合 | `enable-webrtc` 开，其余 Porta 默认，`relay-fallback-delay` 默认 2.5 | 真实体验：谁赢、多快 |

- `enable-webrtc` 和 `relay-fallback-delay` 在设置界面里勾、填。`enable-tcp-punch` 等三项如果界面上没有，就在客户端退出后改本地配置文件（`<应用名>_local.toml` 的 `[options]`）【待核对：界面位置和文件名】。
- `ice-servers` 评估期不改：用默认的 4 个第三方 STUN，不配 TURN（已有 hbbr）。

### 6.4 场景和次数

| # | 场景 | 控制端 → 被控端 | 网络设置 | 次数（A/B/C） |
|---|---|---|---|---|
| S1 | 同一局域网，两端开 TUN | 台式机 → Mac；反向 Mac → 台式机 | 平常的代理规则 | 正向 10/10/5；反向 B 组 5 |
| S2 | 同一局域网，两端 UDP 走不同代理出口 | 台式机 → Mac | 台式机的 mihomo 里把测试机 IP 和那 4 个 STUN 域名指向一个支持 UDP 的代理节点，Mac 保持直连。用服务端的注册记录确认两端的 UDP 注册 IP 不同，确认分组生效 | 10/10/5 |
| S3 | 外网连回家 | 笔记本 → 台式机 | 笔记本所在网络照常 | 10/10/5 |
| S4 | 家里连外网 | 台式机 → 笔记本 | 同上 | 10/10/5 |
| S5 | IPv6 | 笔记本 → 台式机 | 两种状态各测：笔记本有 IPv6；在笔记本网卡属性里临时取消 IPv6（笔记本所在网络没 IPv6 时，改连手机热点拿 IPv6） | 每种状态 A 5、B 5 |
| S6 | 会话中换网 | 台式机 → Mac（B 组） | 会话中依次：台式机关 TUN、再开 TUN；Mac 关 Wi-Fi 再开 | 每个动作 3 次 |
| S7（可选） | UDP 被封的网络 | 笔记本 → 台式机 | 有封 UDP 的网络（例如某些访客网）时测 | B 3、C 3 |

S2 是关键场景：它就是 04 §2.5.8 的缺口，现有路径预期判不出同网（不出 `direct_lan`），ICE 预期靠 host 对直连。

### 6.5 每次记录什么

**结果**：
- 连上没有；赢家的连接类型（会话窗口里显示的连接类型，`WebRTC`、`WebRTC/IPv6`、TCP 直连、中继）。
- 选中的候选对（§6.2 第 3 步的日志）：两端各是 host、srflx、prflx 还是 relay；udp4 还是 udp6；本端 host 在哪块网卡（物理、TUN、Tailscale、虚拟机）。srflx 记"家宽出口"还是"代理出口"，不记 IP。

**控制端日志里的固定文字**【读码，`rustdesk@bd92623:src/client.rs`、`hbb_common@ed07431:src/webrtc.rs`；release 构建默认 debug 级】：

| 文字 | 级别 | 含义 |
|---|---|---|
| `#{i} {punch_type} punch attempt with …` | info | punch_type 含 `WebRTC` 说明 offer 发出去了（fallback 那条是 `TCP`） |
| `WebRTC signalling to … cannot be encrypted, punching without WebRTC` | warn | 密钥交换失败，offer 被丢（多半是 Key 不对） |
| `webrtc offerer setup failed` | warn | 没建出 offerer |
| `failed to set WebRTC answer` / `failed to set WebRTC relay answer` | warn | answer 坏了，这一轮不带 WebRTC |
| `{elapsed} used to establish WebRTC connection`（中继路径）/ `… with {punch_type} punch`（打洞路径） | info | WebRTC 连上及耗时 |
| `relay requested from peer, time used: …` | info | 被控端走了 `relay_v4`，answer 在 `RelayResponse` 里 |
| `WebRTC secure handshake failed (…), falling back to relay` | warn | 身份握手失败、回落中继 |
| `WebRTC leg also failed`、`fallback leg also failed: …` | warn | 竞速里某条腿失败 |
| `WebRTC session peer connection state: connected/failed/…` | debug | ICE/DTLS 状态（target 是 `hbb_common::webrtc`） |
| `Local data channel bootstrap open.` | debug | 数据通道打开 |
| `Peer stopped answering, reconnecting` | — | 会话中断开、自动重连（S6 看它） |

`WebRTC failed: …` 不是日志行，是竞速返回给界面的错误文本。

**服务端**：临时分支的日志（offer 已转发；answer 经 `PunchHoleSent` 还是 `RelayResponse`；两个方向的候选数）；`conn_tracker` 的结果标签只作参考，它判不出 WebRTC（§3.3）。

**耗时**：控制端日志里从第一行 `#1 … punch attempt` 到赢家那一行（`used to establish …`、`Hole Punched`、中继建立）的时间差；另外用手机秒表记一次"点连接到出画面"，每个场景测 3 次即可。

### 6.6 性能

- 在 S1（局域网）和 S3（外网）各选一组：B 组赢家是 WebRTC 直连的一次，和 A 组的直连（TCP）或中继各比一次。
- 被控端全屏播放一段 1080p60 的视频，两端画质、编码设置相同，各看 2 分钟：打开会话窗口的"显示质量监测"，记帧率、延迟、速度、编码；两端在任务管理器里记 Porta 进程的平均 CPU（看 1 分钟）。有 4K 显示器的话加测一次 4K。
- S1 里用 B 组开一次 30 分钟的长会话，记中途卡顿、断开次数（留意 ULA 变化，§5.1）。

### 6.7 50 次连接断开（稳定性）

- **主测**：台式机 → 笔记本，两端都是 Porta，B 组开关（每次都走 WebRTC，压力最大）。**补测**：台式机 → Mac 20 次（同网路径）。
- 每次：发起连接 → 出画面后停 10~20 秒 → 关会话窗口。其中第 10、20、30、40、50 次改成在"正在连接"时就关窗口，测取消路径（上游修过多处取消安全问题）。
- 每 10 次记一次两端 Porta 进程的内存（工作集、专用字节）、句柄数、线程数（任务管理器"详细信息"加列，或 `Get-Process` 看 `WS`、`PM`、`HandleCount`、`Threads`）。
- 看什么：
  - 崩溃：进程消失、Windows 事件查看器里"应用程序错误"、WER 报告；
  - 卡死：超过 30 秒停在"正在连接"、既不报错也不回落；
  - 泄漏：内存、句柄、线程随次数持续上涨；最后 10 次 WebRTC 是否仍然赢（被控端应答名额只有 16 个，泄漏的话十几次后 WebRTC 就不再应答，表现为后面的连接全走中继）。
- 半自动化可以试 PowerShell 循环调 `<Porta 程序> --connect <ID>`，到时间后关窗口【待实测：Porta 是否支持、密码怎么带】；不行就手动，50 次约 30 分钟。

### 6.8 记录表（每次连接一行）

| 场景 | 组 | 序号 | 方向 | 结果 | 赢家类型 | 选中对（本端类型/族/网卡 ↔ 对端类型/族） | srflx 出口 | 耗时（日志） | 服务端：answer 路径 / 候选数 | 备注 |
|---|---|---|---|---|---|---|---|---|---|---|

### 6.9 时间估计

服务端临时分支 1 天（coder）；维护者实测约半天到一天：S1~S5 约 140 次连接，每次连同记录约 1 分钟，加上性能、换网和 50 次循环。

## 7. 判定标准（沿用 04 §3.6 的三条，基线改成现有 Porta 路径）

三条同时满足才进第四期（届时 03、04 里自写的局域网多候选扩展、UDP 出口证明等大部分不做）；任一不满足，就按 03、04 实施，等上游把 WebRTC 设为自建服务器默认开再看。

**(a) 至少一种场景里 WebRTC 能直连而现有路径不能，或者建连明显更快，或者换网不断。** 怎么量：
- 每个场景算 A 组和 B 组的直连率（赢家不是中继）。建议标准：B 组 ≥8/10 直连、A 组 ≤2/10 直连，算"能而不能"。重点看 S2。
- 选中的对经过 TUN（mihomo 代发）或经过用户自己的代理出口（srflx 是代理出口）的，单独列出，不算进上面的直连率：它们界面上显示直连，但不是要找的那条路，而且关 TUN 或换节点就断。
- "明显更快"：C 组的建连耗时中位数比 A 组快 1 秒以上（都按日志时间差算）。
- "换网不断"：S6 的中断时间。按代码预期约 8 秒整次重连（§2.5），大概率不满足，照实记录。

**(b) 50 次循环无崩溃、无卡死。** 怎么量：§6.7 主测 50 次、补测 20 次，崩溃 0、卡死 0；另外建议附加两条（维护者可调）：最后 10 次 WebRTC 仍然赢；第 50 次时的内存不比第 10 次多出 20% 以上。

**(c) 服务端改动（含防伪造）估计不超过一周。** 怎么量：§3.4 估 2~3 天；用临时分支的实际耗时校准。如果维护者要求的隐私处理（§5.2 第 1 项）或自建 STUN 把估计推过一周，照实记录。

另外，三条之外还有几件要维护者拍板的事，不拍板不能进第四期（§8 末尾）。

## 8. 待实测和待确认

**待实测**：
1. 开 TUN 时 host 候选平局，控制端实际多常选中经 TUN 或 Tailscale 的对（S1、S2 每次记选中对；Tailscale 开、关各看几次）。
2. Wintun 网卡是默认强主机模型，还是开了弱主机发送；维护者的 mihomo 对私网段是 DIRECT 还是排除。这决定 TUN 到物理局域网 IP 那一对是否经 mihomo 能通（§5.1）。
3. Windows 上 ICE socket 的 10054 静默失效（§4.3）。日志里看不到（错误被丢掉、不打日志），要看选中对和候选状态，或在评估构建的分支源码里临时加日志。
4. `RUST_LOG` 能否盖过 release 内置的过滤串、界面进程是否继承环境变量；依赖有没有打开 `release_max_level` 一类特性把 trace 编译掉。
5. 断开但有静态地址的网卡会不会产生 host 候选。
6. fake-ip 下的 IPv6 srflx；默认 Windows 防火墙是否放行进入 SYSTEM 服务的入站检查。
7. 半自动化 `--connect` 能否用于 50 次循环。

**待确认**：
1. Mac 的官方 1.5.x 能否在 porta-server 上正常注册（rustdesk-server #733 的同类问题），Mac 原版的日志目录。
2. Porta 基线有没有 #16605 的问题（自建环境下 `direct_failures>0` 后直连超时被压到 1 秒，SYN 丢一次就永久走中继）【旁证，https://github.com/rustdesk/rustdesk/issues/16605 ，修复是否在 `bd92623` 里没核对】。它会拉低 A 组的直连率，实测前先确认。
3. `enable-tcp-punch` 等三项的界面位置、本地配置文件名。
4. 上游官方服务器（闭源）在同一内网时怎么处理带 offer 的请求；Server Pro 的实现和防伪造做法（闭源）。
5. webrtc-rs 官方 0.17.x、0.21.x 有没有 Windows 网卡枚举的同类修复；如果没有，换哪个版本都得背 rustdesk 分支的补丁。

**要维护者拍板的方向问题**（评估通过后、进第四期前）：
1. Porta 客户端是否在构建时把 `enable-webrtc` 预置成开（LocalConfig，心跳改不到）。
2. 自建 STUN（porta-server 回 STUN Binding，连同 IPv6 探测路径），还是接受访问第三方 STUN。
3. 同一内网分支：带 offer 时一律改发 `PunchHole` 让 ICE 决定，还是扩展 `FetchLocalAddr`（§3.3）。
4. host 候选给谁：服务端只转给认证、授权的请求方，还是客户端白名单只发物理网卡（要改 `webrtc.rs`）。
5. 服务端强制中继时是否去掉 offer。
6. 服务端到被控端那段明文 UDP（含 ICE 凭据和全部候选）是接受，还是放进第三期签名、加密方案一起处理。
7. webrtc-rs 留在 0.13 分支、升 0.17.x 还是升 0.20+。

## 9. 实测结果与建议

2026-10-24 维护者定：不跑 §6 全矩阵，S1 之后只补测 S2、S3、S4，每个 B 组 3~5 次（理由：对端开 TUN 的场景已确定失败，再跑没有新信息；补测的三个场景是自研 ICE 也要依赖的前提，笔记 07 §11）。性能、换网、50 次循环不测。结论和建议在 §9.3。

### 9.1 2026-10-24 S1 冒烟：台式机（Porta 评估构建，开 TUN）→ Mac（官方 1.5.0，开 TUN）

- **信令通了**：临时分支的 porta-server 转发了 offer，Mac 经 `RelayResponse` 回 answer（Mac 判自己要走中继，answer 照样带回），两边互发候选（台式机 36 个、Mac 9 个）。
- **C 组（四个开关全开）**：中继在 2.5 秒时建好，ICE 刚进入 checking 就被关掉，连没连得通看不出来。
- **B 组（只开 WebRTC，中继压 10 秒）**：ICE 在 10 秒里一对都没通，最后走中继。用 `RUST_LOG=…,webrtc_ice=trace` 重启控制端再连一次，trace 日志显示：
  - 台式机所有物理网卡上的 socket（私网 IPv4、全局 IPv6）都向 Mac 的局域网地址发了检查，**一个回应都没收到**；约 1.5 秒后所有候选对按"重发次数用完"判失败。
  - 台式机唯一收到过包的 socket 是 Tailscale 网卡上的那个：Mac 从它的 tailnet 地址发来 3 个检查请求，台式机回了成功，但台式机这个 socket 发往 Mac 的检查全部在本机就报 10051（网络不可达）。
- **原因【实测】：Windows 的 10054 让 ICE socket 静默失效（§4.3、§8 待实测第 3 项）**。每个物理网卡 socket 的第一轮检查里，紧跟在"发往 Mac 局域网地址"之后，就是"发往 Mac 的 TUN 地址 198.18.0.1"（mihomo 的默认地址，台式机自己的 TUN 也是这个地址；IPv6 同理是 `fdfe:dcba:9876::1`）。这个包在本机立刻产生 ICMP 端口不可达，Windows 让这个没 connect 的 UDP socket 的下一次 `recv_from` 返回 WSAECONNRESET（10054）。rustdesk-org/webrtc@49c89bd8 的 `ice/src/agent/agent_internal.rs` `recv_loop` 遇到任何接收错误就返回，调用处是 `let _ = ai.recv_loop(...)`，错误被丢掉、不打日志；这个候选从此只发不收，几毫秒后 Mac 的回应到了也没人收。Tailscale 那个 socket 活下来，正是因为它的发送全在本机就失败、没有引来 ICMP。
  - 本机复现：在物理网卡地址上开一个 UDP socket，向 198.18.0.1 的任意端口发一个包，`recvfrom` 立即返回 10054；向局域网里一台机器的关闭端口发包，约 5 毫秒后返回 10054。
  - 影响：只要对端报了一个会在本机或局域网引来 ICMP 端口不可达的候选（对端开着同款 TUN、对端某个端口已关闭、对端的虚拟网卡地址和本机冲突），Windows 控制端对应的 socket 就废了。两端都开 mihomo TUN 时这个条件**必然成立**，因为两端的 TUN 地址一样。
  - 修法有两种，都要改 rustdesk-org 的 webrtc 分支：给每个候选 socket 设 `SIO_UDP_CONNRESET` 关掉这种报错；或者让 `recv_loop` 在 10054 时继续收。笔记 07 的自研方案已经把前者列为必做。
- **对照（同日，Mac 关掉 TUN，其余不变，B 组）：连上了，证实上面的判断。** answer 到达台式机后约 30 毫秒 ICE 就连通（从服务端把 offer 转到 Mac 新地址算起约 2.2 秒；日志 `56.9ms used to establish WebRTC connection`），选中的是 **IPv6 全局地址 host↔host**，和 UU 日志里局域网直连选中的类型一样（笔记 05）。这次 Mac 没有报 TUN 地址，台式机的物理网卡 socket 没被打死，检查回应都收到了。
  - 这次从点连接到 Mac 回 answer 花了约 10.8 秒，原因不在 ICE：Mac 关 TUN 后它的 UDP 映射变了，服务端一直往旧地址转 offer，等 Mac 重新注册（约 12 秒一轮）后第一个 offer 才到。计耗时要剔除这种情况。
  - 待查（没核实，不进结论）：这次台式机日志里另起了一个没收到 answer 的 ICE agent，它的"对端候选"是台式机自己的地址，可能是评估分支的候选路由或 Mac 旧的 UDP 映射被复用造成的。

### 9.2 2026-10-24 补测 S2、S3、S4（B 组，两端都开详细日志）

设备：台式机（家里，联通宽带，开 mihomo TUN）；老家笔记本（电信宽带，平时也开 mihomo TUN，TUN 地址和台式机完全相同，所以 S3、S4 期间**关掉笔记本的 TUN**，否则必然撞上 §9.1 的 10054；防火墙两台都是全关，"默认防火墙放不放行"这次测不了）；Mac（官方 1.5.0，TUN 关）。

| 场景 | 方向 | 次数 | 直连 | 选中的对 | answer 到达后连通用时 |
|---|---|---|---|---|---|
| S2 两端 UDP 走不同出口 | 台式机 → Mac | 3 | **3/3** | 私网 IPv4 host ↔ host（台式机以太网 ↔ Mac Wi-Fi） | 50~100 ms |
| S3 外网连回家 | 笔记本 → 台式机 | 4 | **4/4** | 笔记本私网 IPv4 host ↔ 台式机 srflx（家宽出口的公网 IPv4） | 0.86~0.91 s |
| S4 家里连外网 | 台式机 → 笔记本 | 3 | **2/3** | 全局 IPv6 host ↔ host | 0.34~0.40 s |

- **S2 正是现有路径做不到的场景**：服务端日志确认台式机的 UDP 注册来自代理出口、Mac 来自家宽，`same IP: false`，现有路径判不出同网、不会走局域网；ICE 靠交换 host 候选在局域网里直连。满足 §7 (a)"至少一种场景里 WebRTC 能直连而现有路径不能"。
- **S3 说明 IPv4 跨网打洞能成**：台式机开着 TUN，但它从物理网卡 socket 问 STUN 得到的 srflx 是家宽出口，不是代理出口；笔记本的检查打到这个映射上能通。即"TUN 下绑物理网卡地址的 UDP socket 发往公网仍从物理网卡出去"在这台机器上成立（笔记 07 §1 最大风险第 1 条、§11），至少对 IPv4 是这样。
- **S4 说明 CGNAT 家宽外网互连可以走 IPv6 host 对**：台式机物理网卡上的全局 IPv6 socket 和笔记本的全局 IPv6 直接互通，台式机开着 TUN 也不影响（IPv6 同样从物理网卡出去）。
- **S4 第 2 次失败，原因同 §9.1，只是发生在笔记本一侧【推测，日志强烈吻合】**：台式机收到了笔记本 IPv6 候选的成功回应并在 02:46:40 提名，之后又重发了约 70 次提名；笔记本那边，它的 IPv6 socket 最后一次收到包是 02:46:39.079，紧接着 02:46:39.194 向台式机的 TUN 地址 `fdfe:dcba:9876::1` 发了检查，此后再没收到任何包，自己的检查一直重发到全部判失败（92 对）。台式机这段时间收到了笔记本每对候选约 54 次重发的检查请求，说明笔记本只是"发得出、收不到"。笔记本收集 srflx 时还直接打出了一条 `os error 10054`。推断是发往对端 TUN 地址（ULA，老家路由器没有路由）引来 ICMPv6 不可达，笔记本的 socket 和 §9.1 一样被静默打死；第 1、3 次是提名先到、ICMP 后到，赢了这场竞速。
- 所有失败都能归到同一个机制：Windows 上 UDP socket 收到 ICMP 错误后接收报错，webrtc-ice 吞掉错误、socket 只发不收。没有观察到第二种失败原因。

### 9.3 结论与建议

**结论**：
1. ICE 这条思路（交换全部候选、逐对实测）在 Porta 的目标环境里成立：S2（同网但服务端判不出）、S3（IPv4 跨网打洞）、S4（CGNAT 家宽经 IPv6 互连）都能直连，选中的都是物理网卡上的地址对，连通在 0.1~0.9 秒。
2. 上游现成实现在 Windows 上不可靠：任何一端报出会引来 ICMP 错误的候选（对端开同款 TUN、ULA、对端关掉的端口），本端对应 socket 就静默失效。两端都开 mihomo TUN 时必然失败；即使一端不开，也是在和 ICMP 赛跑（S4 失败 1/3）。修它要改 rustdesk-org 的 webrtc 分支（`SIO_UDP_CONNRESET` 或 `recv_loop` 遇 10054 继续收）。
3. §7 三条：(a) 满足（S2）；(b) 50 次循环没测；(c) 满足（临时转发约 1 个 coder 人天）。笔记 06 读码列的其他不足（host 候选同优先级、不续选、只 UDP、SCTP 数据面、密码前交出全部候选）都还在。

**建议**：不采用上游 WebRTC 路径；按笔记 07 自研 ICE。实测给自研的几个前提都有了正面答案（物理网卡 socket 在 TUN 下仍走物理网卡、host 对在"同网判不出"时能通、IPv4 srflx 打洞和 IPv6 host 对跨网能通），同时把两件事从"建议"升为**必须**：每个候选 socket 关掉 ICMP 报错（`SIO_UDP_CONNRESET`），以及不收集、不发送 TUN/VPN 网卡的候选（对端是官方客户端时收到的 TUN 候选也无害，因为关了报错）。默认 Windows 防火墙下的行为没测到，留到自研 MVP 的验收里测。

## 参考

- 上游代码：`rustdesk@bd92623`（`src/client.rs`、`src/rendezvous_mediator.rs`、`src/common.rs`、`src/server.rs`、`src/client/io_loop.rs`、`src/port_forward.rs`、`src/hbbs_http/sync.rs`、`Cargo.toml`、`libs/base/src/config/keys.rs`、`flutter/lib/desktop/pages/desktop_setting_page.dart`）；提交 `ae6af2de`、`5b214418`、`f4808b71`、`4df7404a`、`f164c9a9`、`c0750fb5`、`7a367f7c`、`691830fe`、`692113c8`
- `hbb_common@ed07431`（`src/webrtc.rs`、`src/stream.rs`、`src/config.rs`、`src/lib.rs`、`protos/rendezvous.proto`、`Cargo.toml`）
- `rustdesk-org/webrtc@49c89bd8`（`ice/`、`util/src/ifaces/`、`sctp/`、`mdns/`、`webrtc/src/peer_connection/`）：https://github.com/rustdesk-org/webrtc/commits/49c89bd8d30e6e62e4c1a96cee38fdc11f79ef63
- Porta：`porta-client@6bb19b190`（`src/client.rs`、`src/porta_hooks.rs`、`src/common.rs`、`libs/porta/src/options.rs`、`libs/porta/src/lan.rs`、`PORTA.md`）；`porta-cardo@df76a0c`；`porta-server@d8403ad`（`src/rendezvous_server.rs`、`src/conn_tracker.rs`、`PORTA.md`）
- 上游 PR 和 issue：https://github.com/rustdesk/rustdesk/pull/15684 ；#16372、#16653、#16605、#16676、讨论 #16613；rustdesk-server #733；https://github.com/rxxozqfoe/rustdesk-server/pull/35
- 官方发布与文档：https://api.github.com/repos/rustdesk/rustdesk/releases/tags/1.5.0 ；https://github.com/rustdesk/rustdesk-server-pro/releases/tag/1.8.7 ；https://rustdesk.com/blog/rustdesk-1-5-0-webrtc-qos/ ；https://rustdesk.com/docs/en/self-host/client-configuration/advanced-settings/ ；https://github.com/rustdesk/rustdesk-server/commits/master
- webrtc-rs：https://webrtc.rs/blog/2026/01/31/webrtc-v0.17.0-feature-freeze-sansio-shift.html ；https://webrtc.rs/blog/2026/07/31/announcing-webrtc-v0.20.0.html ；https://github.com/webrtc-rs/webrtc/releases/tag/v0.17.2 ；issue #101、#772；PR #812、#813；https://crates.io/api/v1/crates/webrtc/versions
- RFC 8445（ICE）
- 笔记 04（TUN 下的局域网直连）、笔记 05（UU 远程的直连与打洞）；契约 `docs/第三期实施契约/04-UDP打洞与NAT探测.md` §2.5.8、§3.6，`README.md`
