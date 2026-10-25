# 第三期实施契约（总述）

状态（2026-10-23）：P-1、P-3、P-4 已定；P-2 维护者定了原则（§1.1）。**维护者随后调整了顺序：先评估上游现成的 WebRTC/ICE 路径（04 §3.6，评估笔记 `docs/research/第三期/06-WebRTC评估.md`），01、02 照常实施；03、04 搁置，等评估结果再定**——评估通过，直连改走 ICE，03、04 里自写的局域网多候选扩展、UDP 出口证明等大部分不做；评估不通过，按本目录的 03、04 实施，那时再请维护者确认 UDP 出口证明。01、02 已确认、开始实施；各块验收后按"同步清单"写回两份 LEAPGATE.md，本目录保留为第三期的设计记录。

**2026-10-24 更新**：01、02 已合入并按实现同步了契约（01：leapgate-server `e36ef89`、leapgate-client `a726a3daf`；02：leapgate-server `32a2060`、leapgate-client `49401a3f6`，服务端修复 `71b753e`），端到端在测试机上走完。WebRTC 评估已结束（笔记 06 §9.3）：ICE 的思路（两端交换全部候选地址，对每一对实际发探测包，哪对通用哪对）在目标环境成立，S2（同一局域网但服务端判不出）3/3、S3（IPv4 跨网）4/4、S4（CGNAT 家宽经 IPv6）2/3 直连；上游 webrtc-rs 实现在 Windows 上会被 ICMP 报错（10054）静默打死候选 socket，不采用。维护者随后拍板笔记 07 §9 的 Q1~Q9 和起草中的 P-A、P-B（§1.3）：**直连改走 Leapgate 自研的精简版 ICE**，实施契约是新增的 05 块。MVP 一次做到 srflx（反射候选：服务端看到的本机 NAT 映射地址；服务端回 STUN 并签发反射地址证明），服务端转给被控端的 OFFER 既签名又加密。03、04 按笔记 07 §7.3 收缩：03 只剩默认 ID 加盐（网卡描述分类搬进 05）；04 的 token 格式和令牌桶搬进 05 实现，§4.4 降为可选，其余（UDP 打洞的前置障碍、UDP 出口证明、P-3 的 H-a）不做；03 的 IPv6 局域网候选也不做。上一段"评估不通过时按 03、04 实施"随之作废。

第三期要做的事：Leapgate（原工作名 Porta，2026-10-24 改名）客户端的上报改走新接口并签名；服务端按客户端实测的延迟选中继；局域网直连在"路由器透明代理只代理 TCP""本机开 TUN 代理"的网络里也能成，并且用上 IPv6；UDP 打洞第一次真正跑起来。（2026-10-24 更新：后两件改由 05 的自研 ICE 完成，"两端 UDP 走不同代理出口"的网络也算在内；IPv4 打洞靠 ICE 的 srflx 对，上游 UDP 打洞维持现状。）

| 文件 | 内容 | 依据 |
|---|---|---|
| [01-上报与认证.md](01-上报与认证.md) | 新路径 `/api/leapgate/v1/`、设备签名、公钥锁定、防降级、响应签名、严格 TLS | 笔记 02、03 |
| [02-路由第二级.md](02-路由第二级.md) | 客户端测速上报、服务端按实测选中继、被控端改用服务端下发的中继 | 笔记 01 |
| [02a-修订草案-TUN下的测速.md](02a-修订草案-TUN下的测速.md) | 2026-10-25：开 fake-ip TUN 时测速每轮作废的分析和修订（测速改成和真实中继连接同路、量到中继关连接），维护者已定，已并入 02 | 读码、实测 |
| [03-局域网判定与候选.md](03-局域网判定与候选.md) | **2026-10-24 收缩后只剩默认 ID 加盐**；IPv6 局域网候选不做，网卡描述分类搬进 05（文件头有逐节说明）。原内容：IPv6 局域网候选、网卡分类、默认 ID 加盐（原第 1 项"同网判定加 UDP 比较"已排除） | 笔记 04、05、02 §1.8 |
| [04-UDP打洞与NAT探测.md](04-UDP打洞与NAT探测.md) | **2026-10-24 收缩**：token 格式和令牌桶搬进 05 实现，§4.4（开 TUN 时 IPv6 打洞绑物理网卡）降为可选，其余不做；WebRTC/ICE 评估项已完成（笔记 06）。原内容：UDP 打洞的前置障碍、UDP 出口证明、开 TUN 时的 NAT 类型、开 TUN 时 IPv6 打洞绑物理网卡、WebRTC/ICE 评估项 | 笔记 05 |
| [05-自研ICE.md](05-自研ICE.md) | 自研精简版 ICE（2026-10-24 新增）：host 和 srflx 候选（只收物理网卡）、独立信令 `leapgate_ice`（转给被控端的 OFFER 签名并加密）、服务端 21116/UDP 回 STUN Binding 和反射地址证明、STUN 连通性检查、KCP 交接、控制端竞速、ICE 结果补报（迁移 0006） | 笔记 07、06 §9 |

笔记都在 `docs/research/第三期/`。已定的方向（新路径、首次验签自动锁定、打洞请求带发起方 ID、响应签名加严格 TLS）记在仓库根目录 `AGENTS.md`"第三期设计"一条，各块不再重提。

## 1. 维护者的决定（2026-10-23；§1.3 是 2026-10-24 的自研 ICE 决定）

### 1.1 已定的四件事

**P-1 UDP 打洞进第三期（已定，按推荐）**（04 块）。改的是架构 §3.8 原来的"UDP 打洞修不修，第三期看中继回落率再定"。理由：开源服务端从不在 UDP 上回 NAT 测试（`TestNatRequest`），控制端的 `udp_port` 永远是 0，UDP 打洞从来没运行过，回落率数据说明不了它值不值得修（笔记 05 §5）。做法：只修前置障碍、做普通 UDP 打洞。服务端在 UDP 上回 NAT 测试（限速）、接受 UDP 来的 `PunchHoleSent`（带防伪造随机数，UDP 上永不回包）、只对会回带随机数的 Leapgate 被控端转发 `udp_port`；Leapgate 控制端对自建服务器默认打开 UDP 打洞。UU 远程的日志里两端家宽都判为锥形 NAT（Cone），普通反射地址打洞大概率够用；端口预测、多端口这类重手段继续排最后。

