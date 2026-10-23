# 第三期调研 04：TUN 代理下的局域网直连

> 2026-10-23 写。基线：客户端 `rustdesk@bd92623`（`porta-client` main 在 `ea74616`，本文涉及的 `src/rendezvous_mediator.rs` 只多一行无关挂钩，`src/client.rs`、`src/server.rs` 和基线逐字相同），hbb_common 用客户端子模块里的版本；服务端 `porta-server@c79181b`（会合部分和 `7c85b95` 相同）。TUN 一侧读的是 mihomo 用的 `MetaCubeX/sing-tun@abfcfde`（meta 分支，2026-10-22）和 `clash-verge-rev` dev 分支。
> 标记：【读码】读代码确认；【推测】推断，未编译、未实测；【实测】2026-10-23 第一期验收里实际看到的；【旁证】第三方 issue、文档。
> 本文只谈"同一局域网、服务端已经判成同一内网"这一条路。跨网打洞、路由选中继分别见笔记 01 和第一期的 `server/PORTA.md`。

## 0. 要回答的问题

1. 上游局域网路径完整流程：被控端 `local_addr` 怎么取、之后在哪个地址上等控制端连进来；控制端收到 `is_local` 的 `PunchHoleResponse` 后怎么连、超时多久、失败怎么回落。
2. Porta 被控端改报真实网卡的局域网地址时，要怎样才能真的在那个地址上收到连接；几种做法各改哪些上游文件、几行，和 §3.3 改动纪律是否相容。
3. 怎么选"真实网卡"：排除虚拟网卡、多网卡、Windows 和 macOS 的差别；要不要上报多个候选（新 proto 字段），控制端怎么试。
4. 绑定物理网卡地址去连会合服务器时，mihomo 的 auto-route、strict-route 会不会照样劫持；绑定源地址对 Windows、macOS 选路的实际效果。
5. 一端是原版 RustDesk 时的兼容性。
6. porta-server 要不要配合改。
7. 推荐方案、备选、不做的事、拍板问题、风险。

## 1. 结论先行

- **这个故障两端都有份**【读码】。被控端把"连会合服务器那条 socket 的本地地址"报上去，开 TUN 时就是 TUN 网卡地址 `198.18.0.1`；控制端去连时，也把自己的源地址**绑定**在"自己连会合服务器那条 socket 的本地地址"上，开 TUN 时同样是 `198.18.0.1`。只修被控端不够：被控端报对了地址，控制端仍会从 TUN 地址发起连接（Windows 上进 TUN 交给 mihomo 转发，能不能通看代理规则；macOS 上直接不通，见 §3.3）。
- **推荐做法（方案 A）**：只在"本地地址是虚拟网卡地址"时改行为，其余情况和上游完全一样。
  1. 被控端把上报的 IP 换成物理网卡的局域网 IP（端口不变）。
  2. 被控端等连接的监听改成 `0.0.0.0:同一端口`（原来绑在 TUN 地址上）。
  3. 控制端在 `is_local` 且自己的本地地址是虚拟地址时，不绑定源地址（交给系统按目的地址选路）。

  三处各加 1 行挂钩，分别在 `src/rendezvous_mediator.rs`、`src/server.rs`、`src/client.rs`，逻辑放 `libs/porta/src/lan.rs`（估计 150~250 行，含 Windows 网卡枚举和单元测试）【推测】。不改 proto，不改服务端，和 §3.3 相容。
- **为什么这样就能通**【读码】：局域网目的地址有一条"直连网段"路由（例如 `192.168.1.0/24` 在物理网卡上），它比 TUN 装的路由（Windows 是 `0.0.0.0/0`，macOS 是 `1.0.0.0/8`~`128.0.0.0/1` 一组子网）更具体，最长前缀优先。所以**不绑定源地址的** socket 连局域网地址时，Windows 和 macOS 都会从物理网卡直接出去，不经过 mihomo。
- **不推荐"把连会合服务器的 socket 绑到物理网卡"**（方案 B）：它让这条连接绕过代理。会合服务器用域名、mihomo 又开着 fake-ip 时，域名解析出来的是 `198.18.x.x` 假地址，从物理网卡出去必然连不上；macOS 是弱主机模型，绑定源地址也不改变出口网卡。何况局域网直连根本不需要这条 socket 的端口映射，没必要冒这个险（§3、§5）。
- **原版 RustDesk 被控端开 TUN 时，Porta 修不了**：它的监听绑在 `198.18.0.1:端口` 这个具体地址上，从局域网连不进去。验收里的 MacBook 就是这种情况（第一阶段 Porta 只做 Windows），只能在用户侧让会合服务器的地址绕开 TUN（§7.2）。
- **服务端不用改**（单地址方案）。porta-server 原样转发 `LocalAddr.local_addr`，不校验内容【读码】。只有以后要上报多个候选地址时，才需要 porta-cardo 加 proto 字段、porta-server 转发它（§6、§8）。

