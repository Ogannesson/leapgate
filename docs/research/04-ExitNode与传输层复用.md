# 04 · Exit Node 与传输层复用评估

> Porta 是当时的工作名，2026-10-24 改名为 Leapgate（跃门）。

调研日期：2026-10-22。只读调研，未编译、未改代码。
源码版本：客户端 `rustdesk@bd92623`，服务端 `rustdesk-server@873230e`。
标注：**[码]** = 读代码确认；**[推]** = 推测或估算，未实测。

> 先说一个容易看错的地方：任务说明里写的 `libs/hbb_common/protos/message.proto` 在 bd92623 已经不在那里了。commit `b50fde69`（#16107）把协议和部分模块挪到了新 crate `libs/base`，现在的路径是 `libs/base/protos/message.proto`。`libs/hbb_common/protos/` 下只剩 `rendezvous.proto`。传输代码（tcp/stream/websocket/webrtc/udp）还在 `libs/hbb_common/src/`。**[码]**

---

## 1. 端口转发（TCP 隧道）现状

### 1.1 两套实现并存
上游在 2026-09-05 合入了 PR #16062「port forward shared conn」（https://github.com/rustdesk/rustdesk/pull/16062 ，merge commit `3fc11c0f`），所以现在有两条路径：

| | 旧路径（legacy 裸管道） | 新路径（mux 多路复用，默认开） |
|---|---|---|
| 会话数 | **每条本地 TCP 连接开一个独立的 RustDesk 会话**（完整走一遍打洞/中继 + 登录） | **每个映射一个会话**，映射下所有本地连接是这条会话里的 channel |
| 客户端入口 | `rustdesk@bd92623:src/port_forward.rs` `fn connect_and_login` → `fn run_forward` | `src/port_forward.rs` `fn establish_tunnel` / `fn connect_and_login_mux`，`src/port_forward_mux.rs` `mod tunnel`（`Tunnel::claim`、`TunnelHandle::open`、`fn tunnel_loop`） |
| 被控端入口 | `src/server/connection.rs` `fn connect_port_forward_if_needed`（登录时就 `TcpStream::connect`）→ `fn try_port_forward_loop` | `src/server/port_forward_mux.rs` `PortForwardMux::handle` / `fn on_open` / `fn run_controlled_channel` |
| 线上格式 | 登录后 `stream.set_raw()`，**直接透传原始字节** | 普通 protobuf `Message`，union tag 33 `PortForwardChannel{open/opened/data/close/window_update}` |
| 加密 | **登录后不加密**（见 1.3） | 沿用会话的 secretbox 加密 |
| 开关 | 控制端 `enable-port-forward-mux=N`、或对端不支持 | 默认开；对端 PeerInfo 里 `Features.port_forward_mux` 为真才走 |

全部 **[码]**。`fn listen` 里的 `Claim::Muxed / Claimed / Legacy` 三个分支说明了怎么选路径：第一次 accept 时探测，之后的连接加入同一条隧道。

### 1.2 关键事实
- **只支持 TCP。** 两条路径的被控端都只调 `TcpStream::connect`（`connection.rs` `fn connect_port_forward_if_needed`、`server/port_forward_mux.rs` `fn run_controlled_channel`）。协议里没有 UDP 帧。**[码]**
- **目标地址**：
  - 由控制端在登录时指定（`LoginRequest.union = PortForward{host, port, multiplex}`）。被控端只做规范化：host 为空就当 `localhost`，`"RDP":0` 换成 `localhost:3389`（`Connection::normalize_port_forward_target`）。**被控端不限制目标必须是本机**，局域网里任意 `host:port` 都能连。**[码]**
  - 协议层面，mux 的 `PortForwardOpen` 每个 channel 都带 `host`/`port`。但被控端 `fn on_open` 硬性要求 `addr == self.login_target`，不一致就回 `"Port forward target not authorized"`。PR 说明里写了原因：click-to-approve 和 2FA 弹窗展示的是登录时的目标，审批的单位是"一次登录 = 一个目标"。**[码]**
  - 结论：**线格式已经支持每个 channel 带不同目标，只是被控端的授权策略锁死了。** 要做"动态目标"，协议不用改，改的是这一处授权判断和审批时展示给被控端的内容。