**2026-10-24 更新**：做法换了，上面的修法不做。IPv4 跨网打洞改由 05 自研 ICE 的 srflx 对完成（MVP 就含服务端 STUN 和反射地址证明，§1.3 Q5）；服务端在 UDP 上回 NAT 测试、带随机数的 UDP `PunchHoleSent`、转发 `udp_port`、Leapgate 控制端对自建服务器默认开 UDP 打洞，这几件都不做，上游 UDP 打洞维持第一期的状态（服务端不转发 `udp_port`，`server/LEAPGATE.md` §6 第 2 条不变）。理由：两端的 srflx 本来就是 ICE 的一对候选，检查用 Leapgate 自己的 STUN，单对的 UDP 打洞路径被 ICE 取代（笔记 07 §7.3）。

**P-2 维护者定的是原则，不是选项**（04 块 §2.5，原 03 块第 1 项）。原来的三个选项（按发起方 ID 比 UDP 注册 IP 并按设备主人、地址簿权限放行；只写环境规则；直接比）都被否掉。维护者的原则，**适用于整份契约**：

> 兼容性要考虑全面，不能假定任何一个运行环境，必须找到一个对于所有环境都适用的规则：要么找到一个不管开不开 TUN 都生效的方式，要么想办法判别清楚究竟有没有开 TUN。

不接受"要用户配环境规则"，也不接受"按设备主人、地址簿授权"。

按这条原则新拟的机制是 **UDP 出口证明**（机制已拟；维护者随后决定先评估 WebRTC/ICE，这个机制成了评估不通过时的备选，届时再确认）：

- 问题的根因是服务端拿两种协议的观测去比：发起方打洞请求的 TCP 来源 IP，对被控端 UDP 注册的来源 IP。路由器透明代理只代理 TCP 时，前者是代理出口，于是误判"不在同一局域网"；UDP 打洞也因为服务端把 TCP 来源 IP 和 UDP 映射端口拼成一个地址而必然失败。
- 改成比同一种协议的观测：服务端回 UDP NAT 测试时附一个 token，里面是服务端看到的发起方 UDP 来源地址和时间，用只在内存里的密钥做 MAC（无状态，30 秒有效）。发起方把 token 原样放进打洞请求，证明自己确实在那个 UDP 地址上收得到包；服务端拿 token 里的 IP 和被控端的 UDP 注册 IP 比，结果和原有 TCP 比较取"或"。被控端的 UDP 打洞也改打 token 里的地址。
- 防放大：Leapgate 控制端的 NAT 测试请求填充到 66 字节，服务端只对不短于 64 字节的请求附 token，带 token 的回包最长 49 字节。
- 不需要 `leapgate_from_id`，不查令牌、设备主人或地址簿；用户什么都不用配。
- **剩余缺口**：发起方和被控端到服务端的 UDP 都被代理、而且两边出口不同时（例如两台机器各走不同的代理节点），服务端仍然判不出同一局域网，退到 IPv6 打洞、UDP 打洞和中继，不比现在差。补这个缺口的是 04 §3.6 的 WebRTC/ICE 评估项（客户端自己对候选逐对实测，不靠服务端判）。

原则同样落到了别处：开 TUN 时 IPv6 打洞改成直接绑物理网卡的全局 IPv6（04 §4.4，原先是"先验收再决定"）；§5 改成"不配也能用"，Leapgate 不要求用户配置任何代理规则。

**2026-10-24 更新**：原则不变，同样适用于 05。UDP 出口证明不做：ICE 根本不做同网判定，两端对候选逐对实测，所有环境用同一套规则（只收物理网卡、逐对实测、强制中继时不做，05 §1）。上面说的"剩余缺口"（两端 UDP 走不同代理出口）由 ICE 的 host 对补上，笔记 06 §9.2 S2 实测 3/3。token 的格式和签发、校验搬进 05，改作 srflx 的反射地址证明（地址改用显式编码、时间戳改大端，05 §2.8）。04 §4.4 降为可选：开 TUN 时的 IPv6 直连改由 ICE 的全局 IPv6 host 候选完成，它的 socket 绑在物理网卡地址上（S4 实测）。

**P-3 开 TUN 时 TCP 测出"对称 NAT"：维护者无偏好，按推荐 A**（04 块）。TUN 会终结 TCP 再重新发起，源端口变了，用 TCP 测 NAT 类型会误判成对称 NAT，任一端对称时被控端对 IPv4 直接走中继。UU 的日志显示 TUN 下 UDP 的反射地址就是家宽出口。A 的做法：服务端给了随机数、控制端有 `udp_port` 时，被控端不看 NAT 类型直接打洞（`rendezvous_mediator.rs` 一处 2 行），最多晚约 1 秒回落中继。不做 B（用 UDP 向两个端口各测一次，服务端多监听一个端口）和 C（不改）。

**2026-10-24 更新**：H-a 不做（上游 UDP 打洞不修，见 P-1 的更新）。ICE 不看 NAT 类型、逐对实测，开 TUN 时 TCP 测成对称 NAT 不影响它；上游 TCP 打洞照旧按 TCP 测出的类型走。

**P-4 局域网候选带 IPv6（已定，按推荐）**（03 块）：ULA（`fd00::/8` 这类只在本地网络有效的地址）+ 和控制端某块物理网卡同一个 /64 前缀的全局地址，私网 IPv4 优先、全局 IPv6 优先于 ULA（控制端给 IPv6 候选晚 50~100 毫秒的先手）。理由：UU 的局域网直连实际大部分时间走以太网 IPv6，这是主路径；限定"同一个 /64"后威胁面和私网 IPv4 一样；路由器的 ULA 前缀会变，而 Leapgate 没有会话中换路径，所以 IPv4 优先。代价：上游 `src/server.rs` 改 1 条语句（双栈监听）、`libs/leapgate` 加 socket2 0.3。

**2026-10-24 更新**：`leapgate_local_addrs` 装 IPv6、`listen_dual`、`src/server.rs` 那条语句、`socket2` 依赖都不做，已合入的局域网多候选保持只有 IPv4 TCP。IPv6 局域网直连改由 ICE 的 ULA 和全局 IPv6 host 候选完成（每个 /64 一个，有临时地址只留临时地址，§1.3 Q2）。"私网 IPv4 优先"延续为 05 的地址族罚分（IPv4 0、全局 IPv6 8、ULA 16，05 §2.10）：ICE 选中一对后同样不会在会话中换路径（续选在 05 第三步），所以 MVP 仍是 IPv4 优先（Q7）。