## 2. 上游局域网路径【读码】

### 2.1 服务端怎么判"同一内网"

`porta-server@c79181b:src/rendezvous_server.rs` `handle_punch_hole_request`（和原版 hbbs 一样）：控制端打洞请求的来源 IP 和被控端注册地址的 IP 相同（或两者都在 `mask` 网段里），且不是 WebSocket 连接，就判 `same_intranet`，给被控端发 `FetchLocalAddr`，不发 `PunchHole`。被控端回 `LocalAddr` 后，`handle_local_addr` 拿 `la.local_addr` 原样填进 `PunchHoleResponse.socket_addr`，置 `is_local = true`，转给控制端。服务端不看这个地址的内容，也不和连接来源比对。

### 2.2 被控端：`handle_intranet` → `handle_intranet_` → `accept_connection_`

`rustdesk@bd92623:src/rendezvous_mediator.rs`：

1. `handle_intranet`：100 ms 内的重复请求丢掉；如果带了控制端的 IPv6 地址、又没走 WebSocket 或代理，先 `start_ipv6` 打一个 IPv6 的 UDP 洞（和后面的 TCP 互不影响）。然后在"长连接的本地地址是 IPv4、没走 WebSocket 或代理、没禁用 TCP 监听"时进 `handle_intranet_`；失败就 `create_relay` 走中继。
2. `handle_intranet_`：
   - 先占一个 `TCP_PUNCHES` 名额（并发打洞上限），没名额就报错、外层走中继。
   - `connect_tcp(&*self.host, CONNECT_TIMEOUT)` **新开一条**到会合服务器的 TCP 连接（不是注册用的长连接）。`connect_tcp` → `connect_tcp_local(target, None, ..)` → `FramedStream::new`：本地地址为空时绑 `0.0.0.0:0`（`Config::get_any_listen_addr`），开 `SO_REUSEADDR`（Unix 再加 `SO_REUSEPORT`），再 connect（`hbb_common/src/tcp.rs` `new_socket`）。
   - `local_addr = socket.local_addr()`，也就是**系统为这条连接选的源地址和端口**。开 TUN 时这条连接按路由进 TUN，源地址就是 TUN 网卡地址 `198.18.0.1`。注释里还提到用代理时见过 `::1`，所以重新 parse 了一遍。
   - 在这条连接上发 `LocalAddr{local_addr, socket_addr=控制端公网地址, relay_server, socket_addr_v6, version, id}`，然后调 `crate::accept_connection(server, socket, peer_addr, true, meta, slot)`。整个客户端里只有这一处调用 `accept_connection`。
3. `rustdesk@bd92623:src/server.rs` `accept_connection_`：
   - 取 `socket.local_addr()`，**丢掉**这条到会合服务器的连接；
   - `new_listener(local_addr, true)`：在**同一个 IP:端口**上开监听（`SO_REUSEADDR`，注释说是为了躲 TIME_WAIT）；
   - 最多等 `CONNECT_TIMEOUT`（18 秒）接受**一条**连接，不按来源过滤；接到就还名额，`create_tcp_connection(.., secure=true, meta)` 进正常的握手和会话。没等到就结束，这次请求不产生连接。

所以被控端没有复用那条 socket 收连接，而是"借它的本地 IP 和端口，另起一个只活 18 秒、只收一条连接的监听"。监听绑的是**具体 IP**，不是 `0.0.0.0`。在局域网场景里没有 NAT，这个端口没有映射意义，复用端口只是和打洞路径共用了写法。

### 2.3 控制端：`_start_inner` → `connect`

`rustdesk@bd92623:src/client.rs`：