- **权限开关**：被控端选项 `enable-tunnel`（`keys::OPTION_ENABLE_TUNNEL` → `Permission::tunnel`）。登录时检查一次（`connection.rs` 登录分支里报 `"No permission of IP tunneling"`），mux 模式下每次 `open` 再查一次（`fn handle_port_forward_channel` 传入的 `tunnel_permitted` 闭包）。**[码]**
- **mux 的参数**（`src/port_forward_mux.rs` 顶部常量）：每个 channel 初始窗口 64 KiB（`INITIAL_WINDOW`），之后 256 KiB（`CHANNEL_WINDOW`），单帧最大 64 KiB（`MAX_FRAME`），每条隧道最多 256 个 channel（`MAX_CHANNELS`），发送队列 128 帧（`DATA_QUEUE_FRAMES`）。流控是信用窗口，靠 `window_update` 补充额度。**[码]**
- **RDP 隧道**：本地端口传 0 就是 RDP 模式。`fn listen` 在 `127.0.0.1` 上随机监听一个端口，然后 `fn run_rdp` 起 `mstsc /v:127.0.0.1:<port>`，用户名和密码从环境变量 `rdp_username` / `rdp_password` 读。被控端的目标是 `localhost:3389`。ConnType 用 `ConnType::RDP`，其余流程和普通端口转发一样。**[码]**
- **保活**：legacy 模式下被控端认为 `port_forward_socket` 已授权，就不发 `TestDelay`（`connection.rs` 约 1188 行的条件）；mux 模式下会照常发。**[码]** 所以 legacy 隧道走 hbbr 时，空闲 30 秒就会被 hbbr 的空闲超时切断（见 §3）。**[推]**（和 Discussion #5293 里用户反映的"空闲约 35 秒 TCP 隧道自动关闭"吻合。）

### 1.3 安全发现：legacy 端口转发登录后是明文
- `FramedStream::set_raw`（`libs/hbb_common/src/tcp.rs`）执行 `self.2 = None`，把 `Encrypt` 丢掉了；`WsFramedStream::set_raw`（`websocket.rs`）同样是 `self.encrypt = None`。WebRTC 的 `set_raw` 什么也不做，仍有 DTLS 加密。**[码]**
- legacy 路径在客户端 `connect_and_login` 末尾和 `run_legacy` 里，以及被控端 `try_port_forward_loop` 开头，都调了 `set_raw()`。所以**登录完成后，隧道里的字节在 TCP/KCP/WebSocket 上都是明文**，走中继时 hbbr 能看到原文。**[码]**
- mux 路径不调 `set_raw`，数据帧走 `stream.send(&msg)`，是加密的。**[码]**
- 对 Porta 的影响：**Exit Node 只能建在 mux 路径上**，legacy 路径要么删掉，要么不让它承载 exit 流量。

---

## 2. 传输层

### 2.1 通道形态
控制端 `Client::start` → `Client::_start` → `fn _start_inner` / `fn connect`（`rustdesk@bd92623:src/client.rs`）。端口转发、RDP、远控、文件传输共用这一套建连逻辑，只是 `ConnType` 不同。**[码]**