网卡枚举改双地址族、`Nic` 加 IPv6 字段、`has_gateway` 拆成 `has_gateway_v4`/`has_gateway_v6`、`is_physical` 参数改成 `IpAddr`，除了 IPv6 候选，02 块测速的 `physical_snapshot` 和 04 §4.4 的 `physical_global_v6` 也要用（03 §4.1 开头）。

**2026-10-24 更新**：02 已做 `AF_UNSPEC` 双地址族枚举、`Nic.ipv6`、`is_physical(IpAddr)`、`physical_snapshot`（`client/LEAPGATE.md` §5.4）；`has_gateway` 拆分、网卡描述关键字、`excluded_v6`/`is_ula`/`is_global`，以及 ICE 另要的临时地址标记、按地址前 64 位分组、网络代价，都由 05 做（05 §4）；`physical_global_v6` 随 04 §4.4 可选。

### 1.2 不回复即按推荐

| 项 | 推荐 | 在哪 |
|---|---|---|
| 会话备注（控制端发到 `/api/audit/conn`，不带凭据） | 第三期不动，记进兼容债务 | 01 §8 |
| `device key reset` 的写法（按安全审查改过） | 默认只清锁定、保留 uuid 和公钥；uuid 也变了时用 `--forget` 删行。原定"删行或同时写 uuid"会让 ID 在重装期间谁都能抢 | 01 §8、§3.10 |
| `conn_attempt.a_device_id` | 不用不认证的 `leapgate_from_id` 填，保持"只来自令牌"的语义 | 02 §8 |
| 测速被代理接住时 | ~~只采信本地地址在物理网卡上的测量；任一公网中继快于 2 毫秒就整轮作废~~。2026-10-25 维护者改定（02 §8 D2-3~D2-5）：测速和真实中继连接同路，等 1.5 秒后量到中继关连接，不再需要识别代答；只留"公网中继 2 毫秒内关就整轮作废" | 02 §8、02a |
| WebRTC/ICE 评估 | **已完成（2026-10-24，笔记 06 §9.3）**：ICE 思路在目标环境成立，上游实现不采用；维护者定直连改走自研 ICE（§1.3、05 块），03、04 按笔记 07 §7.3 收缩。原推荐（已执行）：提前到第三期最前面做，和 01 并行，对照基线是现有 Leapgate 路径（局域网多候选 + TCP 打洞 + IPv6 打洞 + 中继） | 04 §3.6、笔记 06、07 |
| 原版和 Leapgate 同机共存的默认 ID 冲突 | 先在测试机上实测确认，再让 Leapgate 首次生成 ID 时加盐 | 03 §4.4、§8 |
| `token.device_verified` | 删掉笔记 02 预留的这一列：第三期没人读也没人写，等签名登录设计时再加。迁移 0004 只加 `peer.pk_pinned_at` | 01 §3.8 |
| `leapgate_only` 开关（`docs/architecture.md` §3.1 退出机制里的"只接受 Leapgate 客户端"开关） | 第三期不做，挪到退出兼容时按当时的方案再加；这是推迟，不是取消。第三期的防降级只有"已锁定的 ID 拒收不签名上报"这一条 | 01 §3.5 |

### 1.3 自研 ICE 的决定（2026-10-24）

WebRTC 评估结束后（笔记 06 §9.3），维护者拍板了笔记 07 §9 的九个问题，起草 05 时又按推荐定了 P-A、P-B（AGENTS.md 2026-10-24"自研 ICE 的决定"一条）。加粗的两条和笔记 07 的推荐**相反**，笔记 07 里与之冲突的写法作废。各条的落点和主会话定的实现取舍见 05 §1。

| 项 | 决定 |
|---|---|
| Q1 | 自研，不复用 webrtc-ice 0.13 |
| Q2 | 被控端的 host 候选（本机物理网卡上的地址）给所有能让服务端转发 OFFER 的请求方，不按身份过滤；只给物理网卡地址，IPv6 每个 /64 只给一个临时地址 |
| Q3 | 检查内核手写精简版：不冻结、角色固定（控制端 controlling、被控端 controlled）、单组件、不 trickle，写成 sans-IO（协议内核不碰 socket，只吃"收到的包、时间到了"，吐出"要发的包、下次唤醒时间"）；现成库只作差分测试参照，MVP 里做一次，不进 CI |
| Q4 | 03、04 按笔记 07 §7.3 收缩：复用 04 的 token 格式、令牌桶和 03 的双地址族枚举（04 从没实现过，"复用"是把规格搬进 05、由 05 实现）；04 的 UDP 打洞整套和 03 的 IPv6 局域网候选不做；04 §4.4 降为可选；03 的默认 ID 加盐照常。逐节去留见 03、04 文件头 |
| **Q5** | **MVP 一次做到 srflx**：服务端在 21116/UDP 回 STUN Binding、附反射地址证明、令牌桶限速；客户端从每个物理 socket 问映射地址；公网 IPv4 候选必须带证明；测试机上 netns + nftables 真实 NAT 的集成测试进 MVP 验收。续选、ICE-TCP 不进 MVP（笔记 07 推荐 MVP 只做 host） |
| **Q6** | **服务端转给被控端的 OFFER 既签名又加密**：用被控端注册并被 01 锁定的设备公钥加密，链路上看不到控制端的局域网地址和口令（笔记 07 推荐只签名） |
| Q7 | MVP 里私网 IPv4 优先于 IPv6，有了续选再改 |
| Q8 | Tailscale、ZeroTier、WireGuard 这类 VPN 网卡和 TUN 都不收集 |
| Q9 | 不用定：S3 实测开 TUN 时绑物理网卡地址的 socket 发往公网仍走物理网卡。另有三件从"建议"升为**必须**（笔记 06 §9.3）：每个候选 socket 关掉 `SIO_UDP_CONNRESET`（否则 Windows 收到 ICMP 错误后让下一次接收报 10054）、接收循环遇错不退出、不收集 TUN/VPN 网卡的候选。默认开着 Windows 防火墙时的行为没测过，放进 MVP 验收 |
| P-A | 控制端在信令连接上补报一条 ICE 结果（选中对的类型、地址族、用时或失败原因；不认证，只作统计），服务端按会话记进新表（迁移 0006），不和 `conn_attempt` 按 IP 硬合并。理由：ICE 胜出时 `conn_attempt` 照样记成 `relay`/`direct_tcp`，不补报的话中继回落率会失真 |
| P-B | 加密 OFFER 复用被控端已锁定的 Ed25519 设备密钥转成 X25519（`sodiumoxide` 的 `to_curve25519_pk/sk` 加 sealed box），不另生成密钥。libsodium 允许这样做，但建议条件允许时签名和加密分开用两把，记为已知取舍 |

