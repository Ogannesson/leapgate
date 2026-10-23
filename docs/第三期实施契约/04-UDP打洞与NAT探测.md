第三期实施契约 · 第 4 块，总述和待定问题见 README.md。状态：待维护者确认（2026-10-23）。

# UDP 打洞的前置障碍、NAT 类型判断、开 TUN 时的 IPv6 直连、WebRTC/ICE 评估

> 标注：【读码】读过现版源码；【实测：解密日志】笔记 05 引用的 UU 控制端日志里写着的；【推测】推断，没有实测。代码锚点对照 porta-client `6bb19b190`、porta-server `d8403ad`、porta-cardo 客户端线 `df76a0c` / 服务端线 `1a46681`、上游 `rustdesk@bd92623`、`rustdesk-server@873230e`。依据是 `docs/research/第三期/05-UU远程的直连与打洞.md`（下称"笔记 05"）。

> **这一块改了一条已拍板的决定。** `docs/architecture.md` §3.8 原定"UDP 打洞修不修，到第三期看中继回落率再定"。笔记 05 §5 发现开源服务端从不在 UDP 上回 `TestNatRequest`，控制端的 `udp_port` 恒为 0，UDP 打洞从来没跑过，现有回落率里 UDP 打洞是零，说明不了"修了值不值"。本块按"第三期先修前置障碍"来写，要维护者确认（§8 P-1）。

术语：
- **UDP 打洞**：两端同时往对方在 NAT 上的映射地址发 UDP 包，让两边路由器都留下放行记录，之后在这条 UDP 上跑 KCP（UDP 上的可靠传输）。上游已有这条路径，只是从没跑通。
- **TestNat**：控制端用一个 UDP socket 给服务端发 `TestNatRequest`，服务端回 `TestNatResponse{port}`，告诉它"我看到的来源端口"，也就是要交给被控端去打的那个映射端口。
- **反射/放大**：攻击者伪造来源地址给服务器发包，服务器把回包发给受害者（反射）；回包比请求大就是放大。上游 `rustdesk-server@109d9a2` 为此停掉了 UDP 上的 `PunchHoleSent`、`LocalAddr`。
- **nonce（防伪造随机数）**：服务端发给被控端的一次性随机字节，被控端经 UDP 回包时带上；伪造来源地址的人收不到它，也就伪造不了回包。

## 1. 目标与范围

依据：笔记 05 §5 差距表第 4~6 行、§6 第 3、5、6、7 项；架构 §3.8"UDP 打洞的修法"。

UDP 打洞挡着四道独立的障碍【读码，现版逐条核对】：

| # | 障碍 | 位置 |
|---|---|---|
| 1 | 服务端不在 UDP 上回 `TestNatRequest`（只在 21116/TCP 的 `handle_tcp` L879 和 21115 的 `handle_listener2` 里回），控制端 `udp_port` 恒为 0 | `porta-server:src/rendezvous_server.rs` `handle_udp`（L557 起，没有这一支；上游同名函数一样） |
| 2 | 服务端丢弃 UDP 来的 `PunchHoleSent`，被控端 UDP 打洞正是用 UDP 发它；IPv6 地址夹在这个包里一起丢 | 同上 L722~724（`109d9a2` 改的两处之一） |
| 3 | 服务端不转发 `udp_port`，也从不置 `PunchHoleResponse.is_udp`（控制端见到 `is_udp` 才去连 UDP） | `handle_punch_hole_request` L1188 注释"udp_port … not forwarded"；`handle_hole_sent`（L963）不设 `is_udp`。上游服务端全仓没有 `is_udp`/`udp_port` 的写入 |
| 4 | Porta 客户端对自建服务器默认不开 UDP 打洞 | `porta-client:libs/porta/src/options.rs` `self_hosted_punch_default` |

和它绑在一起的三件事：
- **NAT 类型判断**：被控端看到任一端是 `SYMMETRIC` 就对 IPv4 直接走中继（`src/rendezvous_mediator.rs` `handle_punch_hole` L1098~1101 的 `relay_v4`）。NAT 类型是用 TCP 测的（`src/common.rs` `test_nat_type_`，L706）。开 TUN 时 TCP 由本机代理终结、再由出站重新建连，来源端口由代理决定，很可能测成 `SYMMETRIC`，把修好的 UDP 打洞也拦掉（§4.1、§8 P-3）。
- **开 TUN 时的 IPv6 直连**（笔记 05 §6 第 3 项，本块认领）：默认开已在第二期做了；本块补验收和修法候选（§4.4）。不依赖服务端有 IPv6。
- **WebRTC/ICE**：只立一个有时间上限的评估项（§3.6），不实现。

上游 `src/client.rs` L663 的 `UDP_NAT_TEST_GRACE` 说的是另一件事：TUN 或网关透明代理在本地几毫秒内应答 TCP 握手，按 `rtt / 2` 算的等待窗口太短，上游已改成"TCP 建连短于 100 毫秒就等固定 400 毫秒"。它修的是"等得太短"，前提是服务端会在 UDP 上回包；开源服务端根本不回，所以在 Porta 部署里 `udp_port` 恒为 0 的原因是障碍 1【读码】。

不在本块：同网判定、局域网 IPv6 候选和网卡分类（03 块）；发起方 ID `porta_from_id`（03 块随第 1 批加，02、03 块都用）。