| 形态 | 代码位置 | 说明 |
|---|---|---|
| TCP 直连（局域网/IP 直连） | `connect_tcp_local`，`check_port(peer, RELAY_PORT+1)` | 被控端监听 21118 等端口 |
| TCP 打洞 | `tcp_punch_allowed`、`request_allows_tcp_punch` | 选项 `enable-tcp-punch`；其它直连方式都被关掉时它是兜底 |
| UDP 打洞 + KCP | `fn udp_nat_connect` → `KcpStream::connect`（`src/kcp_stream.rs`，依赖 `kcp_sys`） | KCP 流被包成 `Stream::Tcp(FramedStream)`，上层看不出区别。默认是 turbo 档，不做拥塞控制（`apply_kcp_config` 里 `get_kcp_cc_enabled` 才开 nc=0） |
| IPv6 打洞 | `get_ipv6_punch_enabled`、`get_ipv6_socket` | |
| WebRTC | `libs/hbb_common/src/webrtc.rs`，`race_transports_prefer_webrtc` | 主 crate 的 Cargo.toml 给 hbb_common 开了 `features=["webrtc"]`；用 DTLS 加密，SCTP data channel |
| hbbr 中继 | `fn request_relay` / `fn create_relay` | 打洞失败时，或 `force-always-relay` 打开时走 |
| WebSocket | `libs/hbb_common/src/websocket.rs`，`use_ws()` | 连 hbbs/hbbr 的 21118/21119，或经反向代理 |

各个 `enable-*` 选项都按 `option2bool` 解析：值不是 `N` 就算开。**[码]**

### 2.2 加密
`Client::secure_connection`（`src/client.rs`）的流程：**[码]**
1. 被控端发 `SignedId`：自己的 ed25519 身份签名、临时 curve25519 公钥，WebRTC 时还有 DTLS 指纹，外面用 hbbs 的 `RS_PUB_KEY` 链校验。
2. 控制端生成随机对称密钥，用 `box_`（curve25519-xsalsa20-poly1305）封给对方，放进 `PublicKey` 消息。
3. 双方 `set_negotiated_key`。`kx_version=1` 时用 `generichash` 按方向拆成两把密钥，并把握手 transcript 混进去（`tcp.rs` `Encrypt::new_split`）；`kx_version=0` 时两个方向共用一把。
4. 之后每条消息都是 `secretbox::seal`（XSalsa20-Poly1305），nonce 是 64 位递增计数器（`FramedStream::get_nonce`）。
5. WebRTC 不再叠 secretbox，只靠 DTLS，并校验 DTLS 指纹和签名身份是否绑定。

hbbs 公钥对不上或者没配时，会**回退成不加密**（`"pk mismatch, fall back to non-secure"`）。客户端会弹 `confirm_insecure_connection` 让用户确认；IP 直连不弹。**[码]**

### 2.3 分帧
`libs/hbb_common/src/bytes_codec.rs`：变长头 1~4 字节，低 2 位表示头长，其余位是长度（`len << 2 | n`）。raw 模式下不分帧。`set_max_packet_length` 在认证前把上限压低；mux 协商成功后，`cap_packet_size` 把 TCP 的上限设成 `MAX_PACKET = 128 KiB`。**[码]**

### 2.4 能不能承载任意字节流，瓶颈在哪
- **能。** mux 已经是一个"加密的、带流控的多路 TCP 字节流"通道，Exit Node 的应用层代理可以直接复用。**[码]**
- 可能的瓶颈：**[推]**
  1. **单 channel 窗口 256 KiB**，单条 TCP 流的吞吐上限约为窗口除以 RTT。RTT 30 ms 时约 8.7 MB/s（≈70 Mbit/s），RTT 100 ms 时约 2.6 MB/s（≈21 Mbit/s），RTT 200 ms 时约 10 Mbit/s。大文件下载、测速这类单流场景会明显受限，要调大窗口，或者改成按 BDP 自适应。
  2. **整条隧道只有一个底层流**：TCP 上有队头阻塞，丢一个包所有 channel 一起卡；如果底层是 TCP，再在里面套被代理的 TCP，就是 TCP-over-TCP。KCP 和 WebRTC 底层没有这个问题。（2026-10-27 更正：KCP 也是可靠有序流，同样有队头阻塞；SOCKS/CONNECT 是应用层代理，被代理的 TCP 在控制端本地终结，不构成 TCP-over-TCP。见 `docs/research/第四期/03-设计决策清单.md` E4。）
  3. **单任务串行**：客户端 `tunnel_loop` 和被控端主循环都是一个 select 循环，加解密和收发在同一个任务里串行做，高带宽时可能单核吃满。
  4. **KCP turbo 不做拥塞控制**：长时间大流量时可能挤占链路、丢包放大。
  5. **超时**：会话 30 秒没有收到数据就断（`connection.rs` 的 `SEC30`），mux 有 TestDelay 心跳，问题不大。