## 2. 实施顺序

**当前执行的顺序（维护者 2026-10-23 调整，2026-10-24 按评估结论续上 D~F）**：

| 步 | 内容 |
|---|---|
| A | **01 服务端、01 客户端**（不同仓库，并行）；同时做 **WebRTC/ICE 评估**的读码和上游历史（笔记 06）。**已完成**：leapgate-server `e36ef89`、leapgate-client `a726a3daf` |
| B | 01 审查合入后做 **02**。proto 只需要 `PunchHoleRequest.leapgate_from_id = 1000`（加文件头号段注释），随 02 做成只含 proto 的提交，两条 leapgate-cardo 线各一份。02 用到的 `lan.rs` 双地址族网卡枚举和 `is_physical(IpAddr)`（原写在 03 §4.1 开头）随 02 一起做。**已完成**：leapgate-server `32a2060`、leapgate-client `49401a3f6`，服务端修复 `71b753e`；01、02 端到端 2026-10-24 在测试机上走完 |
| C | WebRTC/ICE 评估的临时信令转发和实测；按结论定 03、04。**已完成（2026-10-24）**：结论是自研 ICE（§1.3），03、04 收缩 |
| D | **05 自研 ICE**。先做只含 proto 的提交（`RendezvousMessage.leapgate_ice = 1000` 和 `LeapgateIce*` 消息，05 §2.2），两条 leapgate-cardo 线各一份，验收是 `git diff origin/leapgate/server origin/leapgate/client -- protos/` 为空；然后服务端、客户端并行（不同仓库）。依赖 01 的能力缓存、心跳签名机制和 `Peer.leapgate_hb`、02 的 `lan.rs` 双地址族（都已合入）。迁移 0006 归 05，在 02 的 0005 之后；客户端合入时 `libs/leapgate` 从 0.3.0 前移到 0.3.1。另做一次和现成 sans-IO 库（`is` 0.11）的差分对照（临时分支，不合并、不进 CI，05 §6.2）。**进度（2026-10-25）**：已实施并合入 main（leapgate-server `d564e30`、leapgate-client `753c9e7e7`），两边审查、`is` 差分对照（没有疑似 bug）和测试机 netns 真实 NAT 测试（6 组 × 3 次全部符合）都已完成，05 已按最终实现同步，维护者实施中另定了 F1（会合服务器域名先问物理网卡的 DNS）、F2（两个打洞开关都关时不做 ICE）；待维护者端到端（05 §6.4） |
| E | **03 收缩后的默认 ID 加盐**：只动 leapgate-cardo 客户端线（`config.rs`、`lib.rs`、新文件 `leapgate_id.rs`），先做 03 §4.4 的前置实测。和 D 没有依赖、可并行；和 D 的 proto 提交都落在 cardo 客户端线、不同文件，后合的一方变基，子模块指针各挪一次 |
| F | 可选，不排期：04 §4.4（开 TUN 时上游 IPv6 打洞绑物理网卡，依赖 05 补的 `has_gateway_v6`、`is_global`、`excluded_v6`，排在 05 之后） |

D、E 之后按 §6 验收，再按 §8 把各块写回 `server/LEAPGATE.md`、`client/LEAPGATE.md`、`docs/architecture.md`。

D 步动到的已有文件（05 内部再拆给几个 coder 时，同一个文件不要两人同时改）：服务端 `rendezvous_server.rs`（`handle_tcp` 加 `LeapgateIce` 分支和"连接已完成密钥交换"的校验、会话表的 static、`handle_udp` 在 `parse_from_bytes` 之前分流 STUN、`LookupBudget` 泛化成通用令牌桶、强制中继的表达式抽成函数和打洞共用）、`conn_tracker.rs`（ICE 结果的写库和修剪）、`cli/ops.rs`（`stats` 的 ICE 计数）、`src/lib.rs`（模块列表）、`api/device.rs`（`LEAPGATE_FEATURES`）、`peer.rs`（去掉 `leapgate_hb` 的 `#[allow(dead_code)]`）、`Cargo.toml`（`crc32fast`）、`Cargo.lock`；客户端 `libs/leapgate` 的 `lan.rs`（05 补全；做 04 §4.4 时排在 05 之后）、`lib.rs`、`Cargo.toml`（版本 0.3.1、`stun_codec`、`bytecodec`、`windows` 的 `Win32_System_IO`），`Cargo.lock`，`src/leapgate_hooks.rs`、`src/client.rs`（H-1）、`src/rendezvous_mediator.rs`（H-3）。新文件：服务端 `src/ice_signal.rs`、`src/ice_stun.rs`、`migrations/0006_ice_result.sql`；客户端 `libs/leapgate/src/ice/`、`libs/leapgate/examples/ice_peer.rs`；总仓库 `scripts/linux/ice-netns.sh`。D 和 E 唯一重叠的是 leapgate-cardo 客户端线（D 的 proto、E 的加盐，不同文件）。

下表是评估不通过、03 和 04 照本目录实施时的完整顺序。**2026-10-24 已作废，保留作记录**：评估结论是自研 ICE，下表和其后的共享文件说明都不再执行。其中 `leapgate_from_id` 已随 02 做了；04 的 6 个 proto 字段从没进过 proto（两条 cardo 线都只有 `leapgate_from_id` 和两个 `leapgate_local_addrs`），作废即可，不需要 `reserved`。

