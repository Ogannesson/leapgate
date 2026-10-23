第三期实施契约 · 第 4 块，总述和维护者的决定见 README.md。状态：P-1、P-3 已定（2026-10-23）；§2.5 的 UDP 出口证明是按维护者对 P-2 定的原则新拟的机制，待维护者确认。

# UDP 打洞的前置障碍、UDP 出口证明、NAT 类型判断、开 TUN 时的 IPv6 直连、WebRTC/ICE 评估

> 标注：【读码】读过现版源码；【实测：解密日志】笔记 05 引用的 UU 控制端日志里写着的；【推测】推断，没有实测。代码锚点对照 porta-client `6bb19b190`、porta-server `d8403ad`、porta-cardo 客户端线 `df76a0c` / 服务端线 `1a46681`、上游 `rustdesk@bd92623`、`rustdesk-server@873230e`。依据是 `docs/research/第三期/05-UU远程的直连与打洞.md`（下称"笔记 05"）。

> **这一块改了一条已拍板的决定。** `docs/architecture.md` §3.8 原定"UDP 打洞修不修，到第三期看中继回落率再定"。笔记 05 §5 发现开源服务端从不在 UDP 上回 `TestNatRequest`，控制端的 `udp_port` 恒为 0，UDP 打洞从来没跑过，现有回落率里 UDP 打洞是零，说明不了"修了值不值"。维护者 2026-10-23 已确认按"第三期先修前置障碍"来做（README §1.1 P-1）。

术语：
- **UDP 打洞**：两端同时往对方在 NAT 上的映射地址发 UDP 包，让两边路由器都留下放行记录，之后在这条 UDP 上跑 KCP（UDP 上的可靠传输）。上游已有这条路径，只是从没跑通。
- **TestNat**：控制端用一个 UDP socket 给服务端发 `TestNatRequest`，服务端回 `TestNatResponse{port}`，告诉它"我看到的来源端口"，也就是要交给被控端去打的那个映射端口。
- **反射/放大**：攻击者伪造来源地址给服务器发包，服务器把回包发给受害者（反射）；回包比请求大就是放大。上游 `rustdesk-server@109d9a2` 为此停掉了 UDP 上的 `PunchHoleSent`、`LocalAddr`。
- **nonce（防伪造随机数）**：服务端发给被控端的一次性随机字节，被控端经 UDP 回包时带上；伪造来源地址的人收不到它，也就伪造不了回包。
- **UDP 出口证明（token）**：服务端回 UDP 上的 TestNat 时附带的一小段数据，绑定服务端看到的控制端 UDP 来源地址，用只在服务端内存里的密钥做 MAC。控制端把它原样放进打洞请求，证明自己确实在这个 UDP 地址上收得到包（§2.5）。

## 1. 目标与范围

依据：笔记 05 §5 差距表第 4~6 行、§6 第 3、5、6、7 项；架构 §3.8"UDP 打洞的修法"。

UDP 打洞挡着四道独立的障碍【读码，现版逐条核对】：

| # | 障碍 | 位置 |
|---|---|---|
| 1 | 服务端不在 UDP 上回 `TestNatRequest`（只在 21116/TCP 的 `handle_tcp` L879 和 21115 的 `handle_listener2` 里回），控制端 `udp_port` 恒为 0 | `porta-server:src/rendezvous_server.rs` `handle_udp`（L557 起，没有这一支；上游同名函数一样） |
| 2 | 服务端丢弃 UDP 来的 `PunchHoleSent`，被控端 UDP 打洞正是用 UDP 发它；IPv6 地址夹在这个包里一起丢 | 同上 L722~724（`109d9a2` 改的两处之一） |
| 3 | 服务端不转发 `udp_port`，也从不置 `PunchHoleResponse.is_udp`（控制端见到 `is_udp` 才去连 UDP） | `handle_punch_hole_request` L1188 注释"udp_port … not forwarded"；`handle_hole_sent`（L963）不设 `is_udp`。上游服务端全仓没有 `is_udp`/`udp_port` 的写入 |
| 4 | Porta 客户端对自建服务器默认不开 UDP 打洞 | `porta-client:libs/porta/src/options.rs` `self_hosted_punch_default` |

和它绑在一起的四件事：
- **UDP 出口证明**（§2.5）：同网判定和 UDP 打洞目标都改用服务端看到的、控制端证明过的 UDP 地址，不再拿 TCP 来源 IP 去凑。这是维护者对 P-2 定的原则（不假定任何运行环境）落到协议上的做法，03 块的局域网候选靠它判同网。
- **NAT 类型判断**：被控端看到任一端是 `SYMMETRIC` 就对 IPv4 直接走中继（`src/rendezvous_mediator.rs` `handle_punch_hole` L1098~1101 的 `relay_v4`）。NAT 类型是用 TCP 测的（`src/common.rs` `test_nat_type_`，L706）。开 TUN 时 TCP 由本机代理终结、再由出站重新建连，来源端口由代理决定，很可能测成 `SYMMETRIC`，把修好的 UDP 打洞也拦掉（§4.1、§8 P-3）。
- **开 TUN 时的 IPv6 直连**（笔记 05 §6 第 3 项，本块认领）：默认开已在第二期做了；本块让 IPv6 打洞绑物理网卡的全局 IPv6，开不开 TUN 都按同一条规则走（§4.4）。不依赖服务端有 IPv6。
- **WebRTC/ICE**：只立一个有时间上限的评估项（§3.6），不实现。

上游 `src/client.rs` L663 的 `UDP_NAT_TEST_GRACE` 说的是另一件事：TUN 或网关透明代理在本地几毫秒内应答 TCP 握手，按 `rtt / 2` 算的等待窗口太短，上游已改成"TCP 建连短于 100 毫秒就等固定 400 毫秒"。它修的是"等得太短"，前提是服务端会在 UDP 上回包；开源服务端根本不回，所以在 Porta 部署里 `udp_port` 恒为 0 的原因是障碍 1【读码】。

不在本块：局域网 IPv6 候选和网卡分类（03 块；本块 §4.4 复用它的双地址族网卡枚举）；发起方 ID `porta_from_id`（02 块，只给路由第二级用，同网判定不用它）。

**依赖和实施顺序**（总述 README.md 的第 2 批）：依赖第 0 步的合并 proto 提交（两个 `porta_nonce` 和 §2.1 的四个 UDP 出口证明字段）、01 块的服务端心跳 handler（写 `Peer.porta_hb`、`features`）和客户端能力缓存（`porta::report::has_feature`），以及 03 块（第 1 批）扩展到 IPv6 的 `lan.rs` 网卡枚举（§4.4）。和 02 块并行，后合的一方变基；两块在 `rendezvous_server.rs`、`conn_tracker.rs`、`rendezvous_mediator.rs`、`client.rs` 里的改动不相邻（`client.rs` 里 02 块的挂钩在 L969 后、本块的 C-2 在 L971 后，中间隔两行上游代码，git 能自动合并）。不加迁移。

## 2. 协议与接口

### 2.1 proto（第 0 步的合并提交，两条 porta-cardo 线各一份，内容一致）

```proto
message TestNatRequest {
  ...
  // Porta: padding, so a reply carrying porta_udp_token is never larger than the request
  // (porta-server attaches the token only to a datagram of 64 bytes or more).
  bytes porta_pad = 1000;
}

message TestNatResponse {
  ...
  // Porta: proof of the UDP address porta-server saw this request come from (contract 04 §2.5).
  bytes porta_udp_token = 1000;
}

message PunchHoleRequest {
  ...
  // Porta: TestNatResponse.porta_udp_token, passed on unchanged.
  bytes porta_udp_token = 1001;
}

message PunchHole {
  ...
  // Porta: one-time nonce for a UDP punch; the controlled side echoes it in the
  // PunchHoleSent it sends over UDP. Set only together with udp_port.
  bytes porta_nonce = 1000;
  // Porta: the controlling side's UDP address from its token; the UDP punch aims here.
  // Set only together with porta_nonce.
  bytes porta_udp_addr = 1001;
}

message PunchHoleSent {
  ...
  // Porta: PunchHole.porta_nonce echoed back; porta-server takes a PunchHoleSent over UDP
  // only with a nonce it issued.
  bytes porta_nonce = 1000;
}
```

- 字段号按消息独立。`TestNatRequest` 现有字段只有 `serial = 1`，`TestNatResponse` 是 `port = 1`、`cu = 2`，两者从 1000 起；`PunchHoleRequest` 的 1000 已给 `porta_from_id`、`PunchHole` 的 1000 给了 `porta_nonce`，这两个新字段用 1001【读码：porta-cardo 客户端线 `df76a0c` `protos/rendezvous.proto`】。原版客户端、原版 hbbs 遇到它们直接忽略。
- 文件头的号段注释（Porta 占 1000~1999）和 `PunchHoleRequest.porta_from_id = 1000` 在同一个提交里，见 README.md。

### 2.2 能力宣告和"被控端会回带 nonce"的判断

- **服务端 → 客户端**：本块合入后，Porta 心跳响应的 `features` 一直带 `"udp-punch"`（01 块 §3.6 接入点表）。不加配置开关：不想要这项功能就不合入。
- **客户端读法**：控制端的两处开关（§4.2 默认值、§4.3 H-c）都在界面进程里，经 `porta::report::has_feature("udp-punch")` 读能力缓存。缓存由服务进程写进 Config 的 options（键 `porta-api-caps`，值是"API 根地址 + features"），经现有的 Options 同步到界面进程；`has_feature` 自己按上游 `get_api_server` 算当前根地址再比较，不依赖进程内 static（01 块 §2.5、§4.4）。
- **服务端判断被控端支不支持**：读 01 块写的内存字段 `Peer.porta_hb: Option<PortaHb { at, porta_ver }>`（Porta 心跳验签通过后写）。`at` 在 180 秒内，且 `porta_ver` 不低于 `udp_punch::MIN_PORTA_VER`（对应 `libs/porta` 0.3.1：本块客户端合入时把版本号前移到 0.3.1，01 块 §2.3 的版本号规则），才认为它会回带 nonce。本块不再加自己的字段或状态。180 秒按 01 块的心跳节奏取：空闲 15 秒一次，失败退避到 60 秒。
- 和 01 块同一次发布时版本条件恒真，但保留：防客户端降级回 0.3.0（有 01 块、没有本块）。心跳请求不加新键。