**依赖和实施顺序**（总述 README.md 的第 2 批）：依赖第 0 步的合并 proto 提交（两个 `porta_nonce`），以及 01 块的服务端心跳 handler（写 `Peer.porta_hb`、`features`）和客户端能力缓存（`porta::report::has_feature`）。和 02 块并行，后合的一方变基；两块在 `rendezvous_server.rs`、`conn_tracker.rs`、`rendezvous_mediator.rs`、`client.rs` 里的改动不相邻。不加迁移。

## 2. 协议与接口

### 2.1 proto（第 0 步的合并提交，两条 porta-cardo 线各一份，内容一致）

```proto
message PunchHole {
  ...
  // Porta: one-time nonce for a UDP punch; the controlled side echoes it in the
  // PunchHoleSent it sends over UDP. Set only together with udp_port.
  bytes porta_nonce = 1000;
}

message PunchHoleSent {
  ...
  // Porta: PunchHole.porta_nonce echoed back; porta-server takes a PunchHoleSent over UDP
  // only with a nonce it issued.
  bytes porta_nonce = 1000;
}
```

- 字段号按消息独立，两处都是 1000。`TestNatRequest`/`TestNatResponse` 不改。原版客户端、原版 hbbs 遇到它们直接忽略。
- 文件头的号段注释（Porta 占 1000~1999）和 `PunchHoleRequest.porta_from_id = 1000` 在同一个提交里，见 README.md。

### 2.2 能力宣告和"被控端会回带 nonce"的判断

- **服务端 → 客户端**：本块合入后，Porta 心跳响应的 `features` 一直带 `"udp-punch"`（01 块 §3.6 接入点表）。不加配置开关：不想要这项功能就不合入。
- **客户端读法**：控制端的两处开关（§4.2 默认值、§4.3 H-c）都在界面进程里，经 `porta::report::has_feature("udp-punch")` 读能力缓存。缓存由服务进程写进 Config 的 options（键 `porta-api-caps`，值是"API 根地址 + features"），经现有的 Options 同步到界面进程；`has_feature` 自己按上游 `get_api_server` 算当前根地址再比较，不依赖进程内 static（01 块 §2.5、§4.4）。
- **服务端判断被控端支不支持**：读 01 块写的内存字段 `Peer.porta_hb: Option<PortaHb { at, porta_ver }>`（Porta 心跳验签通过后写）。`at` 在 180 秒内，且 `porta_ver` 不低于 `udp_punch::MIN_PORTA_VER`（对应 `libs/porta` 0.3.1：本块客户端合入时把版本号前移到 0.3.1，01 块 §2.3 的版本号规则），才认为它会回带 nonce。本块不再加自己的字段或状态。180 秒按 01 块的心跳节奏取：空闲 15 秒一次，失败退避到 60 秒。
- 和 01 块同一次发布时版本条件恒真，但保留：防客户端降级回 0.3.0（有 01 块、没有本块）。心跳请求不加新键。

### 2.3 UDP 上的消息与回包

| 来包（UDP） | 服务端做什么 | 回包 |
|---|---|---|
| `TestNatRequest` | 过全局令牌桶，回来源端口 | `TestNatResponse{port}`，**不带** `cu`（`ConfigUpdate` 带服务器列表，会放大）。客户端的请求是空消息，约 2~3 字节，回包最多 7 字节；加上 IP/UDP 头 28 字节约 31 对 35 字节，约 1.13 倍；以太网最小帧 64 字节下两者一样大 |
| `PunchHoleSent`，带有效 `porta_nonce` | 按 nonce 找到控制端的 TCP 连接，发 `PunchHoleResponse{is_udp: true}` | **UDP 上不回任何包**，只往已存在的 TCP 连接写 |
| `PunchHoleSent`，不带或带无效 nonce | 丢弃，不回包、不打日志（每个包都能触发） | 无 |
| `LocalAddr` | 照旧丢弃 | 无 |

`109d9a2` 之前的 UDP `PunchHoleSent` 是把回包经 UDP 发往包里自带的 `socket_addr`（攻击者可以随便填），那才是反射源。改成"只写进控制端已有的 TCP 连接"后不存在反射，nonce 只用来防伪造。本块没有 HTTP 接口。

### 2.4 控制端的 TCP 和 UDP 从不同出口出去时

例如路由器透明代理只代理 TCP、控制端在家里往外连。服务端把控制端的"TCP 来源 IP"和"UDP 映射端口"拼成一个地址交给被控端（`PunchHole.socket_addr` 的 IP 加 `udp_port`），两者出口不同时被控端打到代理出口上，必然失败、回落中继【读码】。被控端那一侧没有这个问题（它的地址取自 UDP 包本身）。外网连回家这个主要场景不受影响。

这和 03 块第 1 项是同一个根因，合并成总述里的 **P-2**。无论 P-2 选哪一项，"开代理的机器要配的规则"（`client/PORTA.md` §8）都写上"会合服务器的 TCP 也走直连"，UDP 打洞在这种环境下就靠这条规则。本块不改协议。