| 步 | 内容 | 可否并行 |
|---|---|---|
| 0 | **一个合并的 proto 提交**：`PunchHoleRequest.leapgate_from_id = 1000`（string）；`PunchHole.leapgate_nonce = 1000`、`PunchHoleSent.leapgate_nonce = 1000`；UDP 出口证明的四个字段 `TestNatRequest.leapgate_pad = 1000`、`TestNatResponse.leapgate_udp_token = 1000`、`PunchHoleRequest.leapgate_udp_token = 1001`、`PunchHole.leapgate_udp_addr = 1001`（都是 bytes，04 §2.1）。文件头加注释"Leapgate 字段占 1000~1999"。leapgate-cardo 两条线（客户端线、服务端线）各放一份、内容一致，两个子模块指针一次前移 | — |
| 1 | **01 服务端**、**01 客户端**（不同仓库）；**03**（只有客户端：`lan.rs`、`src/server.rs` 那条语句；leapgate-cardo 默认 ID 加盐，前置实测见 03 §4.4。03 不改服务端、不碰 `client.rs`） | 01 和 03 并行。01 客户端放 `route/mod.rs` 的空实现 |
| 2 | **02**（含 `leapgate_from_id` 的客户端 2 行、服务端取 `a_id` 的 1 行、`route/mod.rs` 的真实实现和 `self_id()`）、**04**（含 UDP 出口证明），都依赖 01 的心跳 handler 和能力缓存 | 两者并行，后合者变基。02、04 的 `lan.rs` 改动都排在 03 之后；迁移 0004（01）先于 0005（02） |
| 3 | 验收（§6），通过后把四块写回 `server/LEAPGATE.md`、`client/LEAPGATE.md`、`docs/architecture.md`（各块"同步清单"） | — |

共享文件（同一批里不要两个 coder 同时改）：服务端 `rendezvous_server.rs`（01、02、04 改，03 不改；`handle_punch_hole_request` 里 02、04 的增量基本不相邻，例外是 02 在 L1187 后加的两行紧挨 04 改的 L1188 注释，后合的一方变基时手工合）、`peer.rs`（01、04 读）、Leapgate 心跳 handler（01、02、04）、`conn_tracker.rs`（02、04）、`cli/`（01、02）、`udp_punch.rs`（04 独有）；客户端 `libs/leapgate` 的 `lib.rs`、`Cargo.toml`（01、03、04）、`route/mod.rs`（01 建空实现、02 填实）、`lan.rs`（03，之后 02、04 各加一个函数），`rendezvous_mediator.rs`（02、04）、`client.rs`（02 在 L969 后；04 在 L505、L893 后、L971 后，和 02 那处隔两行，git 能自动合并）、`common.rs`（04）。

## 3. 改动面合计

### 3.1 上游文件里的挂钩（只算第三期新增）

2026-10-24 按 05 改：04、03 收缩后不做的挂钩划掉保留，05 的挂钩补进来。01、02 的已合入。

| 文件 | 挂钩 | 合计 |
|---|---|---|
| `src/client.rs`（热点） | 02：`_start_inner` 的 `PunchHoleRequest` 字面量里 +2（`leapgate_from_id`，已合入，现在在 L970~971）；05 H-1：`Client::start` 里的 `match Self::_start(...).await` 改成 `match crate::leapgate_hooks::race_ice(..., Self::_start(...)).await`（改调用点，约 3 行；竞速窗口和上游一样取 `relay_fallback_delay_ms()`，这个私有函数怎么取到见 05 §4）；~~04：`_start` L505 后 +4（服务端宣告 `udp-punch` 时换成带填充、取 token 的 Leapgate 版 UDP NAT 测试）、`_start_inner` L893 后 +2（登录后也等 UDP NAT 测试，必须保留）、L971 后 +2（打洞请求带 token）~~（不做） | 2 处约 5 行 |
| `src/rendezvous_mediator.rs`（热点） | 02：`get_relay_server` 开头 +4（已合入）；05 H-3：`handle_resp`（L489）加 `Union::LeapgateIce` 分支，交给 `leapgate_hooks` 里 spawn 出去的处理函数，约 +3；~~04：`handle_punch_hole` L1101 后 +2（P-3 A）、L1151 后 +2（回带随机数）、L1153 后 +2（UDP 打洞改打 token 里的地址）~~（不做） | 2 处约 7 行 |
| `src/server/connection.rs`（热点） | 01：`post_audit_async` 第一行 +4（已合入） | 1 处 4 行 |
| `src/hbbs_http/sync.rs` | 01：tick 里 `stop-service` 检查之后 +4（已合入） | 1 处 4 行 |
| ~~`src/server.rs`~~ | ~~03：`accept_connection_` L198 改 1 条语句 + 1 行注释（双栈监听）。这是本期唯一改上游调用点的地方~~（03 收缩，不做） | — |
| `src/common.rs`（热点） | ~~04：`test_ipv6` L2775 后 +5（有物理网卡的全局 IPv6 就用它，跳过路由探测和 STUN）；UDP 打洞默认值复用已有挂钩~~：只在做 04 §4.4（可选）时才有这 5 行 | 0（可选 1 处 5 行） |
| leapgate-cardo 客户端线 | 03：`config.rs` `get_auto_id` +2、`lib.rs` +1、新文件 `src/leapgate_id.rs`（照常）；05：只含 proto 的提交（服务端线同样一份）；~~步骤 0 的合并 proto~~ | — |

每处都在"几行"以内，符合 `client/LEAPGATE.md` §1。本期改上游调用点的只有 05 的 H-1：`_start` 的 future 在泛型上下文里证明不了是 `Send`，用不了上游现成的 `race_transports_prefer_webrtc`，只能在调用点外面包一层自写的竞速（05 §4.8.1）。上游文件以外的逻辑都在 `libs/leapgate` 的新模块里：`api`、`report`、`sign`（01），`route`（02），`lan` 扩展和 `ice/`（05：收集、检查内核、STUN 编解码、信令）；要用主 crate 私有项的胶水（`race_ice`、被控端处理 OFFER 的函数）放在 `src/leapgate_hooks.rs`。`libs/leapgate` 新依赖：`reqwest 0.12`（`default-features = false`，开 rustls 和 socks）、`serde`（01）；`stun_codec 0.3`、`bytecodec 0.4`，`windows` 加 `Win32_System_IO` feature（05）；都已在 `Cargo.lock` 里。~~`socket2 0.3`（给 `listen_dual` 用）~~不加。

