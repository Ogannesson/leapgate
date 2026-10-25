# Leapgate（跃门）

基于 RustDesk 深度改进的远程桌面（2026-10-22 立项）。名字 Leapgate = leap（一跃）+ gate（门）：一步跨过去的门，对应打洞直连，也是 Exit Node 的出口；中文名跃门。原工作名 Porta（拉丁语"门"），2026-10-24 因域名被占改名，带日期的调研笔记里仍是旧名。

**维护者本地有 `internal/` 时先读 `internal/README.md`**：那是独立的私有仓库，放立项背景、现网部署、待办这些不公开的内部文档。公开仓库里没有它，也不依赖它。

## 目标（2026-10-22 定）
- 原生补全 API：不再依赖第三方的 rustdesk-api（登录、地址簿、设备管理这些由自己的服务端提供）。
- 智能路由：客户端和服务端按延迟、可达性自动选直连或中继，不再手动改中继地址（开源版 RustDesk 只能填一个中继）。
- 类似 Tailscale Exit Node：被控端可以作为出口节点，让控制端的流量从它那里出去。
- 客户端 UI 重做成现代化设计。
- 复用原项目的引擎（抓屏、编解码、输入、传输），只在需要的地方改。

## 状态
- 2026-10-22：架构方案 `docs/architecture.md` 已和维护者逐条确认（第 7 节是决策记录），下一步按第 5 节分期开工，第一期是服务端。调研依据在 `docs/research/`（7 份笔记，基于上游 `rustdesk@bd92623`、`rustdesk-server@873230e`）。
- 方案只谈抽象分层，部署选址不在方案里。
- 2026-10-22：第一期（服务端）开工。三个代码仓库都已建好并挂成子模块：`server/` → `leapgate-server`（起点 `rustdesk-server@873230e`），`client/` → `leapgate-client`（起点 `rustdesk@bd92623`，和调研基线一致，第二期再合上游正式版本）；两者的 `libs/hbb_common` 都指向 `leapgate-cardo`（`5d52530`）。子模块地址都是相对路径，新检出用 `git clone --recurse-submodules`。