1. `_start_inner`：`connect_tcp` 连会合服务器，`my_addr = socket.local_addr()`（开 TUN 时同样是 `198.18.0.1:端口`）。最多 3 轮发 `PunchHoleRequest`，日志 `#1 TCP punch attempt with {my_addr}` 打的就是这个本地地址，所以验收日志里第一行的 `198.18.0.1:14438` 是**控制端自己**的 TUN 地址。
2. 收到 `PunchHoleResponse`：`is_local = ph.is_local()`，`peer_addr = decode(ph.socket_addr)`，日志 `{punch_type} Hole Punched {id} = {peer_addr}`，所以第二行的 `198.18.0.1:54996` 是**被控端**报上来的 TUN 地址。
3. `connect(local_addr = my_addr, peer = peer_addr, .., is_local, ..)`：
   - 超时：`is_local` 或对端 NAT 是 `SYMMETRIC` 时固定 `MIN = 1000` 毫秒；日志 `peer address: {peer}, timeout: 1000`。
   - 直连尝试：允许 TCP 打洞时，`connect_tcp_local(peer, Some(local_addr), connect_timeout)`，**源地址绑定在 `my_addr` 上**（同 IP 同端口，`SO_REUSEADDR`）。另外有 UDP 洞、IPv6 洞、WebRTC 时一起赛跑（`select_ok`），谁先成谁赢。
   - 全部失败（或强制中继）且 `relay_server` 非空：`request_relay` 走中继，日志 `#1 request relay attempt`；`relay_server` 为空就报错。
   - 连上以后 `secure_connection` 校验对端签名的 id 和公钥。**TCP 直连连上了、但握手失败时直接报错，不回落中继**（只有 WebRTC 握手失败才回落）。

验收日志对得上：控制端从 `198.18.0.1:14438` 去连 `198.18.0.1:54996`，这个地址是控制端自己 TUN 网卡的地址，连接要么被本机拒绝、要么被 mihomo 接走，1 秒内没有成功，退回中继【实测 + 读码】。

## 3. TUN 环境下的路由事实

### 3.1 mihomo 怎么装路由【读码，`MetaCubeX/sing-tun@abfcfde`】

- TUN 网卡地址：mihomo 顶层 `tun:` 不开放 `inet4-address`，写死 `198.18.0.1/30`【旁证：mihomo 配置解析的第三方整理，和验收日志一致】。fake-ip 地址池默认是 `198.18.0.1/16`。两者都落在 `198.18.0.0/15`（RFC 2544 基准测试保留段）里。
- `tun_rules.go` `BuildAutoRouteRanges`，没配 `route-address` 时：
  - **macOS**（`autoRouteUseSubRanges = darwin`）：装 `1.0.0.0/8`、`2.0.0.0/7`、…、`128.0.0.0/1` 一组子网，不碰 `0.0.0.0/0`。原来物理网卡的默认路由还在。
  - **Windows / Linux**：装 `0.0.0.0/0`。Windows 上路由 metric 是 0，TUN 接口 metric 也设成 0（`tun_windows.go` `configure`），压过物理网卡的默认路由；物理网卡的那条默认路由仍在表里，只是 metric 更大。
  - 配了 `route-exclude-address` 时，从上面的范围里挖掉这些网段再装。
  - 题目里说的"`0.0.0.0/1` + `128.0.0.0/1`"是文档示例和 Linux 上手动配置的常见写法，不是 Windows、macOS 的默认值。
- **strict-route**：
  - Windows（`tun_windows.go` `Start`）用 WFP 加过滤器：放行 mihomo 自身进程、放行 TUN 网卡；**"block ipv4" 那段被注释掉了，IPv4 不封**；没配 IPv6 地址时封 IPv6；DNS 劫持模式下封非 TUN 网卡的 53 端口。
  - Linux 上让其他网卡不可达。
  - mihomo 文档没写 macOS 上有额外效果。
- Clash Verge Rev 的默认值【读码，dev 分支 `src-tauri/src/config/clash.rs` `template`、`tun-viewer.tsx`】：`auto-route: true`、`strict-route: false`、`auto-detect-interface: true`，设备名 Windows 是 `Mihomo`、macOS 是 `utun1024`。界面"TUN 设置"里可以填 `route-exclude-address`。
- 有人把整个私网段（`10/8`、`172.16/12`、`192.168/16` 等）写进 `route-exclude-address`【旁证：clash-verge-rev Discussion #7469】，这种配置下私网目的地址完全不经过 TUN。

### 3.2 两个系统的源地址模型【旁证：Microsoft 文档、Wikipedia "Host model"】

- **Windows（Vista 起）默认强主机模型**：socket 绑了源地址，选路就只在拥有这个地址的网卡上找路由；从一个网卡发出的包，源地址必须是这个网卡的地址。
- **macOS（BSD）是弱主机模型**：选路只看目的地址，绑定的源地址照原样填进包里，可以从别的网卡发出去。要强制走某块网卡，得用 `IP_BOUND_IF`（按接口序号），光 `bind` 源 IP 不够【推测，按 BSD 网络栈的一般行为，未在本项目实测】。

### 3.3 由此推出的四种情况【推测，按 3.1、3.2 推导，未实测】