### 3.2 服务端（硬分叉）

- 新文件：`src/api/devauth.rs`（01）、`src/router/measure.rs`（02）；`src/ice_signal.rs`（05：会话表、"连接已加密"校验、REJECT 各分支、候选过滤、OFFER 加密签名后转给被控端、ANSWER 附 S 签过的被控端公钥、重发、ICE 结果记录）、`src/ice_stun.rs`（05：识别 STUN Binding 请求并回响应、FINGERPRINT、反射地址证明的签发和校验）；~~`src/udp_punch.rs`（04：随机数表，UDP 出口证明的签发和校验）~~（不做）。
- 05 还要改 `rendezvous_server.rs`、`api/device.rs`、`peer.rs`（§2 D 步）；`Cargo.toml` 显式声明 `crc32fast = "1"`（经 `flate2` 已在锁文件里），不给服务端加 `stun_codec`。
- 03 不改服务端代码；`src/auth.rs`、`src/api/ab.rs` 本期都不改（草稿里 03 的权限查询已随原第 1 项排除）。
- 迁移：`0004_device_signing.sql`（01：`peer.pk_pinned_at`）、`0005_route_legs.sql`（02：`conn_attempt.route_a_ms`、`route_b_ms`）、`0006`（05：ICE 结果表，P-A，表结构见 05 §3）。03 不加迁移。
- 内存状态：`Peer.pinned`、`Peer.leapgate_hb`（01，05 读）；防重放表（01，4096 台）；测量表（02，1 万条）；ICE 会话表（05，每个控制端来源最多 8 条，含已应答、留到控制端关信令连接的；条目随控制端的信令连接结束删掉，全表由 21116 的 2048 条并发连接封顶）；STUN 令牌桶（05，全局每秒 1000、突发 1000）。都有上限。反射地址证明无状态，只有一把进程启动时随机生成的内存密钥（05）。~~随机数表（04，4096 条，每个控制端来源 IP 最多 8 条）~~（不做）。
- 新命令：`device key`、`device key reset [--forget]`（01）；`strategy set` 拒收 `leapgate-` 开头的键（01）；路由状态显示测量来源（02）。05 的 ICE 结果怎么在命令行里看见 05 §3.8（`stats` 补一段计数）。

## 4. 兼容总表

2026-10-24 按 05 改：去掉 UDP 打洞和 token 的说法，补上 ICE 在各种组合下的行为。ICE 只在两端都是 Leapgate、服务端是含 05 的 leapgate-server、走普通路径时出现；任何一种不满足都不出 ICE 或 ICE 腿很快失败，ICE 失败一律不对外报错，结果和错误文字都是上游路径自己的（05 §4.8.1）。

| 组合 | 第三期之后 |
|---|---|
| 原版客户端 ↔ leapgate-server 第三期 | 照第一期兼容路径上报，不受影响；只有被 Leapgate 锁定过的 ID 上的不签名上报会被拒（防降级）。原版客户端不发也不认 `leapgate_ice`，直连路径和第一期一样（路由器透明代理只代理 TCP 时判不出同网，和现在一样） |
| Leapgate 客户端 ↔ leapgate-server 第三期（含 05） | 全部新功能。两端都是 Leapgate 时多一条 ICE 直连 |
| Leapgate 客户端 ↔ leapgate-server 第三期（只有 01、02） | `features` 为空，能力缓存里没有 `ice`，不启动 ICE；01、02 的功能照常 |
| Leapgate 客户端 ↔ leapgate-server 第一期，或 rustdesk-api | 手动填写的地址：新路径探测回 404 → 走上游兼容路径（不签名）；构建时注入的地址视为支持、不退回，上报停掉（01 §2.5）。不测速；能力缓存里没有 `ice`，不启动 ICE。局域网多候选要服务端转发 `leapgate_local_addrs`：已合入第三期第一项的 leapgate-server 照常；更早的 leapgate-server、或 rustdesk-api 配原版 hbbs 时被丢掉，和上游一样（03 §5） |
| Leapgate 客户端 ↔ 原版 hbbs | 新 proto 字段被忽略，行为和上游一样（加第二期的改动）；能力缓存里没有 `ice`，不启动 ICE |
| Leapgate 控制端 → 原版被控端、低于 0.3.1 的 Leapgate 被控端、或设备公钥还没被锁定的被控端（服务端含 05） | 服务端回 `REJECT{UNSUPPORTED}`，ICE 腿在信令连接上当场失败，上游路径照常（05 §2.4） |
| 原版控制端 → Leapgate 被控端 | 原版不发 OFFER，被控端不受影响 |
| 控制端便携运行（服务进程没跑） | 界面进程会在本进程里起服务，心跳和能力缓存照常，ICE 照常；只有带 `no_server` 启动、只当控制端用时缓存为空，不启动 ICE（05 §5）。被控端便携运行时心跳和 OFFER 都在界面进程里处理，ICE 照常应答 |
| 普通路径以外的连接（`id@server?key=`、直连 IP、强制中继、WebSocket、配了代理、`disable-udp`、没有可信 Key、`enable-udp-punch` 和 `enable-ipv6-punch` 都关（05 F2）） | 控制端不启动 ICE，只跑上游路径。被控端开代理、WebSocket 或 `disable-udp` 时，服务端判它不在线（回 `OFFLINE`），或它自己回 `REJECT{UNSUPPORTED}`（05 §2.3） |
| 被控端配了 IP 白名单（非空、不含 `0.0.0.0`） | 被控端回 `REJECT{UNSUPPORTED}`，只走上游路径：白名单按 ICE 选中的地址判可能拒掉以前能连上的连接，而 ICE 胜出后不再回落（05 §4.8.2） |
| 服务端没有会合私钥（`-k` 只给了公钥） | 签不了 Leapgate 心跳响应，配了 Key 的控制端能力缓存写不进 `ice`，不启动 ICE（05 §2.4）。这种部署本来就连不上登录过的客户端（`server/LEAPGATE.md` §6 第 1 条） |
| 能力缓存所在的 API 地址和会合服务器不是同一台 | 已知限制，干净失败：会合服务器是原版 hbbs 时它不做密钥交换，信令连接到超时（3 秒）失败；是不含 05 的 leapgate-server 时收到 OFFER 就断开连接；反过来就不启动 ICE，少一条路（05 §2.12） |
| API 用自签证书的部署 | Leapgate 路径只认受信任证书，又不退回上游，Leapgate 客户端的心跳和审计停掉（"无视接受无效证书选项"这条已定决策的直接后果）；能力缓存也写不进 `ice`，不启动 ICE。出路：换受信任证书，或 API 用明文 HTTP 并配 Key |
| 同一台机器装原版和 Leapgate、指向同一服务器 | 两边默认 ID 相同会互抢，03 块第 4 项加盐解决（先实测确认） |