- 2026-10-23：第一期服务端实现完成并合进 leapgate-server main（`e20ca86`，321 个测试）。实施契约是 `server/LEAPGATE.md`，所有取值、取舍和实测依据都写在里面。经过八轮审查：前三轮查功能正确性；后五轮查资源上限，覆盖会合端口的帧长、并发和注册限流，21114 的连接保护和超时，地址簿、设备表、审计表的上限，WAL 上界和强制 checkpoint，以及会合主循环的独立连接池。最后一轮只剩说明性的小问题。还剩部署（选机器、迁移现网数据），由维护者安排。
- 2026-10-23：第三期第一项"TUN 下的局域网直连（多候选地址）"合进 main：leapgate-client `68e1259fa`（契约 `client/LEAPGATE.md` §3）、leapgate-server `bff8a17`（转发 `leapgate_local_addrs`）、proto 在 leapgate-cardo `375e2a3`（服务端线）/`a3d96d4`（客户端线）。经两轮审查和一轮复核，等维护者用两台开 TUN 的 Windows 端到端测。
- 2026-10-23：第三期实施契约写好（`docs/第三期实施契约/`：README 总述 + 四块），吸收了笔记 05（含 UU 远程解密日志）的借鉴项，经四路起草、三路交叉核对、逐块复核和三路终审。待维护者定 README §1.1 的 P-1~P-4，确认前不派 coder、不改两份 LEAPGATE.md。
- 2026-10-23 · 第三期契约的决定：P-1 UDP 打洞进第三期（只修前置障碍、做普通 UDP 打洞，改架构 §3.8"看回落率再定"）；P-4 局域网候选带 IPv6，范围是 ULA + 和控制端物理网卡同一 /64 的全局地址，私网 IPv4 优先；P-3 维护者没有偏好，主会话选 A（开 TUN 时不看 TCP 测出的 NAT 类型，有随机数和 UDP 端口就直接试打洞）。P-2 维护者定了原则而不是选项：**兼容性要考虑全面，不能假定任何运行环境，规则必须对所有环境都适用**（要么不管开不开 TUN 都生效，要么能判别清楚有没有开 TUN），不接受"要用户配环境规则"或"按设备主人授权"的做法。这条原则适用于整份契约。
- 2026-10-23 · 第三期顺序调整（维护者定）：先评估上游现成的 WebRTC/ICE 路径（UU 远程式的"候选全交换、客户端逐对实测"，上游 `hbb_common/src/webrtc.rs` 已有实现，开源服务端不转发它的信令），01 上报与认证、02 路由第二级照常推进；03 局域网判定与候选、04 UDP 打洞与 NAT 探测搁置，等评估结果再定（契约里按"UDP 出口证明"改写的 03/04 是评估不通过时的备选）。
- 2026-10-24 · 第三期 01 上报与认证合进 main：leapgate-server `e36ef89`、leapgate-client `a726a3daf`（`libs/leapgate` 版本 0.3.0）。经审查、修复、两轮复核；契约 01 已按最终实现同步（控制台只有 `kl` 按库重载、改库只由命令行做；注册先扣查库预算再按库重载；2xx 的 time 偏差超 30 秒才采信；根证书信系统库加内置 webpki，因为 Windows 根证书按需下载、rustls 不会触发）。测试机还没部署（WebRTC 评估期间跑的是评估版服务端）。
- 2026-10-24 · 第三期 02 路由第二级合进 main：leapgate-server `32a2060`、leapgate-client `49401a3f6`；proto `PunchHoleRequest.leapgate_from_id = 1000` 在 leapgate-cardo 服务端线 `76fe22e`（分支 `leapgate/server`；当时叫 `leapgate/lan-candidates`，远端现已没有这个分支）、客户端线 `2e37363`（分支 `leapgate/client`），两条线内容逐字一致。经四视角审查（没有正确性问题），补了测试；契约 02 按审查同步（`198.18/15` 对端不看耗时整轮作废、冒用 `leapgate_from_id` 能侧面推断对方相对延迟的口径）。
- 2026-10-24 · WebRTC 评估 S1 实测（笔记 06 §9.1）：两端开 mihomo TUN 时上游 WebRTC 路径必然失败，根因是 Windows 10054 让 webrtc-ice 的候选 socket 静默失效（对端报的 TUN 地址 198.18.0.1 在本机引来 ICMP，rustdesk-org/webrtc 的 `recv_loop` 吞掉错误退出）；Mac 关 TUN 后 ICE 选中 IPv6 host 对连通。维护者定只补测 S2/S3/S4（B 组）：S2 3/3、S3 4/4、S4 2/3 直连，失败同属上述机制。结论（§9.3）：ICE 思路在目标环境成立，上游实现不采用，按笔记 07 自研；自研必须关掉 socket 的 ICMP 报错（`SIO_UDP_CONNRESET`）、不收集 TUN/VPN 候选。
- 2026-10-24 · 维护者决定改名（Porta 相关域名几乎都被注册，以后发布没有官网可用）：**整体改**，仓库、crate、接口路径、请求头、签名前缀等协议字符串一起改，不保留 porta 当内部代号；新名字不限词源、短而好拼，要配中文名，域名不必非 .com。同日定名 **Leapgate，中文名跃门**（leap 一跃 + gate 门：一步跨过去的门，对应打洞直连，延续"门"的原意；候选和核实记录在私有仓库 `internal/命名候选-2026-10.md`）。改名找没有分支在跑的时候一次做完（02 合入后、自研 ICE 开工前）。改名的决定：仓库改成 `Leapgate`、`leapgate-server`、`leapgate-client`、`leapgate-cardo`（保留"门枢"的搭配）、`Leapgate-internal`，由主会话推到新名字的 Forgejo 仓库（首推自动建私有库），旧仓库由维护者之后删除或归档；协议字符串用全称（`/api/leapgate/v1/`、`Leapgate-Device-Auth`、`Leapgate-Server-Sig`、`leapgate-device-v1`、`leapgate-server-v1`、`leapgate-api-caps`、保留前缀 `leapgate-`、客户端类型 `leapgate`、proto 字段 `leapgate_*`）；现行文档（AGENTS、架构、实施说明、契约、脚本）全改，带日期的调研笔记和决策原文保留 Porta，开头注明是当时的工作名。本地总目录 `WorkSpace\Porta` 暂不改名（worktree 和会话路径都依赖它）。
- 2026-10-24 · 维护者表示"如果进度快，直接用 Porta 自己做的 ICE 也行"（不依赖上游 webrtc-rs）。主会话安排：上游 WebRTC 评估照常完成（临时分支已做好，结果用来回答自研设计的关键问题），同时出自研 ICE 的设计方案（`docs/research/第三期/07-Porta自研ICE设计.md`），给维护者确认后再定走哪条。
- 2026-10-24 · 第三期 01、02 端到端（契约 01 §6.3、02 §6.3）在 Linux 测试机上走完：两台免安装运行的 Leapgate Windows（A、B）、同机两台 hbbr 中继、Mac 上的官方 RustDesk 1.5.0 当原版客户端。01 第 1~8 步全部符合（第 7 步另起一份第一期服务端，退回旧接口）；02 第 1~4、6 步符合；第 5 步（作废规则）客户端一侧符合（`probe round dropped … not on a physical adapter`），旧测量过期后选路是 `rtt_a`，但发现服务端缺口：Leapgate 心跳不带 `probes` 时不清旧测量，要等 15 分钟过期，和契约"作废时当场清掉"不符。修复合进 leapgate-server `71b753e`（总仓库 `29f17ec`，两路审查、两条变异验证、359 个测试通过），已部署测试机并线上验证：B 关 TUN 测一轮、测量写入后再开 TUN，B 作废那一轮后 3 秒内（下一次心跳）服务端就删掉了它的测量，`route test` 当场回到估计。偏离契约原文的做法：02 第 4 步用测试机 iptables 挡 A 到一台中继（A 的 Windows 防火墙是关的）；02 第 5 步改由 B 开 TUN，期望值相应是 `rtt_a`；01 第 6~8 步放在 A 上做（在远端的 B 上改错 Key 会断开远程会话、改不回来）。
- 2026-10-24 · 仓库名统一成全小写（维护者定）：总仓库 `Leapgate` → `leapgate`、私有仓库 `Leapgate-internal` → `leapgate-internal`，和 `leapgate-server`、`leapgate-client`、`leapgate-cardo` 一致；品牌写法 Leapgate 只用在文档和界面里。改名前的五个 Porta 仓库已归档。
- 2026-10-24 · 自研 ICE 的决定（维护者拍板笔记 07 §9）：Q1 自研，不复用 webrtc-ice 0.13；Q2 被控端的 host 候选给所有能让服务端转发 OFFER 的请求方，只给物理网卡地址，IPv6 每个 /64 一个临时地址；Q3 检查内核手写精简版，`is` 只当差分测试的参照；Q4 契约 03、04 按笔记 07 §7.3 收缩（复用 token 格式、令牌桶、双地址族枚举；04 的 UDP 打洞整套和 03 的 IPv6 局域网候选不做，04 §4.4 降为可选）；Q5 **MVP 一次做到 srflx**（含服务端 STUN 和反射地址证明，不按笔记推荐的"MVP 只做 host"）；Q6 服务端转给被控端的 OFFER **既签名又加密**（用被控端注册的设备公钥加密，链路上看不到控制端的局域网地址；笔记推荐只签名）；Q7 MVP 里私网 IPv4 优先于 IPv6，有了续选再改；Q8 Tailscale、ZeroTier 这类 VPN 网卡不收集；Q9 不用定，S3 实测开 TUN 时绑物理网卡地址的 socket 发往公网仍走物理网卡（笔记 06 §9.2）。下一步写自研 ICE 的实施契约、改架构 §3.8"WebRTC 不开"。起草中又定了两条（维护者按推荐）：P-A 控制端在信令连接上补报一条 ICE 结果（只作统计、不认证），服务端记进新表，免得中继回落率失真；P-B 加密 OFFER 复用设备已锁定的 Ed25519 密钥转成 X25519，不另生成密钥（libsodium 允许，记为已知取舍）。
- 2026-10-24 · 第三期实施契约 05（自研 ICE，`docs/第三期实施契约/05-自研ICE.md`，约 1700 行）写好：六路在当前 HEAD 重新读码，分段起草（协议 → 服务端/客户端/关联文档 → 整合），五路交叉核对（服务端、客户端代码事实，协议与安全，决定与原则，篇幅）提出的 72 条全部核实后接受，再复核一轮修了 7 条小问题；测试向量经两种独立实现逐字节复算。和笔记 07 不同的主要几处：控制端竞速自己写（上游 `race_transports_prefer_webrtc` 因 future 不是 Send 用不了），ICE 失败一律返回上游结果；04 的 token 和令牌桶从没实现过，由 05 实现；网卡过滤补 Wi-Fi Direct，Hyper-V 不按名字排、改为出候选的网卡必须有默认网关；被控端配了 IP 白名单时不做 ICE；信令连接整段套 3 秒超时。工作量约 20 人天。README、01、03、04、architecture 同步改了带日期的更新说明。维护者同日确认契约，按 README §2 D 步开工：先做只含 proto 的提交（两条 cardo 线各一份），再服务端、客户端并行（两边都在 `p3/ice` 分支上做）。
- 2026-10-24 · 镜像到 GitHub（维护者定）：自建 Forgejo 开着强制登录，外人看不到源码，不满足"全部公开"和 AGPL 第 13 条，所以四个公开仓库另推一份到 GitHub `Ogannesson/leapgate`、`leapgate-server`、`leapgate-client`、`leapgate-cardo`（普通仓库，不是 fork），服务端 `[api] source_url` 改指 GitHub。GitHub 上关掉了 Actions（构建不走 GitHub Actions，§3.11）、Wiki、Projects，三个代码仓库关掉 Issues（问题统一提到总仓库）；客户端删了上游的 `.github/FUNDING.yml`（会显示指向 RustDesk 的赞助按钮）。服务端、客户端的 README 放在 `.github/README.md`，不动上游的 `README.md`；cardo 的 README 在 main 上。同日按维护者要求把四个公开仓库的全部提交说明改写成英文、重写历史并强推 Forgejo：作者、日期、文件内容不变，子模块指针和说明里引用的哈希按对照表换成新的，上游基点（873230e、bd92623、5d52530）不变，文档里引用的旧哈希已统一替换（历史文件里仍是旧哈希）。重写前的全部分支打包在维护者本机 `~/leapgate-history-backup-20261024/`（含新旧哈希对照表），各仓库另留 `refs/backup/pre-rewrite/*`（cardo 的在 `server/libs/hbb_common` 那份克隆里）。
- 2026-10-25 · 第三期 05 自研 ICE 合进 main：leapgate-server `d564e30`、leapgate-client `753c9e7e7`（`libs/leapgate` 0.3.1）；proto 在 leapgate-cardo 客户端线 `f6309f1`、服务端线 `d08e8ca`。服务端 S1~S3、客户端 C1~C4 写完后各做三路审查加变异验证、两轮修订，复核无遗留；和 is 0.11 的一次性差分对照没有疑似 bug；§6.3 的 netns 真实 NAT 测试（总仓库 `scripts/linux/ice-netns.sh`）6 组 × 3 次全过。实施中维护者又定了两条：**F1** 会合服务器是域名时，客户端从物理网卡问那块网卡自己的 DNS 服务器，拿不到才退回系统解析并丢掉 `198.18/15` 这类地址（mihomo fake-ip 下系统解析给假地址，从物理网卡发的 Binding 收不到回包，srflx 全部失效，维护者本机实测）；**F2** 上游的 `enable-udp-punch`、`enable-ipv6-punch` 都关时不做 ICE。契约 05 已按最终实现同步，§6.4 加了第 9 步 (e)（F2）和第 10 步（F1）。下一步是维护者按 05 §6.4 端到端验收。
- 2026-10-25 · 端到端验收改成 agent 无人值守跑（维护者要求：每次等他手动测，他一离开流程就停住）。端点脚本和循环驱动在 `scripts/e2e/`，带具体机器、ID、测试密码的运行手册在私有仓库 `internal/e2e-运行手册.md`，测试环境（台式机经一次性计划任务起程序、另一台跨网的笔记本经 telechir 操控、同局域网的 Proxmox 测试虚拟机）记在 `internal/environment.md`。维护者的手动测试以后只当最后抽查。05 §6.4 的跨网部分第一轮已跑完，详见手册。
- 2026-10-25 · 第三期 02 修订（开 fake-ip TUN 时中继测速每轮作废，契约 `02a-修订草案-TUN下的测速.md`，维护者选方案甲）合进 main：leapgate-client `85f71c756`、leapgate-server `d830ac2`（只改 LEAPGATE.md）。测速连接改成和真实中继连接走同一条路（不绑网卡、系统解析、进 TUN），连上后等 1.5 秒再发 1 字节空帧，量到 hbbr 静默关连接的时间，正好是真实中继路径的一个往返；三条作废规则删了两条，不用判断开没开 TUN。待端到端（02 §6.3）。