| socket 怎么建 | 目的地址 | Windows | macOS |
|---|---|---|---|
| 不绑源地址 | 局域网 IP（有直连网段路由） | 直连网段路由（如 /24）比 TUN 的 `0/0` 具体，从物理网卡直接出去 | 直连网段路由比 TUN 的子网路由具体，从物理网卡直接出去 |
| 绑在 TUN 地址 `198.18.0.1` | 局域网 IP | 强主机模型只看 TUN 上的路由，命中 `0/0` 进 TUN；mihomo 按规则处理（私网规则是 DIRECT 就由 mihomo 从物理网卡代发，能通；规则走代理就不通）。`route-exclude-address` 里排除了这个私网段时，TUN 上没有对应路由，立即失败 | 按目的地址选物理网卡发出，源地址却是 `198.18.0.1`；对端回包发往 `198.18.0.1`，对端自己开着 TUN 时这是它自己的地址，不开 TUN 时会发给它的默认网关。**不通** |
| 绑在物理网卡地址 | 会合服务器公网 IP | 强主机模型只看物理网卡上的路由，走物理网卡的默认路由，**绕过 TUN 和代理**；strict-route 不封 IPv4，所以不会被拦（DNS 53 端口除外） | 选路仍按目的地址，进 TUN，源地址却是物理网卡地址，mihomo 系统栈怎么处理这种包不确定；要真正绕开得用 `IP_BOUND_IF` |
| 绑在物理网卡地址 | fake-ip 假地址 `198.18.x.x` | 从物理网卡发往假地址，**不通** | 进 TUN 能被 mihomo 认出来，但源地址不对，结果不确定 |

验收里 Windows 控制端连 Windows 上的 TUN 地址那一步，属于"目的地址是本机地址"，和这张表无关：直接在本机内部投递，没有监听就失败。

## 4. 被控端怎样在物理网卡地址上收到连接（问题 2）

前提：被控端报的地址换成物理网卡的 IP，控制端按 §5 不再绑 TUN 地址。剩下的问题是被控端的监听要开在哪里。

| 方案 | 做法 | 上游改动 | 评价 |
|---|---|---|---|
| **A 换报地址 + 监听放宽（推荐）** | `handle_intranet_` 算出 `local_addr` 后，虚拟地址时把 IP 换成物理网卡 IP、端口不变；`accept_connection_` 里监听地址是虚拟地址时改成 `0.0.0.0:同一端口` | `rendezvous_mediator.rs` +1 行，`server.rs` +1 行 | 连会合服务器的连接照旧走代理，不受 fake-ip 影响；监听只活 18 秒、只收一条连接，和上游语义一样（上游本来就不按来源过滤）。`0.0.0.0` 比具体 IP 多收 TUN、虚拟机网卡上的连接，影响可以忽略，握手照样要校验 |
| A' 监听绑物理 IP | 同 A，但监听绑 `物理IP:端口` | 同 A | 范围更窄，但两处挂钩要算出同一个 IP：两次枚举之间网卡变了就会对不上。要么做成一次计算、两处共享（多一个静态状态），要么接受偶尔回落中继。收益不大，不如 A |
| A'' 新端口 | 不借会合连接的端口，直接 `new_listener(物理IP:0)`，报系统分配的端口 | 要替换 `accept_connection` 调用，把 `accept_connection_` 的接受逻辑搬进主 crate 的 Porta 文件（`PunchSlot`、`create_tcp_connection` 都在主 crate，`libs/porta` 调不到） | 语义最干净（局域网不需要端口复用），但上游改动和自写代码都更多 |
| B 会合连接绑物理网卡 | `handle_intranet_` 里改用 `connect_tcp_local(host, Some(物理IP:0), ..)`，`local_addr` 自然就是物理 IP，后面全不用动 | `rendezvous_mediator.rs` 改 1 行 | 只有 1 行，但这条连接会绕过代理：会合服务器直连不通时整条局域网路径失败；fake-ip 模式下域名解析成假地址时必然失败；macOS 上 `bind` 不改变出口网卡（§3.3）。不推荐 |
| C 借直连端口 21118 | 报 `物理IP:21118`，由 `direct_server` 接 | `rendezvous_mediator.rs` +1 行，外加要求用户打开"允许 IP 直接访问" | `direct_server` 默认关；它调 `create_tcp_connection(.., secure=false, ConnectionMeta::default())`，**丢掉服务端下发的控制权限**（`meta`），安全握手也和局域网路径（`secure=true`）不一样。常驻开放端口改变了安全面。否决 |
| D 用户侧绕开 | 代理里把会合服务器地址排除出 TUN，连会合服务器的 socket 源地址自然是物理网卡 | 不改代码 | 原版客户端也适用（§7.2），但要每台机器手配，而且有已知坑 |