### 2.3 UDP 上的消息与回包

| 来包（UDP） | 服务端做什么 | 回包 |
|---|---|---|
| `TestNatRequest` | 过全局令牌桶，回来源端口；数据报不短于 64 字节时再附 token（§2.5.2） | `TestNatResponse{port}`，**不带** `cu`（`ConfigUpdate` 带服务器列表，会放大）。原版客户端的请求是空消息，整个数据报 3 字节，回包最多 7 字节；加上 IP/UDP 头 28 字节约 31 对 35 字节，约 1.13 倍；以太网最小帧 64 字节下两者一样大。带 token 的回包最长 49 字节，只回给不短于 64 字节的请求 |
| `PunchHoleSent`，带有效 `porta_nonce` | 按 nonce 找到控制端的 TCP 连接，发 `PunchHoleResponse{is_udp: true}` | **UDP 上不回任何包**，只往已存在的 TCP 连接写 |
| `PunchHoleSent`，不带或带无效 nonce | 丢弃，不回包、不打日志（每个包都能触发） | 无 |
| `LocalAddr` | 照旧丢弃 | 无 |

`109d9a2` 之前的 UDP `PunchHoleSent` 是把回包经 UDP 发往包里自带的 `socket_addr`（攻击者可以随便填），那才是反射源。改成"只写进控制端已有的 TCP 连接"后不存在反射，nonce 只用来防伪造。本块没有 HTTP 接口。

### 2.4 控制端的 TCP 和 UDP 从不同出口出去时

例如路由器透明代理只代理 TCP、控制端在家里往外连。上游服务端把控制端的"TCP 来源 IP"和"UDP 映射端口"拼成一个地址交给被控端（`PunchHole.socket_addr` 的 IP 加 `udp_port`），两者出口不同时被控端打到代理出口上，必然失败、回落中继【读码】。被控端那一侧没有这个问题（它的地址取自 UDP 包本身）。同一个根因也让同网判定失真：服务端拿控制端的 TCP 来源去比被控端的 UDP 注册地址。

本块用 §2.5 的 UDP 出口证明把两件事一起解决，不要求用户配置任何代理规则。

草稿里曾考虑让控制端在打洞请求里自报完整的 UDP 观测地址、服务端照转给被控端，因为反射风险没采用：被控端打洞包的目的 IP 会变成控制端自报的值，恶意控制端可以填任意第三方的地址，让知道 ID 的大量被控端往那里发打洞包和 KCP 握手。§2.5 的 token 由服务端签发、绑定服务端自己看到的地址，控制端只能原样转交，这个风险不存在（§2.5.7）。

### 2.5 UDP 出口证明

#### 2.5.1 为什么要它

维护者对 P-2 定的原则（README §1.1）：规则必须对所有运行环境都成立，要么不管开不开 TUN 都生效，要么能判清楚到底有没有开 TUN；不接受"要用户配环境规则"，也不接受"按设备主人、地址簿授权"。

同网判定失真的根因是服务端拿两种协议的观测去比：发起方打洞请求的 TCP 来源 IP，对被控端 UDP 注册的来源 IP。透明代理只代理 TCP 时，前者是代理出口、后者是家宽，判成"不同网"。改法是比同一种协议的观测：发起方 UDP NAT 测试的来源 IP，对被控端 UDP 注册的来源 IP，并且让发起方证明它确实在那个 UDP 地址上收得到包（伪造源地址的人收不到）。这条规则只用服务端看得见的事实，本机开没开 TUN、路由器怎么代理，算法都一样。

UDP NAT 测试本来就在打洞请求之前做（为了拿 `udp_port`），token 跟着它的回包回来，不多一次往返。

#### 2.5.2 token 的格式和放大比

服务端回 UDP 上的 `TestNatResponse` 时，在 `porta_udp_token` 里放：

| 段 | 字节 | 内容 |
|---|---|---|
| 版本 | 1 | 固定为 1 |
| 时间戳 | 4 | 签发时刻的 unix 秒，小端 `u32` |
| 观测地址 | 7~18 | 服务端看到的这条 UDP 数据报的来源地址，先 `try_into_v4` 再 `AddrMangle::encode`（IPv4 最长 11 字节，IPv6 固定 18 字节） |
| MAC | 16 | libsodium `crypto_auth`（HMAC-SHA512-256）对前三段算出的 32 字节，取前 16 字节 |

- 总长 28~39 字节。观测地址的长度 = 总长 − 21，不另记长度。
- **无状态**：密钥是进程启动时随机生成、只在内存里的一把（`sodiumoxide::crypto::auth::gen_key()`），不落盘，也不另开表。porta-server 重启后旧 token 全部失效，只影响那一刻正在建立的几次连接（退回原有判定）。
- **有效期 30 秒**：时间戳不晚于现在，也不早于 30 秒前。控制端一次连接最多发三轮打洞请求，分别在第 0、3、9 秒发出（`client.rs` L979~989），token 在第一轮之前签发，第三轮发出时一般只过了约 10 秒；连会合服务器的 TCP 建连再慢（最多等 `CONNECT_TIMEOUT` 18 秒），第三轮也在约 28 秒内。签发和校验都在同一个进程里，不涉及两边的时钟。
- token 不加密：里面只有控制端自己的公网 UDP 地址和签发时间，控制端本来就知道。
- **放大比**：Porta 控制端在 `TestNatRequest.porta_pad` 里填 60 个零字节，整个数据报 66 字节（外层 `test_nat_request = 20` 的标签 2 字节、长度 1 字节；`porta_pad` 的标签 2 字节、长度 1 字节）。服务端**只在收到的数据报不短于 64 字节**（`MIN_PADDED_TEST_NAT`）时附 token，否则照 §2.3 只回端口，原版客户端 3 字节的请求不受影响。带 token 的回包最长 49 字节：外层 `test_nat_response = 21` 的标签 2 字节、长度 1 字节，`port` 最多 4 字节，`porta_udp_token` 的标签 2 字节、长度 1 字节、内容最多 39 字节。回包 ≤ 49 < 64 ≤ 请求，放大比小于 1（算上 IPv4/UDP 头约 77 对 92 字节）。

#### 2.5.3 控制端怎么带上

控制端把回包里的 token 原样放进 `PunchHoleRequest.porta_udp_token`。token 只在控制端做了 UDP NAT 测试时才有，所以它依赖：

- P-1 的"Porta 控制端对自建服务器默认开 UDP 打洞"（§4.2，服务端宣告 `udp-punch` 时）；
- 登录用户也等 UDP 测试的挂钩 H-c（§4.3）。上游里登录用户（有令牌、配了 Key）不等 UDP 测试就发打洞请求，没有 H-c，token 多半赶不上。**H-c 必须保留**。

客户端挂钩见 §4.3 的 C-1（带填充的测试）、C-2（打洞请求带 token）。

#### 2.5.4 同网判定

服务端验 token 的版本、MAC、时效，解出地址 `udp_addr`：

```
same_intranet = 原有 TCP 比较
             || (token 有效 && !ws && !forced_relay
                 && try_into_v4(udp_addr).ip() == try_into_v4(B 的 UDP 注册地址).ip())
```

- 原有 TCP 那一路保持上游行为不动（同网时照旧发 `FetchLocalAddr`，不看强制中继；`server/PORTA.md` §3 要求原版会合逻辑里的地址处理保持原样）。
- `!forced_relay`：强制中继时新加的这一路不生效，免得它绕过强制中继。`!ws`：和现有判定一样，WebSocket 来的请求不走局域网路径。
- B 的 UDP 注册地址就是 `handle_punch_hole_request` 里已经读出的 `peer_addr`：`Peer.socket_addr` 只由 UDP 的 `RegisterPeer`/`RegisterPk` 写，TCP 上的 `RegisterPk` 回 `NOT_SUPPORT`；走到这里时 B 一定在 30 秒内注册过，否则前面已经回了 `OFFLINE`【读码：`rendezvous_server.rs` L1126~1140、L894~901】。
- 比较前两边都 `try_into_v4`（`server/PORTA.md` §3"新代码比较前先规范化"）；地址族不同时判否，不做跨地址族比较。
- 不用 `porta_from_id`，不查令牌、设备主人或地址簿。
- `FetchLocalAddr.socket_addr` 仍是 A 的 TCP 来源地址：服务端靠它在 `tcp_punch` 里找回 A 的那条 TCP 连接（`handle_local_addr` → `send_to_tcp`）。

统计口径（不新增 `conn_attempt` 列）：`signal = 'fetch_local_addr' and a_ip <> b_ip` 基本就是新规则判出来的（原有规则要求两者相等；例外是服务端配了 `mask`、两端都在服务端所在内网）。其中 `outcome like 'relay%'` 是判了同网但最后走了中继；`outcome = 'direct_lan'` 只说明被控端回了局域网地址、匹配上的回落请求为 0。控制端 TCP 走多出口代理时，回落的 `RequestRelay` 可能匹配不上、另记成 `relay_only` 行，原行仍是 `direct_lan`，所以"判对且连上"还要排除同一 `b_id`、同一时间窗里的 `relay_only` 行【读码：`migrations/0001_init.sql` `conn_attempt`、`src/conn_tracker.rs` `outcome`】。

#### 2.5.5 UDP 打洞的目标