## 已定的架构决策（详细理由在 `docs/architecture.md`）
- 2026-10-22 · 兼容原版 RustDesk 客户端只在最初几个版本提供；兼容带来的代价（上报接口不认证、靠 404 之类的约定判断能力、远程清中继的变通等）要在几个迭代内移除，不长期背着。退出机制见 §3.1。
- 2026-10-22 · 界面默认留 Flutter；新界面轨道开工前先做 3~5 天的 Slint 原型（标准见 §3.4：真实解码输出 1080p60/4K60、hwcodec 的 BGRA D3D11 纹理零拷贝进 wgpu、多窗口/中文输入法/高 DPI），过了且桌面优先才换。
- 2026-10-22 · 客户端跟随上游正式版本合并（merge 不 rebase），服务端硬分叉。仓库：`leapgate` 是总仓库，用子模块挂 `client/`（`leapgate-client`，rustdesk fork）和 `server/`（`leapgate-server`，rustdesk-server fork）；hbb_common 的 fork 叫 `leapgate-cardo`（拉丁语"门枢"，2026-10-22 定名），挂在两者的 `libs/hbb_common` 位置，crate 名不改。全部公开、AGPL-3.0（§3.2）。
- 2026-10-22 · 服务端是单进程 `leapgate-server`（hbbs 硬分叉，内置 API 和路由策略，SQLite，HTTP 用 axum），hbbr 用原版、统一配 `-k`；第一期只用命令行管理，不做网页后台（§3.5）。
- 2026-10-22 · 地址簿只做新版（个人簿 + 共享簿，三级权限，按"多本 + 权限"建模，兼容接口只是外壳）；共享簿里客户端明文上传的密码加密后落盘；共享簿用命令行管理（§3.6）。同日补定：个人簿的密码哈希也加密落盘（它能直接登录对端，等同明文）；"读写"权限可以删簿内设备和标签（客户端对读写和完全控制显示同样的菜单）；Leapgate 也做用户组，共享簿可以授权给组。
- 2026-10-22 · 智能路由：代价 =（发起方到中继 + 被控端到中继的延迟）× 中继权重。第一级只改服务端，用覆盖全球的 GeoIP/ASN 库估算延迟（推荐 DB-IP Lite，备选 MaxMind GeoLite，上线前用各大洲真实 IP 对比），不手写区域表；第二级由 Leapgate 客户端测速上报，发起方测量随打洞请求带上（新 proto 字段）；固定中继在服务端按设备配置；权重先手工固定（§3.7）。
- 2026-10-22 · 直连：第一期开 IPv6 打洞、不开 UDP 打洞（现版 hbbs 会丢 UDP 来的 `PunchHoleSent`），服务端记录中继回落率；UDP 打洞（防伪造随机数）修不修到第三期看数据再定；WebRTC 不开（§3.8）。同日读码更正：IPv6 打洞的开关是控制端本地的 LocalConfig 选项，心跳策略改不到，被控端也不检查它；原版 hbbs 还不转发 IPv6 地址。所以第一期由 leapgate-server 补转发，原版客户端在控制端手动勾选"Enable IPv6 P2P connection"，Leapgate 客户端第二期默认打开。
- 2026-10-22 · leapgate-server 第一期必须实现会合端口上的 TCP 密钥交换（KeyExchange）：原版 hbbs 没有，配了 key 又登录过 API 的客户端连它每次都在 18 秒后失败。
- 2026-10-22 · Exit Node：出口是设备能力（新权限，和 `enable-tunnel` 分开，默认关），服务端登记出口目录，只列给主人和被授权的人；第四期做 SOCKS5/HTTP CONNECT 应用出口，复用多路复用端口转发、放开 `on_open` 的目标校验，只支持 TCP，域名交给被控端解析；默认禁止访问被控端局域网和本机，按网段放行；允许走中继并在界面标明；Leapgate 被控端拒绝明文裸管道；全局出口（编排 Tailscale/Headscale）不排期；不做自研 VPN（§3.9）。
- 2026-10-22 · 平台、签名、构建：第一阶段只做 Windows（控制端和被控端）；前两期不签名，驱动名不改、沿用上游已签名的驱动；服务端在 Linux 测试机构建；客户端先本机手工搭、固化成 PowerShell 脚本，稳定后挂 Forgejo Actions（自己的 Windows 机器当 runner），不用 GitHub Actions；产物发 Forgejo Releases（§3.11）。
- 2026-10-22 · 不支持 Windows 7，只支持 Windows 10 及以上；构建链因此不必照搬上游为 Win7 钉的旧版 Flutter、Rust 1.75 和自编引擎。
- 2026-10-22 · 第二期编上游现有界面的 Flutter 路线按 B → C → A 依次试：B 官方 Flutter 3.44.9 + 上游源码补丁脚本；C 自编 3.44.9 引擎只打多窗口崩溃那一处补丁；A 照搬上游 x64 的 3.24.5 + 自编引擎（`docs/research/第二期客户端/03`）。Windows 客户端只能在 Windows 上构建，在维护者本机做。
- 2026-10-22 · 品牌：主界面的"Powered by RustDesk"用内置选项隐藏，关于页保留上游版权行并注明"基于 RustDesk"；`librustdesk.dll` 改名为 `libleapgate.dll`（接受每次合并上游多几处冲突）。
- 2026-10-23 · 第三期设计（依据 `docs/research/第三期/01~03`）：
  - Leapgate 客户端的心跳、sysinfo、审计改走新路径 `/api/leapgate/v1/`，客户端在上游代码里只加 2 处挂钩，原版客户端照走旧接口。
  - 设备用已有的 Ed25519 私钥（注册时上报的 `pk` 对应的那把）签每个请求，签名放请求头。服务端第一次验签通过就自动锁定这把公钥，之后换公钥的注册回 `UUID_MISMATCH`，命令行可以重置。锁定后的设备再发不签名的上报一律拒收。
  - 路由第二级：候选中继放在 Leapgate 心跳响应里下发；设备每 5 分钟测一次到各中继的 TCP 建连耗时，随心跳上报；打洞请求加"发起方自己的 ID"（新 proto 字段），服务端拿这个 ID 去查发起方上报过的测量值。这偏离了方案 §3.7 原文"把测量值放进打洞请求"的写法，原因是发起连接的是界面进程，测量结果在服务进程里。
  - 服务端用会合私钥给 Leapgate 心跳响应签名，客户端配了 Key 就强制验签；Leapgate 路径不理会"接受无效证书"选项。
  - 明确不做：给 UDP 注册加签名（留到退出兼容前）、公钥轮换、私钥加密存放。