方案 A 的挂钩写法（示意，名字待定）：

```rust
// src/rendezvous_mediator.rs  handle_intranet_，紧接在 local_addr 重新 parse 之后
let local_addr = porta::lan::advertised_local_addr(local_addr);
// src/server.rs  accept_connection_，紧接在 let local_addr = socket.local_addr(); 之后
let local_addr = porta::lan::intranet_listen_addr(local_addr);
// src/client.rs  connect()，在算 connect_timeout 之前
let local_addr = porta::lan::controller_bind_addr(local_addr, is_local);
```

- `advertised_local_addr`：地址是虚拟地址（判据见 §5）且找得到物理网卡候选时，换成候选 IP、保留端口；否则原样返回。上游不开 TUN 的用户完全不受影响。
- `intranet_listen_addr`：地址是虚拟地址时返回 `0.0.0.0:端口`，否则原样返回。`accept_connection` 只有局域网路径调用（§2.2），不会波及打洞路径。
- `controller_bind_addr`：`is_local` 且地址是虚拟地址时返回 `0.0.0.0:0`，否则原样返回。非局域网的 TCP 打洞仍按上游绑定（那条路靠端口复用穿 NAT，开 TUN 时本来就打不通，不在本文范围）。

改动纪律：三个文件里，`client.rs`、`rendezvous_mediator.rs` 是 §3.3 列出的热点文件，`server.rs` 不在列表里但也是上游文件；三处都只加一行 `porta::…` 调用，逻辑全在 `libs/porta`，相容。`libs/porta` 只依赖 `hbb_common` 和 `base`，网卡枚举放进去不会成环。

## 5. 怎么选"真实网卡"（问题 3）

### 5.1 判"虚拟地址"

`local_addr` 的 IP 满足下面任一条就算虚拟地址，触发 Porta 的替换：

- 在 `198.18.0.0/15` 里（mihomo、sing-box、Shadowrocket 的 TUN 默认地址和 fake-ip 池都在这里）；
- 或者属于 §5.2 判成虚拟网卡的接口。

只用第一条就能覆盖维护者的环境；第二条是为了覆盖别的代理软件（例如自定义了 TUN 地址的）。

### 5.2 枚举候选

依次过滤：

1. 接口在线，有 IPv4 地址，排除回环和 `169.254.0.0/16`。
2. 排除虚拟网卡：
   - Windows 看 `IfType`：53 `IF_TYPE_PROP_VIRTUAL`（Wintun 的 INF 里写死 53，Tailscale、WireGuard、mihomo、sing-box 都用 Wintun；OpenVPN 的 TAP 也改成了 53）、131 隧道、23 PPP、24 回环【旁证：wintun.inf、Microsoft `IP_ADAPTER_ADDRESSES` 文档】。
   - macOS 看接口名前缀：`utun`、`ipsec`、`ppp`、`bridge`、`awdl`、`llw`、`anpi`、`gif`、`stf`。
   - 两边都排除 `198.18.0.0/15` 和 `100.64.0.0/10`。`100.64.0.0/10` 是 Tailscale 的默认地址段，运营商 CGNAT 地址也在这段，但不会出现在局域网网卡上。
3. 要求接口**有 IPv4 默认网关**。这一条顺带排除了 Hyper-V/WSL 的 `vEthernet`、VMware/VirtualBox 仅主机网卡、ZeroTier 这类没有网关的虚拟以太网卡。维护者用 WSL，这条有实际意义。
4. 地址优先选 RFC 1918 私网段（`10/8`、`172.16/12`、`192.168/16`）。
5. 多个候选时，优先有线、再按链路速度从高到低排。Windows 的自动 metric 本来就按链路速度定，这个顺序近似于"不开 TUN 时系统会选的默认网卡"。

**不能用 `default_net::get_default_interface()`**【读码，`default-net 0.14.1`】：它用"UDP socket connect 一个公网地址，再看本地地址"来判断默认网卡，开 TUN 时选中的正好是 TUN。

### 5.3 用什么库

- **`default-net 0.14`**：主 crate 已经依赖它（`Cargo.toml` 第 76 行，`src/lan.rs` 的局域网发现在用），`libs/porta` 加同一版本不会往 `Cargo.lock` 里加新包。它能给出 `if_type`、IPv4 和掩码、MAC、链路速度、网关【读码】。两个坑：
  - Windows 上每个有网关的网卡都会同步调一次 `SendARP` 取网关 MAC。网关在 ARP 缓存里时立即返回，不在时会阻塞到 ARP 超时。
  - macOS 上只给"默认网卡"填网关，而且是开 BPF 抓包拿的；"默认网卡"又是按上面那个 UDP 办法判的，开 TUN 时是 utun，所以**物理网卡拿不到网关**。