各块的细表在各自 §5。

## 5. 不配也能用：自动降级与可选优化

**Leapgate 不要求用户配置任何代理规则。** 下表是开代理的机器上各项功能不配规则时自己会怎么做，以及配了能多拿到什么。写进 `client/LEAPGATE.md` §8。2026-10-24 按 05 改写了第 3 行以后的内容（原来按 04 写的是 UDP 出口证明、P-3 A 和 04 §4.4）；2026-10-25 测速两行按 02 修订并成一行（02a）；ICE 那几行不再有"配了能多拿到什么"，因为 ICE 逐对实测，不靠服务端的观测。

| 情况 | 不配时的自动行为 | 可选优化，配了能多拿到什么 |
|---|---|---|
| 测速时握手被本机 TUN 或路由器透明代理接住 | 2026-10-25 起测速和真实中继连接同路，等代理连好上游后量到中继关连接，量到的就是真实中继路径（02 §4.2）；原来是整轮作废、退回估计值 | 不需要 |
| 控制端到会合服务器的 TCP 被代理、UDP 没被代理（路由器透明代理只代理 TCP 等） | 两端都是 Leapgate 时，ICE 的 host 候选在局域网里逐对实测，不靠服务端判同网（05）；原版被控端照旧靠服务端的 TCP 比较，判不出同网时退到打洞或中继 | 不需要 |
| 控制端到会合服务器的 UDP 也被代理（开 TUN、规则把它交给代理） | 同上，两端 UDP 出口不同也能在局域网里直连（笔记 06 §9.2 S2 实测 3/3）。跨网时 srflx 从绑在物理网卡地址上的 socket 去问，开 TUN 时拿到的仍是家宽映射（S3 实测），不是代理出口 | 不需要 |
| 对端报了会引来 ICMP 错误的地址（对端开着同款 TUN、ULA 在本地没有路由、对端端口已关） | 每个候选 socket 关掉 `SIO_UDP_CONNRESET`、接收循环遇错不退出，socket 不会被打死；Leapgate 自己也不收集 TUN/VPN 网卡的候选（05 §4，笔记 06 §9.1 的失败机制） | 不需要 |
| 开 TUN 时 TCP 测出"对称 NAT" | ICE 不看 NAT 类型，逐对实测；上游 TCP 打洞照旧按测出的类型走（P-3 的 H-a 不做） | 不需要 |
| 开 TUN 时 IPv6 直连 | ICE 的全局 IPv6 host 候选 socket 绑在物理网卡地址上，不进 TUN（S4 实测）；上游 IPv6 打洞照旧（04 §4.4 降为可选） | 不需要 |

## 6. 验收总览

在"路由器透明代理只代理 TCP + 本机开 TUN"的真实环境里做，具体步骤在 01、02 块的 §6.3、05 块的 §6.4 和 03 块 §6 的"端到端验收"（2026-10-24 起 04 的端到端不做，05 取代）。上游原有路径（局域网多候选、TCP 打洞、IPv6 打洞）判"直连成功"一律看两样：

- 服务端 `conn_attempt`：`outcome` 是对应的直连值，`relay_req_count = 0`，并且同一 `b_id`、同一时间窗里没有 `signal = 'relay_only'` 的行（多出口代理下，回落的中继请求匹配不上会另记一行）。`direct_lan` 只说明被控端回了局域网地址，不代表连上了。
- 控制端日志：局域网看 `LAN candidate … won`、没有 `all N LAN candidates failed`；IPv6 看 `used to establish IPv6 connection`。原来按 04 写的 UDP 打洞判据（`used to establish UDP connection with … punch`、`UDP NAT test … success=true`）随 04 收缩作废。

**ICE 另有判据（05 §6.4），不能只看 `conn_attempt`**：ICE 胜出时 `conn_attempt` 照样按上游信令记成 `relay` 或 `direct_tcp`，上游先给出中继、ICE 在窗口内胜出时 `relay_req_count` 还会是 1 以上。ICE 看：

- 控制端日志 `leapgate ice: selected <本端类型>/<地址族>/<网卡> <-> <对端类型>/<地址族> in <N> ms`（例如 `leapgate ice: selected host/v4/ethernet <-> host/v4 in 85 ms`，不打具体 IP，05 §4.12）；
- 服务端 ICE 结果表（迁移 0006）里这次会话的结果是 `connected`，选中对的类型和地址族和日志一致。
- 上游直连先赢时 ICE 被取消、不打日志，结果表里这一次是 `abandoned`，单独计数，不算 ICE 失败（05 §6.4）。

ICE 的场景照笔记 06 §6.4 的 S1~S5，两端都是 Leapgate Windows、不配任何代理规则：S1（同一局域网、两端开同款 TUN，上游 WebRTC 在这里必败）和 S2（两端 UDP 走不同代理出口，现有路径判不出同网）期望选中 host↔host；S3（外网连回家）、S4（家里连外网）期望跨网直连：两端都有全局 IPv6 时按 05 §2.10 的优先级选全局 IPv6 host 对，否则是至少一端为 srflx 或 prflx 的 IPv4 对；S5 专门对比这两种情况（一端临时取消 IPv6，srflx 那一路正是 Q5 要验的）。另外三条进 MVP 验收：在一台开着默认 Windows 防火墙的机器上重复 S1、S3，安装版、便携版各一轮（笔记 06 实测的机器防火墙都关着，代表不了默认配置）；50 次连接断开（其中 10 次在"正在连接"时取消）全程不出现 `no_answer`、被控端句柄不涨（05 §6.4 第 8 步）；测试机上 netns + nftables 真实 NAT（全锥形、端口受限、对称）的集成测试（05 §6.3，coder 做）。