上游被控端在 `handle_punch_hole` 里用 `PunchHole.socket_addr` 的 IP 加 `udp_port` 作 UDP 打洞目标（L1152~1153），用 `socket_addr` 本身作 TCP 打洞目标（L1172~1180）【读码】。

token 有效、服务端又要转发 `udp_port`（§3.2 第 4 条的 `udp_ok` 成立、发了 nonce）时，服务端在 `PunchHole.porta_udp_addr` 里放 `AddrMangle::encode(udp_addr)`；Porta 被控端的挂钩 C-3（§4.3）在 L1153 之后用它整个替换 UDP 打洞目标，IP 和端口都用服务端的观测值。这同时解决了 §2.4。

**`socket_addr` 不改**，仍是 A 的 TCP 来源地址。被控端会把它原样带回服务端：`PunchHoleSent.socket_addr`（L1143），以及走中继时 `create_relay` 发出的 `RelayResponse.socket_addr`（L1128）。服务端拿它在 `tcp_punch` 里找 A 的 TCP 连接（`handle_hole_sent`，`RelayResponse` 分支 L832~871 的 `send_to_tcp_sync`）。如果把它换成 UDP 地址，被控端走中继时（例如它本地配了代理，`relay_v4` 为真）A 就收不到 `RelayResponse`。所以 UDP 目标走新字段，`conn_tracker` 用 TCP IP 匹配回落请求这条也就不受影响。

- `udp_port` 照旧填 `ph.udp_port`。它和 token 来自同一个回包（§4.1 的 token 按 UDP socket 交接），端口相同；被控端以 `porta_udp_addr` 为准。
- 只有会回带 nonce 的 Porta 被控端（`libs/porta` ≥ 0.3.1）才收到 `udp_port`，这些版本都有 C-3，不需要另加版本判断。
- TCP 出口被代理时 TCP 打洞本来就打不通（被控端打到代理出口上）。被控端收到 `udp_port` 后只做 UDP 打洞、不做 TCP 打洞（上游 `punch_tcp` 要求 `udp_port <= 0`，L1103），这条不变。
- TCP 和 UDP 从同一个出口出去时，结果和以前一样，只是端口改用服务端的观测值。

#### 2.5.6 时序和开关

- 原版控制端的请求不带填充，拿不到 token，同网判定照旧只比 TCP。
- Porta 控制端只在服务端宣告 `udp-punch` 时才做带填充的测试（C-1）；连原版 hbbs、或没有本块的 porta-server 时调上游的测试函数，行为不变。
- 控制端便携运行（服务进程没跑）时能力缓存为空，UDP 打洞按上游默认关，不做 UDP 测试也就没有 token，退回原有判定。
- 用户手动打开 TCP 打洞时，上游会再发一条只做 TCP 打洞的后备请求，它不做 UDP 测试、不带 token，按原有 TCP 比较判定（§9 第 13 条）。默认配置下不发后备请求：自建服务器上 TCP 打洞默认关、IPv6 打洞默认开，`tcp_punch_allowed()` 为假【读码：`client.rs` `tcp_punch_allowed` L361~366，`_start` L556~562】。

#### 2.5.7 安全分析

- **伪造 UDP 源地址拿不到 token**：回包发往被伪造的地址。要拿到一个装着 B 的公网 IP 的 token，得真在 B 的公网 IP 上收得到包，也就是和 B 在同一个 NAT 后面，这在原有 TCP 判定下本来就算同网。
- **路径上的攻击者**能截下 token，但他本来就能看到、改动明文的会合流量（包括被控端回给 A 的局域网地址），不是新增的面。
- **重放**：token 在 30 秒内可以被同一个发起方反复用（连同一台或别的被控端），后果只是又一次按它真实的 UDP 地址做同网判定、定 UDP 打洞目标，可以接受。拿到别人的 token 要么靠对方给，要么得在路径上，同上一条。
- **反射**：被控端打洞包的目的地址，是服务端 30 秒内亲眼看到、并且对方收到了回包的 UDP 地址，指不到第三方。
- **放大**：带 token 的回包只回给不短于 64 字节的请求，最长 49 字节（§2.5.2），放大比小于 1；照旧过 TestNat 的全局令牌桶（§3.2）。
- **伪造 token**：要有服务端内存里的密钥；MAC 截到 16 字节（128 位），猜不出来。
- **强制中继不被绕过**：新加的同网判定要求 `!forced_relay`；UDP 打洞在强制中继时本来就不转发 `udp_port`，也就没有 `porta_udp_addr`。
- 不加每来源的表：token 无状态，没有可以灌满的东西。nonce 表已经有按来源的限额（§3.1），不再造同类的面。

#### 2.5.8 剩余缺口

服务端判定只能比它看得见的东西。发起方和被控端到服务端的 UDP 都被代理、而且两边出口不同时（例如两台机器各自走不同的代理节点），服务端看到的两个 UDP IP 不同，仍然判不出同一局域网。这时退到 IPv6 打洞、UDP 打洞和中继，不比现在差，但局域网候选用不上。两边经同一个出口时判得出，和原有 TCP 判定同理。

补这个缺口的是 §3.6 的 WebRTC/ICE 评估项：客户端自己对候选逐对实测，不靠服务端判同网。

#### 2.5.9 不做

- 把连服务端的 socket 绑到物理网卡：`client/PORTA.md` §3.7 已写不做（fake-ip 下域名解析出假地址，绑物理网卡后连不上），它也违反"不假定运行环境"。
- 按发起方 ID 比 UDP 注册 IP、按设备主人或地址簿权限放行（原 03 块第 1 项，见 03 §2.1"已排除的方案"）。
- 要求用户配置代理规则。

## 3. 服务端改动（porta-server）

### 3.1 新文件 `src/udp_punch.rs`

模块内 `static`（`server/PORTA.md` §3"模块自己的小状态放模块内 static"），`std::sync::Mutex`，锁内不 await：

```rust
const NONCE_LEN: usize = 8;                            // 64 位，单次有效
const NONCE_TTL: Duration = Duration::from_secs(10);   // 控制端每轮最多等 3/6/9 秒，被控端毫秒级回
const MAX_PENDING: usize = 4096;
const MAX_PENDING_PER_IP: usize = 8;                   // 同一控制端 TCP 来源 IP 最多占的待用条数
const HB_FRESH: Duration = Duration::from_secs(180);   // 判断条件里的常量，不是另一份状态（§2.2）
pub const MIN_PORTA_VER: u32 = 3010;                   // get_version_number("0.3.1")

struct Pending { a_addr: SocketAddr, b_id: String, at: Instant }
static PENDING: Lazy<Mutex<HashMap<[u8; NONCE_LEN], Pending>>>;

/// 被控端会不会回带 nonce：最近一次验签心跳在 HB_FRESH 内，且版本够新（§2.2）。纯函数。
pub fn echoes_nonce(hb: Option<&PortaHb>, now: Instant) -> bool;
/// 发一个 nonce；同一来源 IP 已有 8 条待用，或表满且清掉过期的仍满时，返回 None
/// （这次不转发 udp_port，退回 TCP 打洞）。
pub fn issue(a_addr: SocketAddr, b_id: &str) -> Option<Vec<u8>>;
/// 一次性取出：nonce 存在、未过期、b_id 相同才返回控制端地址；取到即删，重复的副本自然作废。
pub fn redeem(nonce: &[u8], b_id: &str) -> Option<SocketAddr>;

// UDP 出口证明（§2.5），无状态
const TOKEN_VER: u8 = 1;
const TOKEN_TTL_SECS: u64 = 30;
const TOKEN_MAC_LEN: usize = 16;
pub const MIN_PADDED_TEST_NAT: usize = 64;             // 不短于这么长的 UDP TestNat 才附 token
static TOKEN_KEY: Lazy<auth::Key>;                       // auth::gen_key()，进程内随机、只在内存

/// 当前 unix 秒（SystemTime::now()）。
pub fn now_secs() -> u64;
/// 给来自 `addr` 的带填充 TestNat 签一个 token：版本 ‖ now（u32 小端）‖ AddrMangle(addr) ‖ MAC 前 16 字节。
pub fn seal(addr: SocketAddr, now: u64) -> Vec<u8>;
/// 本进程 30 秒内签发、MAC 对得上的 token 里的地址；其他一律 None。
pub fn open(token: &[u8], now: u64) -> Option<SocketAddr>;
```

- `MIN_PORTA_VER` 照 hbb_common `get_version_number` 的算法写死：每段乘 1000 累加，末段再乘 10，"0.3.1" 得 3010，"0.3.0" 得 3000。§6.1 的 `echoes_nonce` 测试直接用这个常量。
- **按来源限条数**：`issue()` 发放前在锁内遍历一次待用表（最多 4096 条），统计未过期、且控制端 TCP 来源 IP（`a_addr.ip()`，规范化成 IPv4）相同的条数，达到 8 条就返回 `None`：这一次不发随机数、不转发 `udp_port`，退回 TCP 打洞。不加新的数据结构。TCP 来源 IP 伪造不了，8 条够一户人家同时发起两三次连接（每次连接 10 秒内最多约 3 轮打洞请求）。
- 随机数用已有依赖 `sodiumoxide::randombytes`，不加依赖。
- 内存：每条约 0.3 KB（id 截到 253 字节），4096 条约 1.2 MB。只有带对 key、目标在线、目标支持的打洞请求才建条目。
- 不验 UDP 来源 IP 是否等于被控端注册 IP：被控端打洞用的是新开的 UDP socket（`new_direct_udp_for`），多出口或开 TUN 时来源 IP 可能和注册时不同，nonce 已经够防伪造。
- `open` 先看长度（28~39 字节，不合就直接返回 `None`，原版客户端的空 token 不用算 MAC），再用常数时间比较 MAC 的前 16 字节（`sodiumoxide::utils::memcmp`；截短的 MAC 不能用 `auth::verify`），再看版本和时效，最后解码地址；端口为 0 或未指定地址也算无效。`auth` 是 `sodiumoxide::crypto::auth`，已有依赖。
- `seal`、`open` 的时间由调用方传入，密钥取模块内 static，单测不用等时间流逝。HMAC 对几十字节的输入约 1 微秒，`seal` 在令牌桶之后才调用（每秒最多 1000 次），`open` 在连接任务里调用，都不构成负担。