## 公开与内部的边界
- 公开仓库里只放适合开源的通用内容：方案、调研、代码、构建脚本。
- 现网部署（服务器 IP、内部域名、机器配置）、立项讨论、待办和内部流程，只写进 `internal/`，推到私有仓库，不进公开仓库，也不写进公开文档。公开文档需要提到现网时，用抽象描述（例如"现有部署里被控端写死了一个中继"）。
- 提交前用 `git diff --cached` 看一眼，别把内部信息带进公开仓库。

## 上游参考源码
- 上游 clone 在仓库内的 `upstream/`（`rustdesk`、`rustdesk-server`、`hbb_common`、`rustdesk-api`、`hwcodec`），已在 `.git/info/exclude` 排除，不进提交。都是 `--filter=blob:none` 部分克隆，`git log --stat` 这类命令会按需下载 blob，比较慢。
- 文档里引用上游代码写成 `仓库@提交:路径` 加函数名；`upstream/` 更新到新版本后，引用要重新核对。

## 上游与许可证
- 客户端 `rustdesk/rustdesk`、服务端 `rustdesk/rustdesk-server`（hbbs/hbbr），都是 **AGPL-3.0**（2026-10-22 核对两个仓库的 LICENSE）。Leapgate 作为衍生作品也是 AGPL-3.0，所有仓库公开。
  - 把客户端发给别人装：要同时提供对应源码。
  - 别人通过网络使用改过的服务端（AGPL 第 13 条）：要向这些用户提供源码。仓库公开就满足。
  - 不能做成闭源产品分发。