- 结论：Windows 先用 `default-net`，在 `spawn_blocking` 里调。先量一下耗时，确实慢再加缓存或改成直接调 `GetAdaptersAddresses`（带 `GAA_FLAG_INCLUDE_GATEWAYS`，不发 ARP）。不要一开始就加后台刷新线程。macOS 第一阶段不做（Porta 第一阶段只有 Windows 客户端）；以后做 macOS 时，网关要从路由表读（`sysctl` 的 `NET_RT_DUMP`，或者按 §3.1 的结论，开 TUN 时 `0.0.0.0/0` 那条仍是物理网卡），不能用 `default-net`。

### 5.4 多网卡、多候选

- 有线和无线连在**同一个**局域网：选哪个都通，按 5.2 第 5 条选有线。
- 机器同时在**两个不同**网段（例如有线在办公网、无线在另一个网络）：被控端不知道控制端在哪个网段，单地址可能选错。选错时控制端 1 秒超时、回落中继，不比现在差。
- 想彻底解决，就得上报多个候选：
  - proto 只追加字段（§3.3）：`LocalAddr` 加 `repeated bytes porta_local_addrs = 1000;`，`PunchHoleResponse` 加同名同号字段；`local_addr` / `socket_addr` 仍放最优的那个，给原版客户端用。
  - 控制端先挑和自己某块物理网卡同网段的候选，再按顺序把其余的并发连（同一个 1 秒窗口，`select_ok`），被控端监听开在 `0.0.0.0:端口` 上，所以所有候选共用一个端口。
  - 代价：porta-cardo 改 proto，porta-server 的 `handle_local_addr` 要转发新字段并加上限（例如最多 8 个、每个不超过 18 字节，照 `PORTA.md` §6 第 8 条的写法）；`client.rs` 的挂钩从 1 行变成要能注入多个 future，行数更多。
  - **建议先不做**，等单地址方案上线后真遇到多网段机器再加。

## 6. 绑定物理网卡去连会合服务器会怎样（问题 4）

即 §4 的方案 B，结论见 §3.3 表格后两行：

- **Windows**【读码 + 推测】：绑物理网卡 IP 后，强主机模型让这条连接只走物理网卡的默认路由，TUN 的 `0/0` 路由不参与；strict-route 的 WFP 过滤器不封 IPv4，所以不会被拦。代价是这条连接绕过了代理：
  - 会合服务器直连不通（被墙、被运营商限制）时，局域网路径整体失败；
  - 会合服务器写的是域名、mihomo 开 fake-ip（Clash Verge 默认 `enhanced-mode: fake-ip`）而这个域名不在 `fake-ip-filter` 里时，解析出来是 `198.18.x.x`，从物理网卡发出去必然不通。
- **macOS**【推测】：弱主机模型下 `bind` 只改源地址，不改出口；包仍按目的地址进 utun，源地址却是物理网卡地址，mihomo 怎么处理不确定。要真正绕开得 `IP_BOUND_IF`，上游 `FramedStream::new` 不支持，得另写连接函数。
- 这条连接在局域网场景里只用来送 `LocalAddr` 和借端口，没有必要绕过代理。所以方案 A 不碰它。

## 7. 和原版 RustDesk 的兼容性（问题 5）

### 7.1 组合矩阵【推测，按 §2、§3 推导】

下表"开 TUN"指开着 mihomo 类 TUN、没有排除会合服务器地址。

| 控制端 | 被控端 | 结果 |
|---|---|---|
| Porta | Porta（开 TUN） | 被控端报物理 IP，控制端不绑源地址，**直连成功**（本文目标） |
| Porta | Porta（不开 TUN） | 和上游一样，直连成功 |
| 原版，不开 TUN | Porta（开 TUN） | 被控端报物理 IP，控制端绑的是自己的物理 IP，**直连成功** |
| 原版，Windows，开 TUN | Porta（开 TUN） | 控制端绑 `198.18.0.1` 去连对端物理 IP，按强主机模型进 TUN、交给 mihomo：私网规则是 DIRECT 就由 mihomo 代发，**能通，但多绕一道用户态转发**；规则走代理，或 `route-exclude-address` 排除了私网段，就失败、回落中继 |
| 原版，macOS，开 TUN | Porta（开 TUN） | 源地址 `198.18.0.1` 从物理网卡发出，对端回包回不来，**失败、回落中继**，和现在一样 |
| Porta | 原版（开 TUN） | 被控端报 `198.18.0.1` 且只在这个地址上监听，Porta 控制端无能为力，**失败、回落中继**，和现在一样 |
| 任一 | 原版（不开 TUN） | 和上游一样 |