### 3.2 `src/rendezvous_server.rs`

1. **`handle_udp` 新增 `TestNatRequest` 分支**（插在 L759 `_ => {}` 之前，约 14 行）：
   ```rust
   Some(rendezvous_message::Union::TestNatRequest(_)) => {
       // porta: answer the UDP NAT test, port only (no ConfigUpdate: it would amplify); the
       // egress token only for a request padded to at least the reply's size (contract 04 §2.5)
       if self.nat_tests.take() {
           let porta_udp_token = if bytes.len() >= udp_punch::MIN_PADDED_TEST_NAT {
               udp_punch::seal(try_into_v4(addr), udp_punch::now_secs())
           } else {
               Default::default()
           };
           let mut msg_out = RendezvousMessage::new();
           msg_out.set_test_nat_response(TestNatResponse { port: addr.port() as _, porta_udp_token, ..Default::default() });
           socket.send(&msg_out, addr).await?;
       }
   }
   ```
   - `bytes` 是 `handle_udp` 的参数（L559），就是这一个数据报的原始字节，长度直接可用。
   - 令牌桶：全局每秒 1000 个、突发 1000 个。最坏反射流量约 1000 × 35 字节 ≈ 35 KB/s，倍数 1.13。不做每来源计数（多一张表）；被灌满时正常用户拿不到 UDP 端口，退回 TCP 打洞，和今天一样。超出时每分钟最多一条 warn（`throttled_log!`）。
   - 把第一期的 `LookupBudget`（L115 起，Porta 自己加的，不是上游）改成带 `rate`、`burst` 两个字段的通用令牌桶，`lookups` 和新字段 `nat_tests` 各建一个。
   - 不计入 `IP_BLOCKER`（那是 `RegisterPk` 的每来源限额），两者互不占用。
2. **`handle_udp` 的 `PunchHoleSent` 分支**（L722~724，替换注释为约 8 行）：
   ```rust
   Some(rendezvous_message::Union::PunchHoleSent(mut phs)) => {
       // porta: only with the nonce this server put in PunchHole (UDP punch)
       if let Some(a_addr) = crate::udp_punch::redeem(&phs.porta_nonce, &phs.id) {
           phs.socket_addr = AddrMangle::encode(a_addr).into();
           if phs.socket_addr_v6.len() > MAX_MANGLED_ADDR { phs.socket_addr_v6 = Default::default(); }
           allow_err!(self.handle_hole_sent(phs, addr, true).await);
       }
   }
   ```
   用表里记的控制端地址覆盖包里的 `socket_addr`，不信任包里的值；H2 的匹配键因此和 TCP 路径一样是控制端的 TCP 地址。`LocalAddr` 分支不动。
3. **`handle_hole_sent`**（L963 起）：第三个参数 `socket: Option<&mut FramedSocket>` 改成 `via_udp: bool`；`PunchHoleResponse` 里加 `is_udp: via_udp`；末尾"`Some(socket)` 就经 UDP 发往 `addr_a`"的分支删掉，一律 `self.send_to_tcp(msg_out, addr_a)`（它 spawn 发送，不阻塞 `io_loop`）；日志标签按 `via_udp`；H2 的 `ReplyKind` 按 `via_udp` 取 `PunchHoleSentUdp` 或 `PunchHoleSent`。`handle_tcp` L874 的调用改传 `false`。被删的分支在 `109d9a2` 之后已无人调用。`PunchHoleResponse.socket_addr` 照旧是 `encode(addr)`，UDP 路径下 `addr` 就是被控端打洞 socket 的映射地址，正是控制端要打的目标。
4. **`handle_punch_hole_request` 的增量**（只写本块的；02 块接 `a_id`）：
   - L1126~1129 读 `peer` 的块里多算一个值：`udp_punch::echoes_nonce(r.porta_hb.as_ref(), Instant::now())`。
   - **同网判定**（§2.5.4）：在 `let same_intranet: bool = !ws && (…);`（L1176~1183）之后、`let socket_addr = AddrMangle::encode(addr).into();`（L1184）之前加：
     ```rust
     // porta: A's UDP egress, proven by its token, against B's UDP registration (contract 04 §2.5)
     let udp_addr = udp_punch::open(&ph.porta_udp_token, udp_punch::now_secs());
     let same_intranet = same_intranet
         || (!ws
             && !forced_relay
             && udp_addr.is_some_and(|u| try_into_v4(u).ip() == try_into_v4(peer_addr).ip()));
     ```
     `forced_relay` 是 L1165 现成的局部变量，在作用域里；`ph.id` 已被移走，`ph.porta_udp_token` 仍可借用（部分移动）。token 为空时 `open` 只看一眼长度就返回。
   - 在 `else`（发 `PunchHole`）分支、L1211 `msg_out.set_punch_hole(...)` 之前：
     ```rust
     // porta: forward A's UDP NAT port only to a B that echoes the nonce
     let udp_ok = !forced_relay && !ph.force_relay && !ws
         && (1..=65535).contains(&ph.udp_port) && echoes;
     let porta_nonce = if udp_ok { udp_punch::issue(addr, &id) } else { None };
     // porta: aim the UDP punch at the address A's token proves (contract 04 §2.5.5)
     let porta_udp_addr = udp_addr.filter(|_| porta_nonce.is_some()).map(|u| AddrMangle::encode(u).into());
     ```
     `PunchHole` 字面量里加 `udp_port: if porta_nonce.is_some() { ph.udp_port } else { 0 }`、`porta_nonce: porta_nonce.unwrap_or_default()`、`porta_udp_addr: porta_udp_addr.unwrap_or_default()` 三行；`socket_addr` 不动（§2.5.5）。本条合计约 17 行。L1188 的注释改成"WebRTC offer not forwarded; udp_port only with a nonce (PORTA.md §6.11)"。
   - **强制中继**（`forced_relay`，L1165）、控制端自己要求中继（`ph.force_relay`）、走 WebSocket：都不转发 `udp_port`、不发 nonce，和第一期对 IPv6 的处理一致。
   - `FetchLocalAddr`（同网）分支不转发 `udp_port`：局域网路径不用 UDP。
   - `track.udp_port` 第一期已记控制端报的端口（`conn_attempt.a_udp_port`），不用改。

### 3.3 `src/conn_tracker.rs`

- `ReplyKind` 加 `PunchHoleSentUdp`，`Answer` 加对应项，`reply` 列写 `'punch_hole_sent_udp'`。
- `outcome` 加 `direct_udp`、`direct_udp_or_v6`（判定规则同 L304~305 的 `direct_tcp_or_v6`/`direct_tcp`，只是回包来自 UDP；L268 直连窗口的匹配也加上新的 `Answer`）。`reply`、`outcome` 都是文本列，**不需要迁移**；`migrations/0001_init.sql` 里列出取值的注释也不改（sqlx 按字节算校验和），取值全集以 `server/PORTA.md` §8 为准。
- 统计查询（L860~861）分母加上这两个值；`stats` 输出分项列出。上线后能直接看到 UDP 打洞的占比，这是本块的主要目的之一。

### 3.4 和 01 块的接入点

- 心跳 handler 的 `features` 加 `"udp-punch"`（一个常量）。
- `Peer.porta_hb` 由 01 块写，本块只读（§3.2 第 4 条）。

### 3.5 要同步改的文档

`server/PORTA.md`：
- §1"不做（第一期）"删掉"转发 `udp_port`（UDP 打洞）"，写明第三期起做（见 §6 第 11 条）。
- §2 文件表加 `src/udp_punch.rs`（nonce 表、"会不会回带 nonce"的判断、UDP 出口证明的签发和校验）。
- §3 模块 static 列表补 `udp_punch` 的 nonce 表和 token 密钥；"原版会合逻辑里已有的地址处理保持原样（`same_intranet` …）"那句后补半句：Porta 新加的那路比较按新代码规范化。
- §6 第 2 条："不转发 `udp_port`"改为"只对会回带 nonce 的被控端转发，见第 11 条"。
- §6 第 8 条资源上限补 nonce 表 4096 条（每个控制端来源 IP 最多 8 条）、TestNat 令牌桶 1000/s；注明 token 无状态、不占表。
- §6 第 9 条（局域网候选）补一句：同网判定除了原有 TCP 比较，还有第 10 条的 UDP 出口证明。
- §6 新增**第 10 条"UDP 出口证明"**：§2.5 的格式和取值（版本 1、unix 秒、AddrMangle 地址、MAC 16 字节；30 秒；密钥只在内存；64 字节门槛、回包最长 49 字节）、同网判定的条件（`!ws`、`!forced_relay`、规范化后比 IP）、`porta_udp_addr` 的填法和 `socket_addr` 为什么不改、统计口径、剩余缺口。
- §6 新增**第 11 条"UDP 打洞"**：§2.2~§2.3、§3.1~§3.2 的全部取值（nonce 8 字节、10 秒、4096 条、每来源 8 条；`porta_hb` 180 秒加版本下限；TestNat 令牌桶 1000/s、回包不带 `cu`；UDP 上永不回 `PunchHoleSent`/`LocalAddr` 的回包）。
- §8 `outcome` 全集和回落率公式加 `direct_udp`、`direct_udp_or_v6`；`reply` 加 `punch_hole_sent_udp`。
- §14 `stats` 的说明补"分项列出 `direct_udp`、`direct_udp_or_v6`"。

`docs/architecture.md`（P-1 已定"进"）：