原来专看 UDP 出口证明的那条（04 §6.3 第 8 条）随 04 收缩作废，它要验的"TCP 被代理时也能局域网直连"由 S2 覆盖。

另外：02 块要 2 台以上中继（只有一台时在同机另一个端口再起一个 hbbr）；03 块第 4 项要先在 Windows 测试机上同时装原版和 Leapgate，确认默认 ID 冲突真的会发生。~~04 §6.3 第 9 条在不配任何规则的环境里测自动降级~~（作废；05 的 S1~S5 本来就不配规则）。

## 7. 明确不做（第三期）

- 会合层（`RegisterPk`/`RegisterPeer`）签名、公钥轮换、私钥加密存放、用户令牌绑设备（笔记 02 §2.9），退出兼容前单独定。
- 会话备注改走新路径（§1.2）；心跳下发 `disconnect`、`/api/record`、`/api/switch-grant`、审计落盘队列（笔记 03 §2.7）。
- 按两端 NAT 类型选策略、端口预测、多随机端口，先中继后升级直连，UPnP/NAT-PMP/PCP（笔记 05 §6 第 8~10 项）。
- 会话中换路径（ICE 的续选：会话中途换一对，换网不断线）、ICE-TCP（UDP 被封的网络）、consent 保活：在 05 的第三步（自研 ICE 完整版，另起契约），不在第三期 MVP。（2026-10-24 改，原写"交给 WebRTC/ICE 评估项决定第四期怎么做"。）
- 要求用户配置代理规则；把连服务端的 socket 绑到物理网卡（`client/LEAPGATE.md` §3.7）；按发起方 ID、设备主人或地址簿权限做同网判定（03 §2.1 已排除的方案）。05 根本不做同网判定。
- 反射地址证明的记账表（一次性使用、按来源限额）、每个来源单独的 STUN 限速表：证明无状态，重放的后果只是又一次按真实地址处理（05 §2.8）。（2026-10-24 改，原写"UDP 出口证明的记账表"，04 §2.5.7。）
- 修上游 UDP 打洞（04 原定的随机数、UDP 上的 `PunchHoleSent`、转发 `udp_port`）、UDP 出口证明、P-3 的 H-a、IPv6 局域网候选和双栈监听（03）：随 03、04 收缩不做（§1.3 Q4）。
- PeerConnection、DTLS、SCTP、SDP，TURN（中继仍是 hbbr）、mDNS、trickle，和浏览器或标准 WebRTC 互通；上游 WebRTC 路径的信令转发（继续不启用）。
- `RelayResponse` 那条路径不遵守固定中继的问题（第一期就有）：单独记一项，不在第三期。
- 界面上对"连 leapgate-server 时本地中继设置不再生效"的提示：留给新界面轨道，第三期只写文档。

## 8. 文档同步清单（确认后、实施时做）

**2026-10-24 按 05 重列。** 01、02 的条目已在合入时同步（`server/LEAPGATE.md` §9.5 和 §7 第二级、`client/LEAPGATE.md` §4 和 §5、`docs/architecture.md` §3.1、§3.7、§7 第 5 条）。原清单里 04 的条目随 04 收缩作废，`server/LEAPGATE.md` §6 第 10、11 条让给 05；03 只剩默认 ID 加盐那几处。原清单划掉保留在最后。

- `server/LEAPGATE.md`：05 落地时按 05 §3.11 的逐节表同步（含 §14 `stats` 补 ICE 结果计数和口径说明）。
- `client/LEAPGATE.md`：按 05 §4.13 的逐节表同步，其中新增 §6 默认 ID 加盐（03）、§7 自研 ICE（05）；§8 不配也能用（本文 §5）：02 实际写在了 §5.6，新建 §8、把 §5.6 挪进去再加 05 的几行。
- `docs/architecture.md`：§3.7 最后一条备选、§3.8、§4、§5 第三期、§6 第 5 条、§7 第 7 条已于 2026-10-24 按"直连改走自研 ICE"加了更新说明（决策原文保留）；落地时再核对一遍实现有没有偏离。§2 总图可选：扩展层加"直连（自研 ICE）"，会合模块的连线加"ICE 信令 · STUN"。§3.10 第 1 条（03 加盐落地时）。
- `docs/第三期实施契约/01-上报与认证.md`：§2.3 的版本号规则和 `features` 那两句，以及开头的实施顺序、§3.6 的接入点表、§4.4 能力缓存的两处、§4.7 末尾提到 04 的地方，已于 2026-10-24 改成归 05（各处注明了"2026-10-24 改"）。`02-路由第二级.md` 里提到 04 的几处（L21、L24、L393）没改，02 已合入、只作设计记录，以 05 为准。
- `AGENTS.md`：第三期状态。

原清单（2026-10-23，按 01~04 写，已被上面取代）：

- ~~`server/LEAPGATE.md`：§1、§2、§3、§4.2、§6（第 2、8 条改（04）、第 7 条改（01）、第 9 条补一句（03、04）、第 10 条 = 04 的 UDP 出口证明、第 11 条 = 04 的 UDP 打洞）、§7、§8、§9、§10、§11（01）、§14、§16（01）。各块 §3 末尾有逐节说明。草稿里 03 要改的 §4.1、§12.1 和 §11 里同网判定那两句已随原第 1 项排除。~~
- ~~`client/LEAPGATE.md`：§2 模块列表；§3 扩写（03）；新增 §4 上报与认证（01）、§5 路由第二级（02）、§6 默认 ID 加盐（03）、§7 UDP 打洞与 UDP 出口证明（04）、§8 不配也能用：自动降级与可选优化（本文 §5）。~~
- ~~`docs/architecture.md`：§3.1 兼容债务第 1 条（Leapgate 客户端的上报已签名，兼容路径照旧不认证）、第 3 条（客户端一半已清），并新增"会话备注不认证"一条（01 §8 第 1 项）；§3.7 第二级（"测量值放进打洞请求"改成"带发起方 ID"，连 leapgate-server 时本地中继设置不再生效）、§3.8（P-1 已定，并补 UDP 出口证明一句）、§5 第三期（03、04 各补一条）、§6 第 5 条、§7 第 5、7 条（§3.8、§5、§6、§7 第 7 条的写法见 04 §3.5）、§3.10 第 1 条（03）。~~
- ~~`AGENTS.md`：第三期状态。~~