没采用的协议改法（留作记录）：Porta 控制端在 TestNat 请求里加填充（保证回包不大于请求），服务端回完整的观测地址，控制端在打洞请求里带上、服务端转给被控端。代价：proto 加 4 个字段，都从 1001 起（`TestNatRequest`、`TestNatResponse` 各一个 1001，`PunchHoleRequest`、`PunchHole` 各一个 1001，这两条消息的 1000 已被占用）；`src/client.rs` 再加 2~3 处挂钩，被控端 `handle_punch_hole` 再加 1 处。**反射风险**：被控端打洞包的目的 IP 变成控制端自报的值，恶意控制端可以填任意第三方的 IP 和端口，让知道 ID 的大量被控端往那里发打洞包和 KCP 握手；现在的写法里 IP 是服务端看到的，控制端只能定端口。真要做，只能用服务端处理 UDP TestNat 时按控制端身份记下的观测地址，或者要求自报 IP 等于服务端看到的 TCP 来源 IP 或那条 TestNat 的 UDP 来源 IP。

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
```

- `MIN_PORTA_VER` 照 hbb_common `get_version_number` 的算法写死：每段乘 1000 累加，末段再乘 10，"0.3.1" 得 3010，"0.3.0" 得 3000。§6.1 的 `echoes_nonce` 测试直接用这个常量。
- **按来源限条数**：`issue()` 发放前在锁内遍历一次待用表（最多 4096 条），统计未过期、且控制端 TCP 来源 IP（`a_addr.ip()`，规范化成 IPv4）相同的条数，达到 8 条就返回 `None`：这一次不发随机数、不转发 `udp_port`，退回 TCP 打洞。不加新的数据结构。TCP 来源 IP 伪造不了，8 条够一户人家同时发起两三次连接（每次连接 10 秒内最多约 3 轮打洞请求）。
- 随机数用已有依赖 `sodiumoxide::randombytes`，不加依赖。
- 内存：每条约 0.3 KB（id 截到 253 字节），4096 条约 1.2 MB。只有带对 key、目标在线、目标支持的打洞请求才建条目。
- 不验 UDP 来源 IP 是否等于被控端注册 IP：被控端打洞用的是新开的 UDP socket（`new_direct_udp_for`），多出口或开 TUN 时来源 IP 可能和注册时不同，nonce 已经够防伪造。

### 3.2 `src/rendezvous_server.rs`

1. **`handle_udp` 新增 `TestNatRequest` 分支**（插在 L759 `_ => {}` 之前，约 8 行）：
   ```rust
   Some(rendezvous_message::Union::TestNatRequest(_)) => {
       // porta: answer the UDP NAT test, port only (no ConfigUpdate: it would amplify)
       if self.nat_tests.take() {
           let mut msg_out = RendezvousMessage::new();
           msg_out.set_test_nat_response(TestNatResponse { port: addr.port() as _, ..Default::default() });
           socket.send(&msg_out, addr).await?;
       }
   }
   ```
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
4. **`handle_punch_hole_request` 的增量**（只写本块的；02 块接 `a_id`、03 块改 `same_intranet`）：
   - L1126~1129 读 `peer` 的块里多算一个值：`udp_punch::echoes_nonce(r.porta_hb.as_ref(), Instant::now())`。
   - 在 `else`（发 `PunchHole`）分支、L1211 `msg_out.set_punch_hole(...)` 之前：
     ```rust
     // porta: forward A's UDP NAT port only to a B that echoes the nonce
     let udp_ok = !forced_relay && !ph.force_relay && !ws
         && (1..=65535).contains(&ph.udp_port) && echoes;
     let porta_nonce = if udp_ok { udp_punch::issue(addr, &id) } else { None };
     ```
     `PunchHole` 字面量里加 `udp_port: if porta_nonce.is_some() { ph.udp_port } else { 0 }` 和 `porta_nonce: porta_nonce.unwrap_or_default()` 两行。共约 8 行。L1188 的注释改成"WebRTC offer not forwarded; udp_port only with a nonce (PORTA.md §6.11)"。
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
- §2 文件表加 `src/udp_punch.rs`（nonce 表和"会不会回带 nonce"的判断）。
- §3 模块 static 列表补 `udp_punch` 的 nonce 表。
- §6 第 2 条："不转发 `udp_port`"改为"只对会回带 nonce 的被控端转发，见第 11 条"。
- §6 第 8 条资源上限补 nonce 表 4096 条（每个控制端来源 IP 最多 8 条）、TestNat 令牌桶 1000/s。
- §6 新增**第 11 条"UDP 打洞"**：§2.2~§2.3、§3.1~§3.2 的全部取值（nonce 8 字节、10 秒、4096 条、每来源 8 条；`porta_hb` 180 秒加版本下限；TestNat 令牌桶 1000/s、回包不带 `cu`；UDP 上永不回 `PunchHoleSent`/`LocalAddr` 的回包）。
- §8 `outcome` 全集和回落率公式加 `direct_udp`、`direct_udp_or_v6`；`reply` 加 `punch_hole_sent_udp`。
- §14 `stats` 的说明补"分项列出 `direct_udp`、`direct_udp_or_v6`"。

`docs/architecture.md`（按 P-1 的结论二选一）：

| 位置 | P-1 选"进" | P-1 选"不进" |
|---|---|---|
| §3.8"决定"和"UDP 打洞修不修看数据" | 改为"第三期先修前置障碍（服务端在 UDP 上回 TestNat、nonce 校验的 UDP `PunchHoleSent`、转发 `udp_port`/`is_udp`），再看回落率决定要不要做更重的打洞手段"，补一句"第一期以来的数据里 UDP 打洞为零" | 保留原决定，补一句"开源服务端从不在 UDP 上回 TestNat，现有回落率里 UDP 打洞为零，说明不了修了值不值" |
| §5 第三期第二条 | "UDP 打洞：修前置障碍（加防伪造随机数，§3.8）" | 加注"回落率数据不含 UDP 打洞" |
| §6 第 5 条（随机数方案没细化） | 改为"随机数方案见第三期实施契约第 4 块；开 TUN 时 UDP 打洞依赖代理规则让会合服务器的 UDP 直连" | 不改 |
| §7 第 7 条 | 补"2026-10-23 改定：第三期先修 UDP 打洞的前置障碍" | 补"2026-10-23 更正：现有回落率不含 UDP 打洞" |

### 3.6 WebRTC/ICE 评估项（笔记 05 §6 第 7 项，按推荐放进第三期，不是实现）

**为什么值得评估**：UU 两次局域网会话的直连全部来自上游 libwebrtc 的标准 ICE 能力（多网卡 host 候选、IPv6 host 对、对端反射候选、持续收集），网易的增强打洞一项都没起作用【实测：解密日志，笔记 05 §3.2、§6 第 7 项】。上游 RustDesk 已经带了一条 WebRTC 路径。**如果评估通过，第四期可以用 ICE 替代 Porta 自写的局域网多候选和 IPv6 打洞**（03 块和本块 §4.4 的那部分），而不只是补充。

- **要回答的问题**：上游现成的 WebRTC 路径能不能直接拿来，替代或补充 KCP-UDP 打洞、局域网多候选和 IPv6 打洞。
- **评估内容**：
  1. 成熟度：`client/libs/hbb_common/src/webrtc.rs`（webrtc-rs 加 rustdesk-org 补丁分支）、客户端的 offer/answer/ICE 桥接（`src/client.rs` `should_create_webrtc_offerer`、`spawn_webrtc_ice_bridge`；`src/rendezvous_mediator.rs` `spawn_webrtc_answerer`）。看上游这条路径的提交历史和时长、issue 里的崩溃和卡死、官方服务器是否默认开、为什么默认关。
  2. porta-server 要改什么：转发 `PunchHoleRequest.webrtc_sdp_offer` → `PunchHole`、`PunchHoleSent.webrtc_sdp_answer` → `PunchHoleResponse`；双向转发 `IceCandidate`。要查清的难点：控制端收到 `PunchHoleResponse` 后还要用同一条 TCP 连接收后续候选，而现在 `send_to_tcp`（L1264）发完就把这条连接从 `tcp_punch` 里取走；被控端经 UDP 发来的 `IceCandidate` 怎么防伪造（`session_key` 能不能当凭证）；带 offer 的 `PunchHole` 经 UDP 发给被控端的大小。
  3. STUN/TURN：webrtc.rs 默认 4 个第三方 STUN（第二期待定项）。要不要在 porta-server 的 UDP 端口上回 STUN Binding（几十行）；TURN 和 hbbr 功能重叠，要不要。UU 的 STUN/TURN 只有 IPv4，IPv6 只靠 host 候选也够用（笔记 05 §1）。
  4. 在"路由器透明代理只代理 TCP + 本机开 TUN"下的预期：host 候选含物理网卡和 TUN 网卡地址，局域网那对靠连通性检查就能通，不依赖服务端同网判定；经 TUN 的 STUN 在代理规则直连时拿到真实映射（笔记 05 §4）。实测核对。
- **做法**：在 porta-server 的临时分支上做最少的信令转发（不合并、不审查），两台 Porta Windows 客户端打开 `enable-webrtc`，在维护者网络里测三种场景（同一局域网两端都开 TUN；外网连回家；家里连外网），每种 10 次，记成功率、建连耗时、最终候选对类型；再做 50 次连接/断开，看崩溃、卡住、泄漏。
- **产出**：`docs/research/第三期/06-WebRTC评估.md`：成熟度结论、porta-server 改动清单和工作量、实测表、建议。
- **时长**：3 个工作日（读码和上游历史 1 天、临时转发 1 天、实测和结论 1 天）。本块服务端合入之后做，方便和 KCP-UDP 打洞对比。P-1 选"维持原决定"时没有本块服务端，评估改在 03 块合入后做，对比对象换成局域网多候选和 IPv6 打洞。
- **进第四期的条件**（同时满足）：(a) 至少一种场景里 WebRTC 能直连，而 KCP-UDP 打洞（P-1 维持原决定时没有这一项）加局域网多候选、IPv6 打洞不能，或者建连明显更快、换网不断；(b) 50 次循环无崩溃、无卡死；(c) 服务端改动（含防伪造）估计不超过一周。任一不满足就不做，等上游把 WebRTC 设为自建服务器默认开再看。

## 4. 客户端改动（porta-client）

### 4.1 `libs/porta/src/punch.rs`（新模块，`lib.rs` 加 `pub mod punch;`）

```rust
const FEATURE: &str = "udp-punch";