- §3.8"决定"和"UDP 打洞修不修看数据"：改为"第三期先修前置障碍（服务端在 UDP 上回 TestNat、nonce 校验的 UDP `PunchHoleSent`、转发 `udp_port`/`is_udp`），再看回落率决定要不要做更重的打洞手段"，补一句"第一期以来的数据里 UDP 打洞为零"；再补一句"同网判定和 UDP 打洞目标比同一种协议的观测：控制端用服务端签发的 token 证明自己在哪个 UDP 地址上收得到包（UDP 出口证明），不要求用户配置代理规则"。
- §5 第三期第二条："UDP 打洞：修前置障碍（加防伪造随机数和 UDP 出口证明，§3.8）"。
- §6 第 5 条（随机数方案没细化）：改为"随机数方案和 UDP 出口证明见第三期实施契约第 4 块"。
- §7 第 7 条：补"2026-10-23 改定：第三期先修 UDP 打洞的前置障碍"。

### 3.6 WebRTC/ICE 评估项（笔记 05 §6 第 7 项，按推荐放进第三期，不是实现）

**为什么值得评估**：UU 两次局域网会话的直连全部来自上游 libwebrtc 的标准 ICE 能力（多网卡 host 候选、IPv6 host 对、对端反射候选、持续收集），网易的增强打洞一项都没起作用【实测：解密日志，笔记 05 §3.2、§6 第 7 项】。上游 RustDesk 已经带了一条 WebRTC 路径。**如果评估通过，第四期可以用 ICE 替代 Porta 自写的局域网多候选和 IPv6 打洞**（03 块和本块 §4.4 的那部分），而不只是补充。它也是补 §2.5.8 剩余缺口的办法：ICE 由客户端自己对候选逐对实测，不靠服务端判同网，两边的 UDP 被不同代理出口带走时，局域网那一对照样能通。

- **要回答的问题**：上游现成的 WebRTC 路径能不能直接拿来，替代或补充 KCP-UDP 打洞、局域网多候选和 IPv6 打洞；能不能补上 UDP 出口证明判不出同网的那种情况（§2.5.8）。
- **评估内容**：
  1. 成熟度：`client/libs/hbb_common/src/webrtc.rs`（webrtc-rs 加 rustdesk-org 补丁分支）、客户端的 offer/answer/ICE 桥接（`src/client.rs` `should_create_webrtc_offerer`、`spawn_webrtc_ice_bridge`；`src/rendezvous_mediator.rs` `spawn_webrtc_answerer`）。看上游这条路径的提交历史和时长、issue 里的崩溃和卡死、官方服务器是否默认开、为什么默认关。
  2. porta-server 要改什么：转发 `PunchHoleRequest.webrtc_sdp_offer` → `PunchHole`、`PunchHoleSent.webrtc_sdp_answer` → `PunchHoleResponse`；双向转发 `IceCandidate`。要查清的难点：控制端收到 `PunchHoleResponse` 后还要用同一条 TCP 连接收后续候选，而现在 `send_to_tcp`（L1264）发完就把这条连接从 `tcp_punch` 里取走；被控端经 UDP 发来的 `IceCandidate` 怎么防伪造（`session_key` 能不能当凭证）；带 offer 的 `PunchHole` 经 UDP 发给被控端的大小。
  3. STUN/TURN：webrtc.rs 默认 4 个第三方 STUN（第二期待定项）。要不要在 porta-server 的 UDP 端口上回 STUN Binding（几十行）；TURN 和 hbbr 功能重叠，要不要。UU 的 STUN/TURN 只有 IPv4，IPv6 只靠 host 候选也够用（笔记 05 §1）。
  4. 在"路由器透明代理只代理 TCP + 本机开 TUN"下的预期：host 候选含物理网卡和 TUN 网卡地址，局域网那对靠连通性检查就能通，不依赖服务端同网判定；经 TUN 的 STUN 在代理规则直连时拿到真实映射（笔记 05 §4）。实测核对，包括两台的 UDP 走不同代理出口的情况（§2.5.8）。
- **做法**：在 porta-server 的临时分支上做最少的信令转发（不合并、不审查），两台 Porta Windows 客户端打开 `enable-webrtc`，在维护者网络里测三种场景（同一局域网两端都开 TUN，其中一组让两台的 UDP 走不同代理出口；外网连回家；家里连外网），每种 10 次，记成功率、建连耗时、最终候选对类型；再做 50 次连接/断开，看崩溃、卡住、泄漏。
- **产出**：`docs/research/第三期/06-WebRTC评估.md`：成熟度结论、porta-server 改动清单和工作量、实测表、建议。
- **时长**：3 个工作日（读码和上游历史 1 天、临时转发 1 天、实测和结论 1 天）。本块服务端合入之后做，方便和 KCP-UDP 打洞对比。
- **进第四期的条件**（同时满足）：(a) 至少一种场景里 WebRTC 能直连，而 KCP-UDP 打洞加局域网多候选、IPv6 打洞不能（包括 §2.5.8 的场景），或者建连明显更快、换网不断；(b) 50 次循环无崩溃、无卡死；(c) 服务端改动（含防伪造）估计不超过一周。任一不满足就不做，等上游把 WebRTC 设为自建服务器默认开再看。

## 4. 客户端改动（porta-client）

### 4.1 `libs/porta/src/punch.rs`（新模块，`lib.rs` 加 `pub mod punch;`）

```rust
const FEATURE: &str = "udp-punch";
const TEST_NAT_PAD: usize = 60;   // 整个请求 66 字节，不短于服务端的 64 字节门槛（§2.5.2）

/// 当前 API 地址是宣告了 udp-punch 的 porta-server。控制端的三处开关都看它（界面进程）。
pub fn wait_udp_nat() -> bool { crate::report::has_feature(FEATURE) }

/// 上游 client.rs test_udp_uat 的 Porta 版，签名相同：请求带 porta_pad；收到回包时先把 token
/// 存进 UDP_TOKENS、再写 udp_port（读到端口时 token 一定已在）。
pub async fn test_udp_nat(udp_socket: Arc<UdpSocket>, server_addr: SocketAddr,
                          udp_port: Arc<Mutex<u16>>, stop_udp_rx: oneshot::Receiver<()>);

/// 取走这个 UDP 测试 socket 收到的 token；没有就空。
pub fn take_udp_token(socket: Option<&Arc<UdpSocket>>) -> Vec<u8>;

/// 被控端：PunchHole.porta_udp_addr 能解出地址（端口非零、不是未指定地址）时，用它替换 UDP 打洞目标。
pub fn udp_target(peer_addr: &mut SocketAddr, porta_udp_addr: &[u8]);

/// handle_punch_hole 的 relay_v4 覆盖：porta-server 发了 nonce、控制端有 UDP 映射端口、
/// 本地没有代理/强制中继时，UDP 打洞试了再说，不看 TCP 测出的 NAT 类型（P-3 按推荐 A）。
pub fn relay_v4(upstream: bool, relay: bool, ph: &PunchHole) -> bool {
    upstream && !(ph.udp_port > 0 && !ph.porta_nonce.is_empty() && !relay)
}
```

- **`test_udp_nat`**：照抄上游的重发节奏和日志（包括 `UDP NAT test to … finished: …` 那一行，§6.3 的判据照旧可用），只多两处：请求带 60 字节填充；收到 `TestNatResponse` 时先存 token 再写端口。约 80 行，和上游重复，换来上游函数一行不改（`client/PORTA.md` §1）。上游那条连续出错时的限频日志改用 `hbb_common::throttled_log!`。
- **token 怎么交到打洞请求里**：`_start_inner` 的参数不改（加参数要改签名和两处调用）。token 存在模块内的 `static UDP_TOKENS: Mutex<Vec<(Weak<UdpSocket>, Vec<u8>)>>`，按测试用的那个 UDP socket 对应：`_start` 把同一个 `Arc<UdpSocket>` 既交给测试任务，又经 `udp.0` 交给 `_start_inner`，`take_udp_token` 按 `Weak::as_ptr == Arc::as_ptr` 找到并取走。存 `Weak` 而不是裸指针：`Weak` 还在，那块内存就不会被新 socket 复用，不会张冠李戴。每次存入时顺手删掉 socket 已释放的条目（`strong_count() == 0`），表的大小不超过同时在跑的 UDP 测试数，不加上限和过期规则。
- 只有带 UDP 的那条打洞请求带 token：只做 TCP 打洞的后备请求 `udp` 是 `(None, None)`，`take_udp_token(None)` 返回空（§2.5.6）。
- **`udp_target`**：解不出就保持原值，等于上游写法。

为什么 P-3 按推荐 A（维护者没有偏好）：UU 日志显示开 TUN 时 UDP 的反射地址就是家宽出口，TUN 在代理规则直连时不破坏 UDP 打洞【实测：解密日志，笔记 05 §4】；而 TCP 在 TUN 下由本机代理终结、再由出站重新建连（笔记 04 §3.3、笔记 05 §5 第 3 行），同一本地端口连两个服务端端口时看到的来源端口由代理决定，用 TCP 测 NAT 类型会误判成对称。"会测成 `SYMMETRIC`"仍待被控端服务进程日志的 `Tested nat type` 核实（笔记 05 §7 第 6 项，§6.3 第 6 条）。

### 4.2 `libs/porta/src/options.rs` `self_hosted_punch_default`

`OPTION_ENABLE_UDP_PUNCH` 在 `crate::punch::wait_udp_nat()` 为真时返回 `Some("Y")`，否则照旧 `None`（上游的 `"N"`）。挂钩已在 `src/common.rs` `get_local_option` L1317，不加新挂钩。函数注释里"UDP 先不开"的理由改成新的条件。用户手动设过的值照旧优先（上游只在值为空时走默认）。

### 4.3 上游文件里的挂钩