- 都比现在好或者持平，没有变差的组合。
- 只有一种情况是在机制上变了：Porta 控制端在 `is_local` 且自己的本地地址是虚拟地址时，不再绑源地址。原来这种情况必然连不上 `198.18.x.x`，所以没有可回归的行为。
- 服务端换成原版 hbbs 也成立：单地址方案不改 proto，hbbs 同样原样转发 `local_addr`。

### 7.2 原版被控端（验收里的 MacBook）怎么办

只能在用户侧处理，并且两台都要配（被控端是关键）：让会合服务器的地址绕开 TUN，这样被控端连会合服务器的 socket 走物理网卡，报的就是物理 IP。

- Clash Verge Rev 里要在**界面的"TUN 设置"对话框**填 `route-exclude-address`。写在订阅或"全局扩展配置"（Merge）里的会被界面保存的空列表覆盖【旁证：clash-verge-rev #7421，Windows】。内部待办里写的"全局扩展配置 `tun.route-exclude-address`"要按这条核对。
- 会合服务器配的是域名时，还要把这个域名加进 `fake-ip-filter`，否则解析出来的是假地址，排除真实 IP 不起作用【旁证：rustdesk-server #457 下的回复】。
- mihomo 有一个未关闭的 issue 报告 `route-exclude-address` 在三个平台上都偶尔不生效【旁证：mihomo #2618】，实测时留意。
- 上游有一样的报告：macOS 被控端开 Shadowrocket TUN，日志 `Server listening on: 198.18.0.1:…`，Windows 控制端连不上；报告者说 iOS、Android、macOS 控制端能连，多半是回落到了中继，没有核实【旁证：rustdesk #14480 / Discussion #14485，2026-03，没有维护者回复】。另一个基于 iroh 的项目也碰到候选地址里混进 Clash TUN 地址的问题，修法同样是按 `198.18.0.0/15`、`100.64.0.0/10` 和接口名过滤【旁证：UniClipboard #486】。

## 8. 服务端要不要改（问题 6）

- **单地址方案（推荐）：不用改**【读码】。`handle_local_addr` 原样转发 `local_addr`，不校验内容；连接结果记录（`conn_tracker.rs`）按"回的是 `LocalAddr`"判 `direct_lan`，不看地址，统计口径不变。
- **多候选方案**：要改三处。
  - porta-cardo 的 `rendezvous.proto` 加 §5.4 的两个字段；
  - porta-server `handle_local_addr` 把新字段从 `LocalAddr` 搬到 `PunchHoleResponse`，加条数和长度上限，写进 `PORTA.md` §6 第 2 条的转发表；
  - 原版 hbbs 不认新字段，会丢掉它，控制端退回单地址，可以接受。
- 有一件和服务端相关、但不在本文范围的事：开 TUN、走同一个代理出口的两台机器，即使不在同一局域网，服务端也会因为公网 IP 相同判成"同一内网"。这时只试 1 秒局域网连接就回落中继，不尝试打洞。原版行为如此，第一期验收里没有碰到。要处理的话属于路由笔记的范围。

## 9. 推荐、备选、不做

### 9.1 推荐

方案 A（§4）加 §5 的选网卡规则：

- 单地址，不改 proto、不改服务端；
- 三个上游文件各 1 行挂钩，`libs/porta/src/lan.rs` 放逻辑；
- `libs/porta/Cargo.toml` 加 `default-net = "0.14"`（Windows）。

单元测试覆盖：虚拟地址判断；候选过滤和排序（用构造的接口列表，不依赖本机网卡）；三个挂钩函数"非虚拟地址原样返回"。

### 9.2 备选

- **A'' 新端口监听**：上游改动多几行、自写代码多一些，换来语义更干净。实测 A 有端口冲突再换。
- **多候选（§5.4）**：等遇到多网段机器再加。
- **控制端快速放弃**：Porta 控制端收到 `is_local` 且对端地址在 `198.18.0.0/15` 时直接走中继，省下最多 1 秒。只对"原版被控端开 TUN"有用，收益小，不建议单独做。

### 9.3 明确不做

- 不让连会合服务器的连接绕过代理（方案 B），也不用 `IP_BOUND_IF` / `IP_UNICAST_IF` 强绑网卡。
- 不借 21118 直连端口（方案 C），不要求用户打开"允许 IP 直接访问"。
- 不在 Porta 里自动改用户的代理配置（例如写 `route-exclude-address`）。
- 不做 macOS 的选网卡实现（第一阶段只有 Windows 客户端）。
- 不改服务端判"同一内网"的逻辑。
- 不处理开 TUN 时的跨网 TCP 打洞（所有连接都经 mihomo 转发，NAT 类型检测本身就不准，属于另一个问题）。