/// 当前 API 地址是宣告了 udp-punch 的 porta-server。控制端的两处开关都看它（界面进程）。
pub fn wait_udp_nat() -> bool { crate::report::has_feature(FEATURE) }

/// handle_punch_hole 的 relay_v4 覆盖：porta-server 发了 nonce、控制端有 UDP 映射端口、
/// 本地没有代理/强制中继时，UDP 打洞试了再说，不看 TCP 测出的 NAT 类型（§8 P-3 推荐 A）。
pub fn relay_v4(upstream: bool, relay: bool, ph: &PunchHole) -> bool {
    upstream && !(ph.udp_port > 0 && !ph.porta_nonce.is_empty() && !relay)
}
```

为什么 P-3 推荐 A：UU 日志显示开 TUN 时 UDP 的反射地址就是家宽出口，TUN 在代理规则直连时不破坏 UDP 打洞【实测：解密日志，笔记 05 §4】；而 TCP 在 TUN 下由本机代理终结、再由出站重新建连（笔记 04 §3.3、笔记 05 §5 第 3 行），同一本地端口连两个服务端端口时看到的来源端口由代理决定，用 TCP 测 NAT 类型会误判成对称。"会测成 `SYMMETRIC`"仍待被控端服务进程日志的 `Tested nat type` 核实（笔记 05 §7 第 6 项，§6.3 第 6 条）。

### 4.2 `libs/porta/src/options.rs` `self_hosted_punch_default`

`OPTION_ENABLE_UDP_PUNCH` 在 `crate::punch::wait_udp_nat()` 为真时返回 `Some("Y")`，否则照旧 `None`（上游的 `"N"`）。挂钩已在 `src/common.rs` `get_local_option` L1317，不加新挂钩。函数注释里"UDP 先不开"的理由改成新的条件。用户手动设过的值照旧优先（上游只在值为空时走默认）。

### 4.3 上游文件里的挂钩

| # | 文件、函数 | 位置 | 行数 | 内容 |
|---|---|---|---|---|
| H-a | `src/rendezvous_mediator.rs` `handle_punch_hole` | L1101（`relay_v4` 表达式结尾）之后、L1102 `let punch_udp` 之前 | 2 | `// porta: a UDP punch the server vouched for is tried, not ruled out by the TCP-measured NAT type`<br>`let relay_v4 = porta::punch::relay_v4(relay_v4, relay, &ph);` |
| H-b | 同上 | L1151（`msg_punch` 字面量结尾 `};`）之后、L1152 `if ph.udp_port > 0 {` 之前 | 2 | `// porta: echo the nonce so porta-server takes this PunchHoleSent over UDP`<br>`let msg_punch = PunchHoleSent { porta_nonce: ph.porta_nonce, ..msg_punch };` |
| H-c | `src/client.rs` `_start_inner` | L893（`if !exchanged && legacy_secure { secure_tcp … }` 的结尾 `}`）之后、L894 注释之前 | 2 | `// porta: against a udp-punch porta-server, wait for the UDP NAT test after a key exchange too`<br>`let legacy_secure = legacy_secure && !porta::punch::wait_udp_nat();` |