| # | 文件、函数 | 位置 | 行数 | 内容 |
|---|---|---|---|---|
| H-a | `src/rendezvous_mediator.rs` `handle_punch_hole` | L1101（`relay_v4` 表达式结尾）之后、L1102 `let punch_udp` 之前 | 2 | `// porta: a UDP punch the server vouched for is tried, not ruled out by the TCP-measured NAT type`<br>`let relay_v4 = porta::punch::relay_v4(relay_v4, relay, &ph);` |
| H-b | 同上 | L1151（`msg_punch` 字面量结尾 `};`）之后、L1152 `if ph.udp_port > 0 {` 之前 | 2 | `// porta: echo the nonce so porta-server takes this PunchHoleSent over UDP`<br>`let msg_punch = PunchHoleSent { porta_nonce: ph.porta_nonce, ..msg_punch };` |
| C-3 | 同上 | L1153（`peer_addr.set_port(ph.udp_port as u16);`）之后、L1154 `self.punch_udp_hole(…)` 之前 | 2 | `// porta: punch at the UDP address porta-server saw A's NAT test come from`<br>`porta::punch::udp_target(&mut peer_addr, &ph.porta_udp_addr);` |
| H-c | `src/client.rs` `_start_inner` | L893（`if !exchanged && legacy_secure { secure_tcp … }` 的结尾 `}`）之后、L894 注释之前 | 2 | `// porta: against a udp-punch porta-server, wait for the UDP NAT test after a key exchange too`<br>`let legacy_secure = legacy_secure && !porta::punch::wait_udp_nat();` |
| C-1 | `src/client.rs` `_start`（L417 起） | L505（`let func = async move {`）之后、L506 `allow_err!(test_udp_uat(…).await);` 之前 | 4 | `// porta: against a udp-punch porta-server, the padded NAT test that also brings back a token`<br>`if porta::punch::wait_udp_nat() {`<br>`    return porta::punch::test_udp_nat(socket_cloned, addr, up_cloned, stop_udp_rx).await;`<br>`}` |
| C-2 | `src/client.rs` `_start_inner` | L971（`PunchHoleRequest` 字面量结尾 `});`）之后、L972 `let webrtc_session_key` 之前 | 2 | `// porta: the UDP egress token from this connection's own NAT test`<br>`msg_out.mut_punch_hole_request().porta_udp_token = porta::punch::take_udp_token(udp.0.as_ref());` |

上游文件合计：`src/rendezvous_mediator.rs` 3 处 6 行，`src/client.rs` 3 处 8 行，`src/common.rs` 1 处 5 行（§4.4）。

- H-a：`relay` 是 L1059 的 `local_proxy || ph.force_relay`。H-a 在 `ph` 被部分移走之前（`ph.relay_server` 在 L1117、`ph.socket_addr` 在 L1143 才移走），借用合法；之后的 `punch_udp`、`punch_tcp`、`take_pair` 都用遮蔽后的 `relay_v4`。只看本次 `PunchHole` 带没带 nonce，不读能力缓存（被控端在服务进程里）。
- H-b：只移走 `ph.porta_nonce`；后面用到的 `ph.udp_port`（Copy）、`ph.webrtc_sdp_offer`（借用）不受影响。TCP 路径的 `PunchHoleSent` 也带上 nonce，服务端在 TCP 上忽略它。
- C-3：`ph.socket_addr` 在 L1143 已移进 `msg_punch`，`ph.porta_nonce` 在 H-b 移走，`ph.porta_udp_addr` 没被动过，借用合法；`peer_addr` 是 L1050 的 `let mut`。只改 UDP 打洞目标（以及随后 `punch_udp_hole` 里这条连接的对端地址），`PunchHoleSent.socket_addr` 仍是 A 的 TCP 地址（§2.5.5）。
- H-c：`legacy_secure` 在 L893 之后只在 L898 的 `filter` 里用到（已核对），遮蔽不影响前面的密钥交换。连原版 hbbs 时 `wait_udp_nat()` 为假，行为不变。**必须保留**：上游里登录用户（有令牌、配了 Key）不等 UDP 测试就发打洞请求（L894~897 的注释），token 多半赶不上，同网判定的新规则就用不上（§2.5.3）。
- H-c 对耗时的影响【读码推断】：等待从密钥交换之前开始计时（`udp_nat_wait_from`，L866），等到 `rtt / 2`（TCP 建连不短于 100 毫秒）或 400 毫秒（短于 100 毫秒，即 TUN、网关透明代理或局域网服务器）为止，回包一到立即结束。密钥交换本身是一个往返，已长于 `rtt / 2`，正常网络下不多等；读 `udp_nat_port`（L926）在 TCP 建连加密钥交换之后，至少两个往返，UDP 回包只要一个。只有 TCP 建连被代理在本地应答、UDP 又慢一点时才多等，最多多等"400 毫秒减去密钥交换耗时"，这正是透明代理和 TUN 环境要兜住的情况。
- C-1：`return` 只退出 spawn 出去的那个 async 块。服务端没宣告 `udp-punch` 时照旧调上游 `test_udp_uat`，原行不动。`wait_udp_nat()` 读界面进程的能力缓存，`_start` 就在界面进程里。
- C-2：写在字面量之后而不是字面量里：02 块的 `porta_from_id` 挂钩在字面量里（L969 后），两处隔两行上游代码，两块并行合并时不冲突。`udp.0` 在 L1034 才被取走，这里还在。`msg_out` 在三轮打洞里重复发送，token 一起重发（第三轮在第 9 秒，30 秒有效期够用，§2.5.2）。

### 4.4 开 TUN 时的 IPv6 直连：绑物理网卡的全局 IPv6（笔记 05 §6 第 3 项）

IPv6 是 CGNAT 家宽回家最主要的直连路，维护者的机器都开 TUN。UU 的 IPv6 也只靠 host 候选、没有 IPv6 STUN（笔记 05 §1），和 Porta 的 IPv6 打洞同一类，所以关键是本机能不能拿到、并且用上物理网卡的全局 IPv6。

- **现状**【读码】：`src/common.rs` `test_ipv6`（L2762）先用 `test_bind_ipv6`（L2749，`connect` 一个全局地址让内核选源地址）取本机地址，只收 `2000::/3`（L2777~2794），日志 `Found public IPv6 address locally`；再后台问 STUN（L2825~2850），结果覆盖前者，日志 `Found public IPv6 address via STUN server`。打洞 socket 由 `get_ipv6_socket`（L2980）绑在这个地址上，绑不上时日志 `Failed to create UDP socket for IPv6`。
- **问题**【推测】：TUN 接管 IPv6 默认路由时，`test_bind_ipv6` 选出的是 TUN 的地址（通常是 ULA），被过滤掉；STUN 也经 TUN 走，被代理出去时拿到的是代理出口地址（绑不上），或者干脆失败。结果取决于代理规则，违反"不假定运行环境"。
- **做法（开不开 TUN 都是同一条规则）**：全局 IPv6 本身就是公网地址，不需要 STUN 来发现。本机物理网卡有全局 IPv6 就直接用它，跳过路由探测和 STUN；没有才照上游走。
  - `libs/porta/src/lan.rs` 新函数 `pub async fn physical_global_v6() -> Option<SocketAddr>`：`spawn_blocking(nics)` 枚举一次网卡（和 `connect_candidates` 同样的写法），按 03 块 `select_candidates` 的网卡顺序（有线优先、链路速度从高到低），取第一块在线、非虚拟、`has_gateway_v6` 的网卡上的第一个全局地址（`is_global` 且不在 `excluded_v6` 里；03 块只收 `DadState == Preferred` 的地址，过期的临时地址不在里面），端口为 0。找到时打一条 debug 日志 `porta: IPv6 punch address from physical adapter <网卡名>: <地址>`（`test_ipv6` 一分钟最多跑一次）。非 Windows 上 `nics()` 为空，返回 `None`。复用 03 块的双地址族枚举、`is_virtual`、`has_gateway_v6`、`excluded_v6`、`is_global`，不加新的网卡判断。
  - 挂钩：`src/common.rs` `test_ipv6` 里 L2775（"占住这一分钟"那个块的结尾 `}`）之后、L2777 `match test_bind_ipv6().await {` 之前，加 5 行：
    ```rust
        // porta: a physical adapter's global IPv6 first, whichever adapter (a TUN) owns the route
        if let Some(addr) = porta::lan::physical_global_v6().await {
            PUBLIC_IPV6_ADDR.lock().unwrap().0 = Some(addr);
            return None;
        }
    ```
    返回 `None` 表示没有后台 STUN 任务，三个调用点都接受（`client.rs` L493 和 `rendezvous_mediator.rs` `start_ipv6` L1450 不看返回值，`test_ipv6_sync` 只在 `Some` 时等待）。必须提前返回：否则后台 STUN 会把代理出口地址写回来，盖掉物理地址。之后 `get_ipv6_socket` 照上游绑这个地址，控制端（界面进程）和被控端（服务进程）都走这里。比预估的 2 行多，是因为要跳过 STUN。
  - 为什么绑了就不进 TUN：Windows 默认对 IPv6 用强主机模型，源地址绑在哪块网卡上，发包就只在那块网卡的路由里找出口，不走 TUN 装的默认路由【推测：前提是那块网卡自己有 IPv6 默认网关，所以上面要求 `has_gateway_v6`；带"严格路由"之类防泄漏规则的 TUN 软件可能另外拦截，§6.3 第 7 条核对】。
  - 没开 TUN 的机器结果基本不变：路由选出的源地址本来就在物理网卡上，STUN 能绑上的结果也只能是本机地址；区别只是不再向第三方 STUN 问 IPv6。物理网卡上没有全局 IPv6（例如 IPv6 只在 6in4 隧道网卡上，IfType 131 被 `is_virtual` 排除）时照上游走，不比现在差。
- 不依赖服务端有 IPv6：IPv6 地址夹在 IPv4 信令里转发，第一期已做。

### 4.5 不动的部分