---

## 3. hbbr 中继限速（`rustdesk-server@873230e:src/relay_server.rs`）

全局默认值（单位注意：代码里的 "Mb" 是 1024×1024 bit）：**[码]**

| 参数 | 默认值 | 作用 |
|---|---|---|
| `SINGLE_BANDWIDTH` | 128 Mb/s | 每条中继连接的限速，**收发两个方向合用一个 limiter** |
| `TOTAL_BANDWIDTH` | 1024 Mb/s | 整个 hbbr 所有连接合计 |
| `LIMIT_SPEED` | 32 Mb/s | 黑名单 IP 或"被降级"连接的限速 |
| `DOWNGRADE_START_CHECK` | 1800 s | 连接持续 30 分钟后开始检查是否降级 |
| `DOWNGRADE_THRESHOLD` | 0.66 | 平均速率超过 0.66 × SINGLE_BANDWIDTH（约 84 Mb/s）就永久降到 32 Mb/s |
| 空闲超时 | 30 s | `fn relay` 里 `last_recv_time.elapsed() > 30` 就 bail |

- 这些参数可以通过启动参数或环境变量设置（`common.rs` `fn get_arg_opt` 会先查环境变量的几种写法），也可以在运行时通过管理命令（`check_cmd`：`ls`/`tb`/`sb`/`dt`/`t`）修改。**[码]**
- hbbr 只按 uuid 配对，加上可选的 `licence_key` 校验，然后双向搬字节，不解析内容。两端都不是 WebSocket 时设成 raw 模式（`fn make_pair_`）。**[码]**

**对 Exit Node 的影响：** **[推]**
1. 走中继时，Exit 流量全部经过 hbbr，带宽受限于 hbbr 所在 VPS 的线路：现网的中继都是小水管 VPS，还按流量计费。上面的默认限速对 Exit 场景偏紧，尤其是"持续 30 分钟高速就降到 32 Mb/s"这条。Porta 自己的 hbbr 要么调参，要么对隧道类连接单独处理。
2. 中继路径多一跳，RTT 变大，又会进一步压低 §2.4 里单 channel 的窗口吞吐。
3. 30 秒空闲超时：mux 有心跳，问题不大；legacy 会被切断。
4. 加密：mux 走中继时 hbbr 看到的是密文；legacy 走中继时 hbbr 看到的是明文（§1.3）。

---

## 4. 三条实现路径评估（只评估，不选）

### a. 应用层代理：控制端本地开 SOCKS5/HTTP，被控端代为连接目标

- **能复用**：mux 隧道几乎整套能用——`PortForwardChannel` 的线格式本来就是每个 channel 带 host/port，还有流控、加密、建连和登录流程（`connect_and_login_mux`），以及 `enable-tunnel` 权限。**[码]**
- **要新写**：**[推]**
  - 控制端：一个 SOCKS5 服务端（CONNECT 命令；要支持 UDP ASSOCIATE 就得加 UDP 帧）和 HTTP CONNECT 服务端，把每个代理请求的目标填进 `TunnelHandle::open(host, port, …)`。现在 `open` 用的是映射固定的 `remote_host`，改成每次传入即可。
  - 被控端：`on_open` 的授权从"目标必须等于登录目标"改成"登录时声明的是 Exit 模式，就按出口策略放行"，比如是否允许访问被控端的局域网、端口黑白名单。登录协议加一个 Exit 模式标记，click-to-approve 界面上要写明"允许对方经本机上网"。
  - DNS：SOCKS5 支持域名类型（ATYP=3），可以把域名直接传给被控端解析，天然避免 DNS 泄漏。
  - UDP（QUIC/HTTP3、游戏、DNS over UDP）：需要新增 UDP channel 帧；不做的话，浏览器会自动退回 TCP。
  - 调大单 channel 窗口，或改成自适应窗口。