## 10. 待维护者拍板

1. 接不接受三处一行挂钩：`client.rs`、`rendezvous_mediator.rs` 是 §3.3 列的热点文件，`server.rs` 不在列表里但也是上游文件。
2. 被控端监听用 `0.0.0.0:端口`（推荐），还是绑物理 IP（A'）。
3. 先做单地址（推荐），还是一步到位做多候选（要动 proto 和 porta-server）。
4. 网卡枚举先用现成的 `default-net 0.14`（推荐，Windows 有 `SendARP` 阻塞风险，先量），还是直接自己调 `GetAdaptersAddresses`。
5. 放第三期哪个位置：它只动客户端，可以独立于路由第二级、设备签名先做；也可以和"上报改走 libs/porta"一起排。
6. 在有 Porta macOS 客户端之前，MacBook 这类原版被控端是不是接受"用户侧排除会合服务器地址"作为正式做法，写进部署或使用说明。

## 11. 风险

- **挑错网卡**：多网段机器可能报错地址，结果是回落中继，不比现在差。更坏的情况是控制端所在的网络里，恰好有另一台机器在那个 IP:端口上监听：TCP 能连上，但 `secure_connection` 握手失败会**直接报错、不回落中继**（§2.3，上游行为）。概率很低（端口是临时端口），上游本来就有同样的风险。
- **Windows 防火墙**：安装版由上游安装逻辑按程序路径加入站放行规则（`src/platform/windows.rs`，用 `app_name` 和 exe 路径，改名后仍然生效）；便携版第一次监听时会弹防火墙提示，没放行就收不到连接。上游局域网路径一样受影响，不是新问题。
- **局域网地址暴露给控制端**：上游本来就这样，开 TUN 时现在暴露的只是 `198.18.0.1`，改了以后暴露真实局域网 IP。前提是服务端已判成同一公网 IP，影响很小。
- **`SendARP` 阻塞**：网关不在 ARP 缓存里时，`default-net` 枚举会变慢，拖慢 `LocalAddr` 的回复（控制端第一轮等 3 秒）。先量，慢了再换实现。
- **代理软件差异**：本文的路由结论按 mihomo / sing-tun 读码得出。别的 TUN 软件可能把私网段也装进 TUN，或者用别的虚拟地址段，§5.1 的第二条判据和 §5.2 的接口过滤能兜住大部分，兜不住就回落中继。
- **都还没实测**：§3.3 的四种情况和 §7.1 的矩阵都是推导结果，要在两台 Windows 加 Clash Verge TUN 上验证，见 §12。

## 12. 怎么验证

两台 Windows 在同一局域网，都开 Clash Verge Rev TUN（默认配置，不排除会合服务器地址），连同一个 porta-server。

1. Porta 对 Porta：
   - 被控端日志应为 `Server listening on: 0.0.0.0:<端口>`；
   - 控制端日志应为 `peer address: <被控端局域网 IP>:<端口>, timeout: 1000`，之后是 `used to establish TCP connection`；
   - porta-server 的连接结果记录应为 `direct_lan`。
2. 原版控制端（Windows，开 TUN）连 Porta 被控端：分别在 mihomo 私网规则为 DIRECT、`route-exclude-address` 含私网段两种配置下记录结果，核对 §7.1 第 4 行。
3. 多网卡：被控端同时连有线和无线（同网段），确认报的是有线地址；再插一块不同网段的网卡（或开 Hyper-V 内部交换机），确认没有被选中。
4. 回归：两台都关 TUN，日志和上游一致（不触发替换）。

## 参考

- mihomo 文档 TUN 一节：https://wiki.metacubex.one/en/config/inbound/tun/ （2026-10-23 查）
- `MetaCubeX/sing-tun@abfcfde`：`tun_rules.go` `BuildAutoRouteRanges`、`tun_windows.go` `configure` / `Start`（2026-10-23 读）
- Clash Verge Rev：`src-tauri/src/config/clash.rs` `template`、`src/components/setting/mods/tun-viewer.tsx`；issue #7421；Discussion #7469
- mihomo issue #2618（route-exclude-address 不生效）
- Wintun INF（`*IfType = 53`）：https://git.zx2c4.com/wintun/tree/wintun.inf
- Microsoft `IP_ADAPTER_ADDRESSES` 文档；强、弱主机模型：https://en.wikipedia.org/wiki/Host_model
- rustdesk #14480 / Discussion #14485；rustdesk-server #457；UniClipboard #486