- H-a：`relay` 是 L1059 的 `local_proxy || ph.force_relay`。H-a 在 `ph` 被部分移走之前（`ph.relay_server` 在 L1117、`ph.socket_addr` 在 L1143 才移走），借用合法；之后的 `punch_udp`、`punch_tcp`、`take_pair` 都用遮蔽后的 `relay_v4`。只看本次 `PunchHole` 带没带 nonce，不读能力缓存（被控端在服务进程里）。只在 P-3 选 A 时加。
- H-b：只移走 `ph.porta_nonce`；后面用到的 `ph.udp_port`（Copy）、`ph.webrtc_sdp_offer`（借用）不受影响。TCP 路径的 `PunchHoleSent` 也带上 nonce，服务端在 TCP 上忽略它。
- H-c：`legacy_secure` 在 L893 之后只在 L898 的 `filter` 里用到（已核对），遮蔽不影响前面的密钥交换。连原版 hbbs 时 `wait_udp_nat()` 为假，行为不变。
- H-c 对耗时的影响【读码推断】：等待从密钥交换之前开始计时（`udp_nat_wait_from`，L866），等到 `rtt / 2`（TCP 建连不短于 100 毫秒）或 400 毫秒（短于 100 毫秒，即 TUN、网关透明代理或局域网服务器）为止，回包一到立即结束。密钥交换本身是一个往返，已长于 `rtt / 2`，正常网络下不多等；只有 TCP 建连被代理在本地应答、UDP 又迟迟不到时，最多多等"400 毫秒减去密钥交换耗时"。
- H-c 的收益可能比笔记 05 §5 估计的小：读 `udp_nat_port`（L926）在 TCP 建连加密钥交换之后，至少两个往返，回包只要一个，登录用户多半已拿到端口【读码推断】。验收用 `conn_attempt.a_udp_port` 判断：登录状态下 `a_udp_port` 基本都非零，就删掉 H-c（如非必要勿增实体）。

### 4.4 开 TUN 时的 IPv6 直连（笔记 05 §6 第 3 项）

IPv6 是 CGNAT 家宽回家最主要的直连路，维护者的机器都开 TUN。UU 的 IPv6 也只靠 host 候选、没有 IPv6 STUN（笔记 05 §1），和 Porta 的 IPv6 打洞同一类，所以关键是本机能不能拿到物理网卡的全局 IPv6。