- **系统权限**：两端都不需要管理员或 root。控制端只是监听 127.0.0.1 端口；被控端只发起出站连接。**[推]**
- **平台难点**：**[推]**
  - 只有配了代理的应用才走出口，做不到"全局"。Windows 可以写系统代理（WinINet/注册表），但很多程序不认；macOS 可以通过 `networksetup` 设置系统代理；Android 只能给单个应用或 Wi-Fi 配代理，想全局就要 VpnService 加 tun2socks，那就变成了 b 的一部分。
  - 被控端是 Android 时，后台保活和出站连接都可以做；用 Flutter 的那套 Rust 服务端即可。
- **对 hbbr 的依赖**：和普通远控一样，能直连就直连，打不通就走中继，受 §3 的限速影响。
- **工作量**：小到中。核心改动集中在 `port_forward_mux.rs`、`server/port_forward_mux.rs`、登录和审批，再加上 SOCKS/HTTP 服务端（有现成 crate，如 `fast-socks5`；hbb_common 已经依赖 `tokio-socks`，但那是客户端）。**[推]**

### b. 网络层 VPN：控制端虚拟网卡 → IP 包经 RustDesk 通道 → 被控端 NAT 出去

- **能复用**：会话建连、加密和中继通道；mux 可以开一个专门的"包通道"，或者新加一种 `Message` 类型承载 IP 包。**[推]**
- **要新写**：**[推]**
  - 控制端：tun 设备（Windows 用 wintun，macOS 用 utun 或 NetworkExtension，Android 用 VpnService，Linux 用 /dev/net/tun），加上路由表管理：默认路由、排除到 hbbs/hbbr/被控端公网 IP 的路由以免回环、DNS 设置、IPv6 处理。
  - 被控端，二选一：
    - (i) 系统 NAT：Linux 开 ip_forward 加 MASQUERADE；Windows 要 ICS 或 WinNAT；macOS 用 pf。都要管理员权限，各平台写法完全不同。
    - (ii) 用户态协议栈（smoltcp 或 lwIP，即 tun2socks 的思路）：在被控端把 IP 包还原成 TCP/UDP 流，再用普通 socket 发出去。不需要管理员权限，也跨平台，但要自己维护一套用户态 TCP 栈。
  - 包是不可靠传输的语义：底层是 TCP 时就成了 TCP-over-TCP，丢包和延迟会互相放大。最好让包通道只走 KCP 或 WebRTC 的不可靠/无序通道；但现在的 KCP 是可靠流，要改。
- **系统权限**：控制端要安装虚拟网卡驱动或 VPN 授权——Windows 需要管理员加 wintun 驱动；macOS 要签名的 Network Extension（需要 Apple 开发者账号和公证）或 root；Android 要用户点同意 VpnService。被控端走 (i) 要管理员，走 (ii) 不用。**[推]**
- **平台难点**：**[推]**
  - Android 同一时间只能有一个 VpnService，和 Tailscale 等 VPN 互斥。
  - macOS 的 NetworkExtension 必须走 App/System Extension 的分发和签名流程，个人项目门槛高。
  - Windows 还要考虑和其它 VPN 抢路由、DNS 泄漏、IPv6 泄漏。
  - 等于自己重写半个 WireGuard 或 Tailscale 客户端，而且没有它们成熟的打洞和路由逻辑。