- 注册保活间隔不动：`REG_INTERVAL` 15 秒（`libs/hbb_common/src/config.rs` L51），已在笔记 05 建议的 15~25 秒内。UDP 打洞两端用的都是每次新开的 socket，注册保活只影响服务端经注册映射把 `PunchHole` 送到被控端这一步。
- `test_nat_type_` 不改，TCP 测出的结果照旧用于 TCP 打洞（开 TUN 时 TCP 打洞确实做不成，`SYMMETRIC` 对 TCP 而言没错）。
- 控制端收到 `is_udp` 后的连接（L1035 起、`connect` 里的 `udp_nat_connect`）照上游。

### 4.6 `client/PORTA.md` 同步

- §2 已有挂钩列表加 `punch.rs`；`lan.rs` 的说明补 `physical_global_v6`。
- 新增 **§7"UDP 打洞与 UDP 出口证明（第三期）"**：本块 §2.2、§2.5、§4 的摘要和 §5 的兼容表。
- **§8"不配也能用：自动降级与可选优化"**（四块共用一节，内容见 README §5）里本块的几行：控制端 TCP 被代理时，同网判定靠 UDP 出口证明、UDP 打洞改打服务端观测的 UDP 地址；开 TUN 时 TCP 测出的 NAT 类型不拦 UDP 打洞（H-a）；IPv6 打洞绑物理网卡的全局 IPv6。可选优化：会合服务器的 UDP 走直连，同网判定和 UDP 打洞都按家宽出口算（两边 UDP 被不同代理出口带走时，这是手工补上 §2.5.8 缺口的办法）。

## 5. 兼容矩阵

| 控制端 | 被控端 | 服务端 | 结果 |
|---|---|---|---|
| Porta | Porta | porta-server（含本块） | 控制端拿到 UDP 映射端口和 token，服务端发 nonce，被控端按 token 里的 UDP 地址打洞、经 UDP 回带 nonce 的 `PunchHoleSent`，控制端收到 `is_udp` 后两端 KCP-UDP 直连；IPv6 地址随包到达。同网判定多一路 UDP 出口比较 |
| 原版（手动开了 UDP 打洞） | Porta | porta-server（含本块） | 同样能 UDP 打洞（原版控制端照上游走 `is_udp`）【读码，基于 `rustdesk@bd92623`，已发布的老版本可能不同，§6.3 第 3 条核对】。原版的 TestNat 不带填充、拿不到 token：同网判定只比 TCP，UDP 打洞目标照旧是 TCP 来源 IP 加 `udp_port`。原版控制端不开 UDP 打洞时照常 |
| Porta 或原版 | 原版 | porta-server（含本块） | 被控端没有 `porta_hb`，不转发 `udp_port`，走 TCP 打洞/中继，和第一期一样。服务端回了 UDP TestNat，控制端的 UDP 测试提前结束，只会更快。Porta 控制端的 token 照样参与同网判定（原版被控端开 TUN 时局域网路径仍连不上，03 §5） |
| 任意 | Porta（`libs/porta` 低于 0.3.1，即 `MIN_PORTA_VER`） | porta-server（含本块） | 不转发 `udp_port`，和第一期一样（同网判定照样看 token） |
| 任意 | 任意 | porta-server（没有本块） | `features` 里没有 `udp-punch`：Porta 控制端不默认开 UDP、不等 UDP 测试、走上游测试函数（没有 token）；服务端不转发 `udp_port` |
| Porta，便携运行（服务进程没跑） | 任意 | porta-server（含本块） | 能力缓存为空，UDP 打洞按上游默认关，不做 UDP 测试也就没有 token：同网判定只比 TCP |
| 任意 | 任意 | 原版 hbbs | 不回 UDP TestNat、不转发 `udp_port`；Porta 客户端能力缓存里没有这一项，UDP 默认关，H-a/H-b/H-c 都不生效，和上游一样 |

## 6. 测试

### 6.1 单元测试

服务端：
- `udp_punch`：`issue` 后 `redeem` 一次成功、第二次失败；过期失败；`b_id` 不符失败；表满且无过期条目时 `issue` 返回 `None`；同一来源 IP 第 9 次 `issue` 返回 `None`，换一个来源 IP 照常发放；`echoes_nonce`：`None`、超过 180 秒、版本低于 `MIN_PORTA_VER`（`porta_ver = get_version_number("0.3.0")`）→ 假，`get_version_number("0.3.1")` 等其余情况 → 真。
- token：`seal` 后 `open` 解出原地址（IPv4、IPv6 各一）；改动任一段（版本、时间戳、地址、MAC）的任一字节 → `None`；时间戳早于 30 秒前、晚于现在 → `None`；长度 27、40、空 → `None`。
- 会合模块（用现有 harness）：
  - UDP 发 3 字节的空 `TestNatRequest` → 回 `TestNatResponse`，`port` 等于来源端口，`cu` 和 `porta_udp_token` 都为空；发 66 字节带填充的 → 带 token，整个回包不长于请求；令牌桶耗尽后都不回。
  - 同网判定（A 的 TCP 来源 IP 和 B 的 UDP 注册 IP 不同）：打洞请求带一个地址 IP 等于 B 注册 IP 的有效 token → `FetchLocalAddr`，`socket_addr` 仍是 A 的 TCP 来源地址；token 无效、过期、IP 不同 → `PunchHole`；同样的请求走 WebSocket → `PunchHole`；强制中继（用掩码造：A 在掩码内、B 在掩码外，同现有测试 `forced_relay_clears_v6`，不改进程级的 `ALWAYS_USE_RELAY`）→ `PunchHole`；A 的 TCP 来源 IP 等于 B 的注册 IP、没有 token → `FetchLocalAddr`（原有判定不受影响）。
  - 打洞请求带 `udp_port`，目标有新鲜的 `porta_hb` → `PunchHole` 带 `udp_port` 和 8 字节 nonce；再带有效 token 时 `porta_udp_addr` 解出 token 里的地址、`socket_addr` 仍是 A 的 TCP 来源；没有 token → `porta_udp_addr` 为空；`porta_hb` 为空或过期 → `udp_port` 为 0、nonce 和 `porta_udp_addr` 都为空；强制中继、`ph.force_relay`、WebSocket 来源 → 都不带。
  - UDP 发带正确 nonce 的 `PunchHoleSent`（含 v6 地址）→ 控制端 TCP 连接收到 `PunchHoleResponse`：`is_udp` 为真、`socket_addr` 是 UDP 来源、`socket_addr_v6` 照转；UDP 上没有任何回包。
  - nonce 缺失、错误、重复发送 → 控制端什么都收不到。
- `conn_tracker`：`PunchHoleSentUdp` → `direct_udp`，双方有 v6 → `direct_udp_or_v6`；回落率分母包含这两项。

客户端：
- `porta::punch::relay_v4`：(上游真, 无代理, udp_port>0, 有 nonce) → 假；没有 nonce、udp_port 为 0、有代理/强制中继 → 保持真；上游假 → 假。
- `self_hosted_punch_default`：能力缓存有、没有 `udp-punch` 两种（缓存的读写由 01 块测）。
- `take_udp_token`：存入后按同一个 socket 取到一次、第二次为空；另一个 socket 取不到；socket 释放后，下一次存入时旧条目被清掉。
- `udp_target`：有效地址替换；空、长度不对、端口为 0 → 保持原值。
- `test_udp_nat` 的请求编码：带填充后整个数据报不短于 64 字节（直接对组好的消息算长度）。
- `lan::physical_global_v6` 的内部选择函数（用构造的网卡列表）：有线优先；虚拟网卡、没有 IPv6 网关的网卡、只有 ULA 的网卡不选；没有合格网卡 → `None`。

不测：TUN 代理的行为、真实 NAT 的映射规则、KCP 本身、上游 `test_udp_uat` 的重发节奏、Windows 的强主机模型。

### 6.2 集成测试

- 服务端在测试机上跑 release 版，用一个最小的 UDP 脚本（或 Rust 测试二进制）走完"带填充的 UDP TestNat（收到 token）→ TCP 打洞请求带 token → 假被控端从另一个 UDP socket 回带 nonce 的 `PunchHoleSent`"，确认被控端收到的 `PunchHole.porta_udp_addr` 是 TestNat 那个 socket 的地址、控制端 TCP 上收到 `is_udp` 的响应。能造出两个来源 IP 时（例如测试机的回环地址和公网地址各走一路），顺带核对 TCP、UDP 来源不同时服务端发给被控端的是 `FetchLocalAddr`。
- Windows 客户端构建通过（`scripts/windows/build-client.ps1`）。

### 6.3 端到端验收（维护者）

前提：两台装了 Porta 的 Windows，都开 TUN 代理，**不配任何代理规则**（Porta 不要求配置，README §5）。第 1~6 条测 UDP 打洞本身，需要两端到会合服务器的 UDP 拿到真实映射：TUN 把会合服务器的 UDP 交给代理时，打洞打到代理出口、回落中继（§9 第 1 条），这时验收临时关 TUN，或把会合服务器的 UDP 设成直连（可选优化，不是使用前提）；第 9 条专测不配规则时的自动降级。除第 2 条外，第 1~6 条为了单看 IPv4 UDP 打洞，控制端临时关掉"Enable IPv6 P2P connection"。

1. 控制端在外网（手机热点），被控端在家，连 5 次。通过：
   - `conn_attempt` 里 `outcome = 'direct_udp'`、`a_udp_port <> 0`、`relay_req_count = 0`；
   - 控制端日志有 `UDP NAT test to … finished: …, port=<非零>, …, success=true`，以及 `used to establish UDP connection with … punch`（`src/client.rs` L1591，`…` 是这一轮带上的传输，通常是 `UDP+TCP`；证明 KCP-UDP 真的连上了；`… Hole Punched …` 只说明收到了响应，不算）。