- **现状**【读码】：`src/common.rs` `test_ipv6`（L2762）先用 `test_bind_ipv6`（L2749，`connect` 一个全局地址让内核选源地址）取本机地址，只收 `2000::/3`，日志 `Found public IPv6 address locally`；再后台问 STUN，日志 `Found public IPv6 address via STUN server`。打洞 socket 由 `get_ipv6_socket`（L2980）绑在这个地址上，绑不上时日志 `Failed to create UDP socket for IPv6`。两条 Found 日志是 debug 级，发布版日志默认记 debug（`hbb_common::init_log`）。
- **推测**：TUN 接管 IPv6 默认路由时，`test_bind_ipv6` 选出的是 TUN 的地址（通常是 ULA），被过滤掉；STUN 也经 TUN 走，代理规则直连时可能拿回物理网卡的全局地址（能绑上），被代理出去时拿到的是代理出口地址（绑不上）。结果取决于代理规则，要实测。
- **先验收，后修**（"不回复即按推荐"的一项）：§6.3 第 7 条实测。拿不到全局 IPv6 时的修法候选：用 `lan.rs` 枚举到的物理网卡全局 IPv6（03 块扩展 IPv6 后才有）代替路由选出的源地址，在 `common.rs` `test_ipv6` 里加一处 2 行挂钩。实测确认之前不加这个挂钩。
- 不依赖服务端有 IPv6：IPv6 地址夹在 IPv4 信令里转发，第一期已做。

### 4.5 不动的部分

- 注册保活间隔不动：`REG_INTERVAL` 15 秒（`libs/hbb_common/src/config.rs` L51），已在笔记 05 建议的 15~25 秒内。UDP 打洞两端用的都是每次新开的 socket，注册保活只影响服务端经注册映射把 `PunchHole` 送到被控端这一步。
- `test_nat_type_` 不改，TCP 测出的结果照旧用于 TCP 打洞（开 TUN 时 TCP 打洞确实做不成，`SYMMETRIC` 对 TCP 而言没错）。
- 控制端收到 `is_udp` 后的连接（L1035 起、`connect` 里的 `udp_nat_connect`）照上游。

### 4.6 `client/PORTA.md` 同步

- §2 已有挂钩列表加 `punch.rs`。
- 新增 **§7"UDP 打洞（第三期）"**：本块 §2.2、§4 的摘要和 §5 的兼容表。
- **§8"开代理的机器要配的规则"**（四块共用一节）里本块的两条：会合服务器的 UDP 走直连（UDP 打洞的前提，§9 第 1 条）；会合服务器的 TCP 也走直连（控制端 TCP、UDP 出口不同时，§2.4）。

## 5. 兼容矩阵

| 控制端 | 被控端 | 服务端 | 结果 |
|---|---|---|---|
| Porta | Porta | porta-server（含本块） | 控制端拿到 UDP 映射端口，服务端发 nonce，被控端经 UDP 回带 nonce 的 `PunchHoleSent`，控制端收到 `is_udp` 后两端 KCP-UDP 直连；IPv6 地址随包到达 |
| 原版（手动开了 UDP 打洞） | Porta | porta-server（含本块） | 同样能 UDP 打洞（原版控制端照上游走 `is_udp`）【读码，基于 `rustdesk@bd92623`，已发布的老版本可能不同，§6.3 第 3 条核对】。原版控制端不开 UDP 打洞时照常 |
| Porta 或原版 | 原版 | porta-server（含本块） | 被控端没有 `porta_hb`，不转发 `udp_port`，走 TCP 打洞/中继，和第一期一样。服务端回了 UDP TestNat，控制端的 UDP 测试提前结束，只会更快 |
| 任意 | Porta（`libs/porta` 低于 0.3.1，即 `MIN_PORTA_VER`） | porta-server（含本块） | 不转发 `udp_port`，和第一期一样 |
| 任意 | 任意 | porta-server（没有本块） | `features` 里没有 `udp-punch`：Porta 控制端不默认开 UDP、不等 UDP 测试；服务端不转发 `udp_port` |
| 任意 | 任意 | 原版 hbbs | 不回 UDP TestNat、不转发 `udp_port`；Porta 客户端能力缓存里没有这一项，UDP 默认关，H-a/H-b/H-c 都不生效，和上游一样 |

## 6. 测试

### 6.1 单元测试

服务端：
- `udp_punch`：`issue` 后 `redeem` 一次成功、第二次失败；过期失败；`b_id` 不符失败；表满且无过期条目时 `issue` 返回 `None`；同一来源 IP 第 9 次 `issue` 返回 `None`，换一个来源 IP 照常发放；`echoes_nonce`：`None`、超过 180 秒、版本低于 `MIN_PORTA_VER`（`porta_ver = get_version_number("0.3.0")`）→ 假，`get_version_number("0.3.1")` 等其余情况 → 真。
- 会合模块（用现有 harness）：
  - UDP 发 `TestNatRequest` → 回 `TestNatResponse`，`port` 等于来源端口，`cu` 为空；令牌桶耗尽后不回。
  - 打洞请求带 `udp_port`，目标有新鲜的 `porta_hb` → `PunchHole` 带 `udp_port` 和 8 字节 nonce；`porta_hb` 为空或过期 → `udp_port` 为 0、nonce 为空；强制中继、`ph.force_relay`、WebSocket 来源 → 都不带。
  - UDP 发带正确 nonce 的 `PunchHoleSent`（含 v6 地址）→ 控制端 TCP 连接收到 `PunchHoleResponse`：`is_udp` 为真、`socket_addr` 是 UDP 来源、`socket_addr_v6` 照转；UDP 上没有任何回包。
  - nonce 缺失、错误、重复发送 → 控制端什么都收不到。