- **对 hbbr 的依赖**：同 a；全局流量全部经过中继时，对带宽的压力最大。
- **工作量**：大，四个平台各一套。**[推]**

### c. 和 Tailscale/Headscale 结合

**Tailscale exit node 的工作方式**（查证日期 2026-10-22）：
- https://tailscale.com/kb/1103/exit-nodes （页面写 Last validated Dec 15, 2025）：exit node 就是对外发布默认路由 `0.0.0.0/0`、`::/0`。需要三方同意：设备自己 advertise，管理员批准，使用方显式选择。支持 Linux、macOS、Windows、Android、iOS、tvOS 作为出口，要求 v1.20 及以上。默认使用方访问不了自己的本地网络，需要 `--exit-node-allow-lan-access`。Linux 做出口要开 IP forwarding。
- https://headscale.net/stable/ref/routes/ ：Headscale 支持 subnet router 和 exit node，路由要在控制端批准（`headscale nodes approve-routes`），也可以在策略里用 `autoApprovers` 自动批准。
- https://tailscale.com/kb/1244/tsnet （Last validated Jul 24, 2026）：tsnet 是 Go 库，把 Tailscale 嵌进程序里，用用户态 TCP/IP 栈，每个程序实例是 tailnet 里的一个独立节点。
- 旁证（第三方博客，不是官方文档）：tailscaled 可以用 `--tun=userspace-networking --socks5-server=…` 跑，不装网卡，只对配了代理的应用生效，并且可以搭配 `--exit-node` 使用。

**c1. 编排模式**：被控端跑 tailscale 并开 `--advertise-exit-node`，Porta 只负责一键开关。
- **能复用**：RustDesk 现有的远控会话可以当"控制信道"：在被控端执行 `tailscale set --advertise-exit-node`、读取状态；或者新加一个 Misc 消息，让被控端的 Porta 服务去调 tailscaled 的 LocalAPI。**[推]**
- **要新写**：被控端调 tailscale CLI 或 LocalAPI；服务端调 Headscale API 批准路由（或者在策略里配 autoApprovers，就不用每次批）；控制端执行 `tailscale set --exit-node=<被控端>`，加 UI。工作量**小**。**[推]**
- **系统权限和平台**：两端都要装 Tailscale 并登录 Headscale。Windows 和 macOS 上 Tailscale 自己装网卡；Android 上 Tailscale 占用唯一的 VPN 槽位。被控端做出口时，Windows、macOS、Android 都由 Tailscale 自己处理，Linux 要开 ip_forward。**[推]**
- **对 hbbr 的依赖**：**没有**。流量走 WireGuard 直连，打不通就走 DERP，用户已经有深圳和成都两台 derper。DERP 是另一套中继，带宽同样受 VPS 限制，但和 hbbr 无关。**[推]**
- 代价：用户要多装一个软件、多维护一个账号体系，Porta 自身的价值只剩"按钮"。

**c2. 嵌入模式**：把 tsnet 或 wireguard-go 嵌进 Porta。
- tsnet 是 Go 库，Porta 是 Rust 加 Flutter，要用 cgo 编成 C 静态库或动态库，再通过 FFI 调用。各平台交叉编译加上体积（Go 运行时加 tailscale 依赖，数十 MB 级 **[推]**）都要处理。
- 被控端用 tsnet 做出口：tsnet 本身是用户态栈，用来"做服务"很方便。它能不能像 tailscaled 那样当 exit node 转发别人的流量，官方 tsnet 文档没写，**需要另外查证**。**[推]**
- 控制端想全局接管流量，仍然要虚拟网卡（嵌 tailscaled 而不是 tsnet），本质上就是"Porta 自带一个 Tailscale 客户端"，权限和平台难点同 b，只是协议栈、打洞和 DERP 都能复用。
- 走 Rust 原生路线的话可以看 boringtun（Rust 的 WireGuard 实现），但没有 Tailscale 的控制面，要自己对接 Headscale 的 Noise 控制协议，工作量很大。**[推]**
- 工作量：中到大。