2. 同一场景打开 IPv6：期望 `outcome` 为 `direct_udp_or_v6`，控制端日志 `used to establish UDP connection` 或 `used to establish IPv6 connection`；`b_has_v6 = 1`，确认 IPv6 地址没随 UDP 包丢失。
3. 原版 RustDesk 控制端（手动开 UDP 打洞）连 Porta 被控端：判据同第 1 条的 `conn_attempt` 三项，控制端日志 `used to establish UDP connection`。
4. Porta 控制端连原版被控端：和第一期相同（`direct_tcp` 或中继），服务端 debug 日志里 `PunchHole` 不带 `udp_port`。
5. 登录状态（配了 Key、登录了账号）下重复第 1 条：判据同第 1 条，并且 `a_udp_port <> 0`。token 和端口在同一个回包里、先存 token 再写端口，所以 `a_udp_port <> 0` 就说明 token 也赶上了打洞请求（H-c 起作用）。
6. 两台被控端服务进程日志里的 `Tested nat type`（服务进程不以当前用户运行，日志不在 `%APPDATA%` 下，笔记 05 §7 第 6 项）记下来：开 TUN 时是 `SYMMETRIC`、第 1 条又通过，就说明 H-a 起了作用。
7. **开 TUN 时的 IPv6**（§4.4）：两台都开 TUN、不配规则、控制端打开 IPv6，外网连回家 5 次。两端日志有 `porta: IPv6 punch address from physical adapter …`，地址是物理网卡的全局 IPv6，并且没有 `Failed to create UDP socket for IPv6`；`conn_attempt` 里 `a_has_v6 = 1`、`b_has_v6 = 1`；控制端日志 `used to establish IPv6 connection`。
8. **同网判定（UDP 出口证明，§2.5）**：两台在同一局域网，控制端到会合服务器的 TCP 走代理出口、UDP 不走（路由器透明代理只代理 TCP，控制端本机不开 TUN；或控制端本机代理按协议分流），被控端照常。连接后核对：控制端日志有 `LAN candidate <私网地址>:<端口> won`、没有 `all N LAN candidates failed`；`conn_attempt` 最新一行 `signal = 'fetch_local_addr'`、`a_ip <> b_ip`、`outcome = 'direct_lan'`、`relay_req_count = 0`，同一 `b_id`、同一时间窗里没有 `signal = 'relay_only'` 的行。反向核对：控制端设置里关掉 UDP 打洞（不做 UDP 测试，也就没有 token）再连，`signal` 回到 `punch_hole`。
9. **不配规则时的自动降级**：两台都开 TUN、不配任何规则，TUN 把会合服务器的 UDP 交给代理。外网连回家、同局域网互连各 5 次：都能连上（中继、IPv6 或局域网），没有失败行。同局域网时记下判没判出同网：两台的 UDP 经同一个代理出口时应判出（`fetch_local_addr`），经不同出口时判不出，属于 §2.5.8 的缺口，记进 WebRTC/ICE 评估的输入。

## 7. 明确不做

- 端口预测、多端口打洞、按两端 NAT 类型分档（笔记 05 §6 第 9 项）：UU 日志里这些都没触发，家宽 NAT 判为 Cone（笔记 05 §4），先看本块之后的回落率；UPnP/NAT-PMP/PCP（第 10 项）。
- 用 UDP 重测 NAT 类型、服务端多监听一个 UDP 端口（P-3 备选 B）。
- 给 UDP 上的 `LocalAddr` 开口子（局域网路径走 TCP）。
- 把连服务端的 socket 绑到物理网卡；按发起方 ID、设备主人或地址簿权限做同网判定；要求用户配置代理规则（§2.5.9）。
- token 的记账表（一次性使用、按来源限额）：token 无状态，重放的后果见 §2.5.7。
- 每来源的 TestNat 限速表。
- WebRTC 信令转发的正式实现（只做 §3.6 的评估）。
- "先走中继、后台升级直连"和会话中换路径（第 8 项，第四期以后）。

## 8. 维护者的决定

全局清单见 README.md §1.1。

- **P-1 已定（2026-10-23）：UDP 打洞的前置障碍进第三期**（改架构 §3.8"看回落率再定"）。理由：不修这四道障碍，UDP 打洞根本不运行，"看回落率再定"永远得不到有用的数据；UU 日志里家宽 NAT 判为 Cone、同出口回环能通，普通的反射地址打洞在这类网络里大概率够用，端口预测这类手段继续排最后（笔记 05 §4、§6"日志带来的变化"）。架构文档按 §3.5 改。
- **P-3：维护者没有偏好，按推荐 A**：不测，试了再说。被控端拿到 porta-server 的 nonce、控制端有 UDP 映射端口时，不看 NAT 类型直接 UDP 打洞（H-a，2 行）。依据见 §4.1。代价：真是对称 NAT 时白试一次，控制端在对端报 `SYMMETRIC` 时的直连超时是 1 秒（`connect` 里的 `MIN`），最多晚约 1 秒回落中继。备选 B（用 UDP 向 21116、21115 各测一次，服务端多监听一个 UDP 端口）和 C（不改，开 TUN 的机器 IPv4 永远不做 UDP 打洞）不做。
- **P-2：维护者定了原则**（规则对所有运行环境都成立，不要用户配规则，不按身份授权）。本块按它新拟了 §2.5 的 UDP 出口证明，开 TUN 时的 IPv6 也照同一原则改成正文直接做（§4.4）。**§2.5 的机制待维护者确认。**

**不回复即按推荐**（属于本块的）：
- WebRTC/ICE 评估放进第三期：本块服务端合入后做 3 个工作日，只产出评估记录，不实现（§3.6）。

## 9. 已知限制和风险

1. 开 TUN 的机器上，TUN 把会合服务器的 UDP 交给代理时，服务端看到的是代理出口：UDP 打洞打到代理出口，通常失败、回落中继，不会更差；两边出口不同时同网判定也判不出（§2.5.8）。UU 日志显示 UDP 走直连时 TUN 上的反射地址就是家宽出口（笔记 05 §4）。Porta 不要求配置规则；把会合服务器的 UDP 设成直连是可选优化（README §5）。
2. TUN 路径对个别目的地会换 UDP 映射端口（笔记 05 §4，推测是 TUN 代理引入的）。控制端发 TestNat 和打洞用的是同一个 socket，映射随目的地变时，被控端打到的端口不对，回落中继。先看验收数据。
3. 控制端 TCP、UDP 出口不同（路由器透明代理只代理 TCP）时，UDP 打洞改打 token 里的 UDP 地址（§2.5.5）。控制端没有 token（原版控制端、UDP 测试的回包没赶上打洞请求）时照上游拼地址，打到代理出口、回落中继。
4. 被控端收到 `udp_port` 后只做 UDP 打洞、不再做 TCP 打洞（上游 `punch_tcp` 要求 `udp_port <= 0`，L1103）。UDP 不通而 TCP 能通的少见网络会少一条直连路，回落中继。
5. 被控端经 UDP 发 `PunchHoleSent`（上游发 3 份，间隔 10~30 毫秒），全部丢失时控制端这一轮收不到响应，要等这一轮超时（3/6/9 秒）重发打洞请求。TCP 路径没有这个问题。
6. 控制端在对端报 `SYMMETRIC` 时 UDP 直连只等 1 秒（上游 `MIN`）；跨洲往返 300 毫秒左右时打洞加 KCP 握手比较紧，可能判失败回落中继。先看验收数据，不预先改。
7. TestNat 令牌桶是全局的，被灌满时所有人拿不到 UDP 端口，退回 TCP 打洞。nonce 表每个控制端来源 IP 最多占 8 条（TCP 来源 IP 伪造不了），灌满全表（4096 条）需要约 512 个来源 IP；打洞请求里的 key 是随客户端分发的服务器公钥，不构成门槛，知道一个在线 Porta 被控端 ID、手里有这么多 IP 的人就能灌。灌满时新的打洞请求不转发 `udp_port`，同样退回 TCP 打洞。
8. `porta_hb` 只在内存：porta-server 重启或条目被淘汰后，最多约 15 秒（心跳退避时 60 秒）内不转发 `udp_port`，走 TCP 打洞。
9. 控制端机器的服务进程没跑（便携运行、没安装）时没人写能力缓存，`wait_udp_nat()` 为假，UDP 打洞按上游默认关，也没有 token。
10. 原版 RustDesk 控制端在登录状态下不等 UDP 测试（上游行为，Porta 改不到），按 §4.3 的分析多半照样拿得到端口。
11. `direct_udp` 和 `direct_tcp` 一样是推断值：服务端只知道"回了 UDP 的 `PunchHoleSent`、之后没有 `RequestRelay`"。验收以控制端日志为准（§6.3）。
12. token 在 porta-server 重启时全部失效（密钥只在内存），那一刻正在建立的连接退回原有判定和上游的打洞目标。
13. 用户手动打开 TCP 打洞时，上游的后备请求不带 token，可能和带 token 的请求判定不同：被控端两种信号都收到（并发尝试，先成者胜）；两条请求来自同一个 TCP 出口时 `conn_attempt` 合并成一行，`signal` 取被控端回包前最后到的那条（§2.5.6）。默认配置下没有后备请求。
14. **同网误判**：两户人家共用运营商 CGNAT 的同一个公网 IPv4、控制端 TCP 又被代理时，UDP 出口相同，新判成同网。控制端去连对方的私网地址，失败后回落中继，比现在晚约 1~2 秒（候选全被本机 TUN 接住时最多再加 800 ms 短握手），这次连接也不再尝试 IPv4 打洞【推测：按 `client/PORTA.md` §3.4 的超时推算】。原有 TCP 判定在两户 TCP 出口相同时本来就会这样。用 §2.5.4 的统计口径看误判率。
15. **开 TUN 时的 IPv6**：绑物理网卡后不进 TUN 是按 Windows 强主机模型推的（§4.4），带防泄漏规则的 TUN 软件可能拦截，§6.3 第 7 条核对；拦截时 IPv6 打洞失败、回落 IPv4 路径或中继，不比现在差。