- `conn_tracker`：`PunchHoleSentUdp` → `direct_udp`，双方有 v6 → `direct_udp_or_v6`；回落率分母包含这两项。

客户端：
- `porta::punch::relay_v4`：(上游真, 无代理, udp_port>0, 有 nonce) → 假；没有 nonce、udp_port 为 0、有代理/强制中继 → 保持真；上游假 → 假。
- `self_hosted_punch_default`：能力缓存有、没有 `udp-punch` 两种（缓存的读写由 01 块测）。

不测：TUN 代理的行为、真实 NAT 的映射规则、KCP 本身、上游 `test_udp_uat` 的重发节奏。

### 6.2 集成测试

- 服务端在测试机上跑 release 版，用一个最小的 UDP 脚本（或 Rust 测试二进制）走完"UDP TestNat → TCP 打洞请求 → 假被控端从另一个 UDP socket 回带 nonce 的 `PunchHoleSent`"，确认控制端 TCP 上收到 `is_udp` 的响应。
- Windows 客户端构建通过（`scripts/windows/build-client.ps1`）。

### 6.3 端到端验收（维护者）

前提：两台装了 Porta 的 Windows，都开 TUN 代理，按 `client/PORTA.md` §8 配好规则（会合服务器的 TCP 和 UDP 都走直连）。除第 2 条外，第 1~6 条为了单看 IPv4 UDP 打洞，控制端临时关掉"Enable IPv6 P2P connection"。

1. 控制端在外网（手机热点），被控端在家，连 5 次。通过：
   - `conn_attempt` 里 `outcome = 'direct_udp'`、`a_udp_port <> 0`、`relay_req_count = 0`；
   - 控制端日志有 `UDP NAT test to … finished: …, port=<非零>, …, success=true`，以及 `used to establish UDP connection with … punch`（`src/client.rs` L1591，`…` 是这一轮带上的传输，通常是 `UDP+TCP`；证明 KCP-UDP 真的连上了；`… Hole Punched …` 只说明收到了响应，不算）。
2. 同一场景打开 IPv6：期望 `outcome` 为 `direct_udp_or_v6`，控制端日志 `used to establish UDP connection` 或 `used to establish IPv6 connection`；`b_has_v6 = 1`，确认 IPv6 地址没随 UDP 包丢失。
3. 原版 RustDesk 控制端（手动开 UDP 打洞）连 Porta 被控端：判据同第 1 条的 `conn_attempt` 三项，控制端日志 `used to establish UDP connection`。
4. Porta 控制端连原版被控端：和第一期相同（`direct_tcp` 或中继），服务端 debug 日志里 `PunchHole` 不带 `udp_port`。
5. 登录状态（配了 Key、登录了账号）下重复第 1 条，看 `a_udp_port` 是否基本都非零，决定 H-c 留不留（§4.3）。
6. 两台被控端服务进程日志里的 `Tested nat type`（服务进程不以当前用户运行，日志不在 `%APPDATA%` 下，笔记 05 §7 第 6 项）记下来：开 TUN 时是 `SYMMETRIC`、第 1 条又通过，就说明 H-a 起了作用。
7. **开 TUN 时的 IPv6**（§4.4）：两台都开 TUN、控制端打开 IPv6，外网连回家 5 次。两端日志找 `Found public IPv6 address locally` 或 `… via STUN server`，并且没有 `Failed to create UDP socket for IPv6`；`conn_attempt` 里 `a_has_v6 = 1`、`b_has_v6 = 1`；控制端日志 `used to establish IPv6 connection`。不通过就按 §4.4 的修法候选补挂钩，再测一次。

## 7. 明确不做

- 端口预测、多端口打洞、按两端 NAT 类型分档（笔记 05 §6 第 9 项）：UU 日志里这些都没触发，家宽 NAT 判为 Cone（笔记 05 §4），先看本块之后的回落率；UPnP/NAT-PMP/PCP（第 10 项）。
- 用 UDP 重测 NAT 类型、服务端多监听一个 UDP 端口（P-3 备选 B）。
- 给 UDP 上的 `LocalAddr` 开口子（局域网路径走 TCP）。
- 控制端 TCP、UDP 出口不同时的协议修正（§2.4 的记录）。
- 每来源的 TestNat 限速表。
- WebRTC 信令转发的正式实现（只做 §3.6 的评估）。
- "先走中继、后台升级直连"和会话中换路径（第 8 项，第四期以后）。

## 8. 需要维护者定的问题

全局清单见 README.md，这里只列本块主导的两项。P-2（控制端 TCP、UDP 出口不同）本块也涉及，选项写在 03 块 §8；不论选哪项，本块都靠"会合服务器的 TCP 也走直连"这条环境规则（§2.4）。

**P-1 UDP 打洞的前置障碍进第三期**（改架构 §3.8"看回落率再定"）
- 推荐：进。不修这四道障碍，UDP 打洞根本不运行，"看回落率再定"永远得不到有用的数据。UU 日志的新信息：局域网场景里 IPv4 打洞的贡献是零（ICE 0.3 秒内就直连，增强打洞被跳过），外网场景还不知道；家宽 NAT 判为 Cone、同出口回环能通，普通的反射地址打洞在这类网络里大概率够用，端口预测这类手段继续排最后（笔记 05 §4、§6"日志带来的变化"）。本块视角的代价：服务端约 60 行加一个小模块，客户端 3 处各 2 行挂钩，不加迁移；架构文档按 §3.5 的表改。
- 备选：维持原决定，第三期不做，只在 §3.8 更正"回落率说明不了 UDP 打洞"。代价：外网直连只能靠 IPv6 和 TCP 打洞，开 TUN 的机器 TCP 打洞做不成，IPv4 外网直连基本没有。选这项时，本块只保留 §4.4（开 TUN 时 IPv6 的验收和修法候选）和 §3.6（WebRTC/ICE 评估）；评估改在 03 块合入后做，对比对象换成局域网多候选和 IPv6 打洞。