### 对照小结

| | a 应用层代理 | b 自研 VPN | c1 编排 Tailscale | c2 嵌入 tsnet/wg |
|---|---|---|---|---|
| 复用上游 | 高（mux 隧道） | 中（只复用通道） | 低（只用控制信道） | 低 |
| 新代码量 | 小到中 | 大 | 小 | 中到大 |
| 管理员权限 | 不需要 | 控制端需要；被控端视方案 | 由 Tailscale 安装时解决 | 控制端全局接管时需要 |
| 全局流量 | 否（只有配了代理的应用） | 是 | 是 | 是 |
| UDP | 要扩展 | 天然支持 | 天然支持 | 天然支持 |
| 依赖 hbbr | 是（打洞失败时） | 是 | 否（用 DERP） | 否（用 DERP） |
| 额外安装 | 无 | 驱动或扩展 | Tailscale 客户端 | 无（但包体变大） |

---

## 5. 上游相关 issue / PR

- PR #16062 port forward shared conn（已合并，2026-09-05）：https://github.com/rustdesk/rustdesk/pull/16062 ——引入 mux，文中明确"一个隧道只服务登录时授权的那个目标"。
- Discussion #1136「vpn support, like zerotier」：https://github.com/rustdesk/rustdesk/discussions/1136 ——维护者答"Technically, yes"，没有落地；有评论建议直接用 easytier。
- Discussion #5293「CLI mode only for linux」：https://github.com/rustdesk/rustdesk/discussions/5293 ——无界面 TCP 隧道的用法；有用户反映隧道空闲约 35 秒自动关闭（和 §1.2、§3 的推测吻合）。
- 以下几条都是反方向的需求，即"让 RustDesk 自己经外部代理上网"，**不是**"把被控端当代理"，列出来免得混淆：#46 https://github.com/rustdesk/rustdesk/issues/46 、Discussion #6398 https://github.com/rustdesk/rustdesk/discussions/6398 、Discussion #5687（HTTP 代理，PR #7600 已合并）https://github.com/rustdesk/rustdesk/discussions/5687 、hbb_common PR #600（WebSocket 经代理）https://github.com/rustdesk/hbb_common/pull/600 。
- 用 WebSearch 和 exa 双路搜索，都**没有找到**"use remote as proxy / SOCKS 出口 / exit node"的上游 issue 或 PR。说明上游没有这方向的计划，Porta 要自己做。

---

## 6. 架构设计时需要拍板的方向性问题

1. **Exit Node 的语义**：要的是"全局 VPN"（所有流量、包括 UDP 都走出口），还是"按应用代理"（浏览器等配了代理的程序走出口就够了）？这决定了选 a，还是选 b/c。
2. **和 Headscale 的关系**：既然 Headscale 和 derper 已经在跑，Porta 是只做编排（c1，最省事，但要求两端都装 Tailscale），还是 Porta 自己提供出口能力、不依赖 Tailscale（a 或 b）？两者也可以并存：a 做"零安装的轻量出口"，c1 做"全局出口"。
3. **hbbr 的定位**：Exit 流量允许不允许走 hbbr？允许的话，要调 `SINGLE_BANDWIDTH` 和降级策略，并评估 VPS 流量成本；不允许的话，打洞失败时就只能拒绝开启出口，或者退到 DERP。
4. **legacy 明文端口转发怎么处理**：Porta 要不要直接删掉 legacy 路径，强制只用 mux？这样也能顺便堵上 §1.3 的明文问题。这同时意味着放弃和老版本 RustDesk 被控端的端口转发兼容。
5. **被控端出口的授权粒度**：开了 Exit 之后，是否允许访问被控端所在的局域网（相当于 subnet router）？是否要端口或网段黑白名单？