- 名字和图标：没找到 RustDesk 官方商标政策，社区 fork 通常改名、换图标、换配置目录和服务名，避免和官方版混淆、共用状态。Leapgate 分发的构建里不出现 RustDesk 的名字和标志。

## 约定
- 项目说明与知识只写本文件，不建 CLAUDE.md。
- 提交用 agent 自签。
- 提交说明的语言（维护者 2026-10-24 定）：四个公开仓库（leapgate、leapgate-server、leapgate-client、leapgate-cardo）一律英文；私有的 `internal/`（leapgate-internal）用中文。文档本身仍是中文。
- 推送：Forgejo 是主远端（`origin` 的 fetch 地址），GitHub 是公开镜像；各仓库和 cardo 的各个克隆都把 `origin` 配成两个 push 地址（先 Forgejo、后 GitHub），一次 `git push` 两边都推。cardo 在 GitHub 上要推 `main`、`leapgate/server`、`leapgate/client` 三个分支。新检出时照此补上：`git remote set-url --add --push origin <Forgejo 地址>`，再 `--add --push origin https://github.com/Ogannesson/<仓库名>.git`。
- 子模块工作区用 LF：Windows 上检出后在各子模块里设 `core.eol=lf`、`core.autocrlf=false`。sqlx 迁移文件的校验和按字节算，CRLF 检出编出来的程序会和 Linux 构建的对不上。