**P-3 开 TUN 时 TCP 测出 `SYMMETRIC`，怎么不让它拦住 UDP 打洞**
- 推荐 A（本文写法）：不测，试了再说。被控端拿到 porta-server 的 nonce、控制端有 UDP 映射端口时，不看 NAT 类型直接 UDP 打洞（H-a，2 行）。依据见 §4.1：UDP 在 TUN 下反射地址正常有日志依据，TCP 测类型在 TUN 下必然失真。代价：真是对称 NAT 时白试一次，控制端在对端报 `SYMMETRIC` 时的直连超时是 1 秒（`connect` 里的 `MIN`），最多晚约 1 秒回落中继。不加服务端端口、不改 proto。
- 备选 B：用 UDP 重测 NAT 类型。一个 UDP socket 分别向服务端 21116 和 21115 发 `TestNatRequest`，比两个映射端口。代价：porta-server 要在 21115 上多监听 UDP（部署多开一个端口，回包同样过令牌桶）；Porta 要另存一份"UDP NAT 类型"，在控制端发请求和被控端判断两处挂钩（TCP 打洞仍用 TCP 的结果）；只能分辨"映射随目的端口变"，分辨不了"随目的地址变"；TUN 路径对个别目的地会换映射端口（笔记 05 §4），判定还要留余量。
- 备选 C：不改。开 TUN 的机器 IPv4 永远不做 UDP 打洞，维护者所有机器都开 TUN，等于本块对 IPv4 白做。

**不回复即按推荐**（属于本块的）：
- 开 TUN 时拿不到全局 IPv6 的修法先做验收（§6.3 第 7 条），实测确认后再加 `common.rs` 的挂钩（§4.4）。
- WebRTC/ICE 评估放进第三期：本块服务端合入后做 3 个工作日（P-1 维持原决定时改在 03 块合入后做），只产出评估记录，不实现（§3.6）。

## 9. 已知限制和风险

1. 开 TUN 的机器上，UDP 打洞要靠代理规则让会合服务器的 UDP 走直连（`client/PORTA.md` §8）。UU 日志显示直连规则下 TUN 上的 UDP 反射地址就是家宽出口（笔记 05 §4）；被代理出去时服务端看到的是代理出口，打洞必然失败、回落中继，不会更差。
2. TUN 路径对个别目的地会换 UDP 映射端口（笔记 05 §4，推测是 TUN 代理引入的）。控制端发 TestNat 和打洞用的是同一个 socket，映射随目的地变时，被控端打到的端口不对，回落中继。先看验收数据。
3. 控制端 TCP、UDP 出口不同（路由器透明代理只代理 TCP）且没配"会合服务器的 TCP 也直连"时，UDP 打洞必然失败、回落中继（§2.4，P-2）。
4. 被控端收到 `udp_port` 后只做 UDP 打洞、不再做 TCP 打洞（上游 `punch_tcp` 要求 `udp_port <= 0`，L1103）。UDP 不通而 TCP 能通的少见网络会少一条直连路，回落中继。
5. 被控端经 UDP 发 `PunchHoleSent`（上游发 3 份，间隔 10~30 毫秒），全部丢失时控制端这一轮收不到响应，要等这一轮超时（3/6/9 秒）重发打洞请求。TCP 路径没有这个问题。
6. 控制端在对端报 `SYMMETRIC` 时 UDP 直连只等 1 秒（上游 `MIN`）；跨洲往返 300 毫秒左右时打洞加 KCP 握手比较紧，可能判失败回落中继。先看验收数据，不预先改。
7. TestNat 令牌桶是全局的，被灌满时所有人拿不到 UDP 端口，退回 TCP 打洞。nonce 表每个控制端来源 IP 最多占 8 条（TCP 来源 IP 伪造不了），灌满全表（4096 条）需要约 512 个来源 IP；打洞请求里的 key 是随客户端分发的服务器公钥，不构成门槛，知道一个在线 Porta 被控端 ID、手里有这么多 IP 的人就能灌。灌满时新的打洞请求不转发 `udp_port`，同样退回 TCP 打洞。
8. `porta_hb` 只在内存：porta-server 重启或条目被淘汰后，最多约 15 秒（心跳退避时 60 秒）内不转发 `udp_port`，走 TCP 打洞。
9. 控制端机器的服务进程没跑（便携运行、没安装）时没人写能力缓存，`wait_udp_nat()` 为假，UDP 打洞按上游默认关。
10. 原版 RustDesk 控制端在登录状态下不等 UDP 测试（上游行为，Porta 改不到），按 §4.3 的分析多半照样拿得到端口。
11. `direct_udp` 和 `direct_tcp` 一样是推断值：服务端只知道"回了 UDP 的 `PunchHoleSent`、之后没有 `RequestRelay`"。验收以控制端日志为准（§6.3）。
