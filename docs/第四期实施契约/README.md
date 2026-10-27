# 第四期实施契约（总述）

状态（2026-10-27）：设计决策清单里要维护者拍板的 11 条已全部按推荐定，其余 69 条按推荐默认（§1.3）。01、02、03 三块初稿都已写好（02 于 2026-10-27 交付）。整份契约经维护者确认后再派 coder。A3 已单独合入，见 `server/LEAPGATE.md` §6 第 8 条（leapgate-server `1241ca7`）。

| 文件 | 内容 | 仓库 |
|---|---|---|
| README.md | 本文：决定、两端共用的接口、分块、实施顺序、兼容、验收 | — |
| [01-服务端出口目录.md](01-服务端出口目录.md) | 心跳 `exit`、目录接口、授权表（迁移 0007）、命令行 `exit` 和 `device owner`、设备主人加固、hbbr 部署参数 | leapgate-server |
| [02-被控端出口.md](02-被控端出口.md) | 出口开关和放行网段、登录关口、拒绝裸管道、地址过滤、解析和连接、关开关断会话、设置卡片和 CM 显示 | leapgate-client |
| [03-控制端代理与界面.md](03-控制端代理与界面.md) | 本地 SOCKS5/HTTP CONNECT 代理、出口监听、TCP 隧道窗口里的出口行、出口目录对话框、控制端不再回落裸管道（C11） | leapgate-client |

标注沿用第三期：【读码】读过现版源码；【推测】推断，没有实测。代码锚点对照 leapgate-client main `a57605c2f`、leapgate-server main `1241ca7`。"清单"指 `docs/research/第四期/03-设计决策清单.md`，条目编号（A1、B3、C5…）沿用清单；清单"核对时更正的事实"一节优先于读码笔记 01、02 的原文。

## 1. 总述

### 1.1 第四期做什么

应用出口：被控端在设置里打开"允许作为出口"后，控制端在 TCP 隧道窗口里加一条"出口映射"，本机 `127.0.0.1:<端口>` 上就有了一个 SOCKS5 / HTTP CONNECT 代理。设了这个代理的程序发出的每条 TCP 连接，变成多路复用隧道里的一个通道（多路复用隧道是上游 1.5.0 起的端口转发模式：一条远程会话里开多个通道，每个通道一个目标），由被控端解析域名、从自己的物理网卡连出去。被控端默认拒绝局域网和本机地址，主人可以按网段放行一部分。服务端登记"此刻开着出口的设备"，按设备主人和命令行授权列给控制端挑选；目录只是建议，不是关口，能不能用由被控端的出口开关加上游原有的认证（密码、点击确认、2FA）决定。只支持 TCP，第一阶段只做 Windows。

文中几个词：
- 裸管道：旧式端口转发，登录后整条连接直接透传到一个固定目标。
- CM：被控端的连接管理小窗，负责审批、显示谁连进来。
- 哨兵：表示"这是出口"的约定登录目标（§1.4）。
- 软拒、硬拒：软拒＝默认拒绝、放行列表能打开；硬拒＝任何规则都打不开（B3、B4）。
- S0：02、03 开工前先合入的共用骨架提交（§2.6）。
- 守卫分支：Rust 里带 `if` 条件的 match 分支。
- open、opened：控制端开通道的请求帧和被控端的应答帧。
- Happy Eyeballs：IPv6、IPv4 交错，错开 250 ms 依次尝试连接。

### 1.2 依据

- 设计决策清单（80 条决定）和它依据的读码笔记 `docs/research/第四期/01-客户端读码.md`、`02-服务端读码.md`。
- `docs/architecture.md` §3.9（已定架构；随契约要更正的几处见 §8.1）、§3.3 客户端改动纪律。
- `client/LEAPGATE.md` §1：逻辑放 `libs/leapgate`，上游文件只加一两行挂钩，前一行注释 `// leapgate: <一句话>`，只加不改。服务端契约 `server/LEAPGATE.md`。
- 原则：P-2（规则对所有运行环境都适用，不要求用户配环境规则）；如非必要勿增实体；校验只针对会变的东西；兼容原版只在最初几个版本；开发期间每块只做单测和一次冒烟，压力、吞吐和多轮对照放进开发全部完成后的统一验收（维护者 2026-10-26 定）。

### 1.3 维护者的决定（2026-10-27）

下面 11 条全部按推荐定。其余 69 条按推荐默认，以清单原文为准；契约不推翻、不改写任何一条。清单"评审之间的出入"一节已取定的四处（控制端挂钩在 `start_one_port_forward` 开头、HTTP 非 CONNECT 回 501、逐通道检查放 `on_open`、登录关口写在规范化之后）照取定的写。

| 编号 | 决定 |
|---|---|
| E1 | 第一版 `CHANNEL_WINDOW`（每个通道的流控窗口，256 KiB）不动，吞吐实测并进统一验收，判定规则预先写死（§6.2）；单流目标值取 30 Mbit/s |
| F7 | 上游 Flutter 界面的改动列为 architecture §3.3 过渡期的例外，清单写死（§3.2），超出清单要维护者同意 |
| A2 | 选 (a)：服务端只做目录和授权表，被控端的出口开关加上游认证是唯一关口；不做服务端签发的出口凭证 |
| A8 | 不改 `enable-tunnel` 的默认值，普通端口转发不加过滤；契约写清"局域网默认拒绝"只约束出口模式，防什么、不防什么 |
| A9 | architecture §3.9 "已信任的设备"那半句更正为"设备密码，或被控端有人点击接受；开了 2FA 时，已信任的设备免 2FA"，不新增免密码机制 |
| B4 | 放行网段存被控端 Config `leapgate-exit-allow-nets`（CIDR 或单个地址）；只能打开"软拒"档，回环和本机地址在任何规则下都打不开 |
| B9 | 出口流量一律从被控端物理网卡出去，不经本机的 TUN 代理、全隧道 VPN 和 RustDesk 自己的 socks 设置 |
| B10 | 被控端所在网络的 DNS 只回 fake-ip 地址（198.18.0.0/15）时默认拒绝，IP 字面量照常能用；唯一开口是放行列表写 198.18.0.0/15；不加 DoH。维护者按推荐定，即认可"默认的安全不依赖这条配置，配置只用来解锁功能"不违反 P-2 |
| C5 | 选 (A)：隧道层（登录、对端支持与否、是否加密）结果准确回报；通道层乐观地先回"连接成功"；不加 proto 字段 |
| C7 | "设为系统代理"不进第一版；出口行给可复制的 `socks5h://` 和 HTTP 地址，附浏览器配置方法 |
| C13 | 控制端逐通道的目标和成败只用 trace 级别；日志文件只记隧道级事件和不带地址的限频计数 |

### 1.4 主会话的裁定和统稿取定

**出口哨兵统一用端口 65536**（主会话裁定，解决清单"评审之间的出入"：C1、C2 写的是端口 1，F1 建议 65536）。线上登录和本地映射都用 `PortForward{host="leapgate-exit.invalid", port=65536, multiplex=true}`。理由：普通添加行输不出 65536；万一被 1.5.0 以前的原版被控端拿去走裸管道，解析端口当场失败、不查 DNS，安全不依赖 `.invalid` 解析失败（和 P-2 一致）。各条路径逐一核实过，没有一处把它截成 u16 或拒掉【读码】：

| 路径 | 处理 | 结论 |
|---|---|---|
| 控制端普通添加行（`flutter/lib/desktop/pages/port_forward_page.dart:187-190`） | 只放行 0~65535 | 手输不出；出口按钮直接传 65536，不经输入框 |
| `session_add_port_forward`（`src/flutter_ffi.rs:1716-1725`）→ PeerConfig `port_forwards: Vec<(i32, String, i32)>`（`libs/hbb_common/src/config.rs:329`） | i32，不查范围 | 原样存取 |
| 映射启动时的过滤（`src/ui_session_interface.rs:2013`） | `remote_port <= 0` 才丢 | 通过 |
| 登录组装（`src/client.rs:3890-3893`）、`PortForward.port` 是 int32（`libs/base/protos/message.proto:52`） | i32；端口转发这条链路上（`port_forward` 元组 `client.rs:2857`、登录组装 `:3890-3893`、`port_forward.rs`、`port_forward_mux.rs`、`server/port_forward_mux.rs`、`ui_session_interface.rs`、`flutter_ffi.rs`）没有 `as u16` | 原样上线 |
| 被控端规范化（`src/server/connection.rs:1789-1800` `normalize_port_forward_target`） | `format!` 拼 i32 | 得 `leapgate-exit.invalid:65536` |
| 登录范围摘要（`connection.rs:2793-2803` `login_scope_digest`） | `port.to_le_bytes()`，i32 | 不截断；出口标记随摘要锁住（A4） |
| CM（`try_start_cm` 经 IPC 发整串；`flutter/lib/desktop/pages/server_page.dart:524-528` 显示） | 字符串 | 02 改成显示"作为出口"（F2） |
| 1.5.0 以前原版被控端的裸管道 `TcpStream::connect(&addr)`（现树 `connection.rs:1821` 同一写法） | std 在最后一个冒号处切开，端口按 u16 解析 | 65536 报 `InvalidInput`，不发 DNS 查询【推测，按 std 实现推断，S0 的单测钉住】 |

**A3**（服务端不再把控制端的 API 令牌转给被控端）已单独合入，见 `server/LEAPGATE.md` §6 第 8 条，本契约不再展开。

**统稿时取定的几处**（清单没写死，或三块起草时提出；主会话可以推翻）：
1. **登录关口用守卫分支**。上游端口转发分支里 `enable-tunnel` 的检查在规范化之前（`connection.rs:2970`），关口写进那个分支就等于要求 `enable-tunnel`，违反 A5。所以 02 在登录 `match lr.union` 里、上游 `Some(login_request::Union::PortForward(mut pf)) => {`（`connection.rs:2969`）之前另加一个分支，分支里先规范化、再过关口；这就是清单说的"写在规范化之后"，契约只保留这一种写法：
   ```rust
                   // leapgate: an exit login passes the exit gate, not enable-tunnel (phase 4 A5, A11)
                   Some(login_request::Union::PortForward(mut pf)) if leapgate::exit::is_exit_target(&pf.host, pf.port) => {
                       (self.port_forward_address, _) = Self::normalize_port_forward_target(&mut pf);
                       if let Some(err) = leapgate::exit::login_refusal(pf.multiplex, self.stream.is_secured()) {
                           self.send_login_error(err).await;
                           sleep(1.).await;
                           return false;
                       }
                   }
   ```
   位置在 IP 白名单（`connection.rs:1507`）和 ID 白名单（`:2923`）之后、密码校验和审批之前，符合 A11 的顺序。
2. **B10 和 B12 的文案数**：B10 要把"被控端所在网络的 DNS 返回了 fake-ip 地址"告诉控制端，B12 在 C5 (A) 下只给两条固定文案。统稿把这层意思并进策略拒绝那条（§2.4 `MSG_BLOCKED`），不加第三条。
3. **C3 ③ 的实际表现**：清单写对方会看到"一闪而过"的卡片，这只在密码模式下成立；点击确认模式下卡片等主人批准，批准后控制端拿到 PeerInfo、发现没有出口位才断开。决定本身不变，兼容表照实际写（§5）。
4. 两个新 key 不进 `KEYS_SETTINGS`（定制客户端可以预设的 key 表，`libs/base/src/config/keys.rs:272`）：没有预设出口的需求。
5. `libs/leapgate` 版本 0.3.1 → 0.4.0，放在 S0（§2.6）。服务端不按版本判断出口（01 §2.4），只作标识。

## 2. 两端共用的接口

### 2.1 哨兵登录目标
- 值见 §1.4。判断只用 `leapgate::exit::is_exit_target(host, port)`：host 和 port 都精确相等，大小写不同、结尾带点、端口不同都不算。被控端只在两处调它，拿的都是规范化之前的原始 `pf`：登录守卫分支（§1.4 第 1 条），以及 `connect_port_forward_if_needed` 建好 mux 之后的挂钩（`connection.rs:1806` 取出的 `pf`）。挂钩判为真时，把控制端 ID 写进 mux 的 `leapgate_exit` 字段（§3.1 的 M-1）。`on_open` 和 B8 的每秒定时器只看 `leapgate_exit.is_some()`，不比字符串。规范化后的 `leapgate-exit.invalid:65536` 只当 `port_forward_address` 和 CM 显示值用；CM 拿到的是这个整串，用 Dart 的 `isLeapgateExitAddress` 判（§2.6）。
- 标记只用来选模式，不是授权依据（C1）。ConnType 照旧填 PORT_FORWARD。
- 出口模式下，open 帧里的目标就是本地代理收到的目标（SOCKS5 的域名或 IP、CONNECT 的 authority，IPv6 不带方括号）。被控端不规范化、不和登录目标比（C2）；端口不在 1~65535 时按原因码 `invalid_target` 拒（B12）。open 帧只带 `host` 字符串、没有地址类型，被控端先 `host.parse::<IpAddr>()`（std 的严格写法），能解析的一律按 IP 字面量走 B3、不经 DNS，198.18/15 的就是 `fake_ip_literal`，不管控制端用的是 SOCKS5 哪种 ATYP 还是 CONNECT；解析不了的才当域名，按 B1、B2 解析。

### 2.2 `Features.leapgate_exit`
`libs/base/protos/message.proto:100-104` 的 `Features` 加一行，并在消息上方注明号段：
```proto
  // Leapgate fields use 1000-1999.
  bool leapgate_exit = 1000;
```
只动客户端独有的 `libs/base`，不碰 cardo（leapgate-cardo，hbb_common 的 fork）。被控端在端口转发会话的 Features 字面量里恒填 true（`connection.rs:2027-2031`，02），意思是"本构建能处理出口登录"；控制端登录后从 `lc.peer_info` 读（03 §2.2）。原版和第三期被控端不发，读到 false。

### 2.3 出口开关、放行网段和两个判定函数
- `leapgate-allow-exit`：存 Config，不存 LocalConfig（被控端服务进程读不到界面进程写的 LocalConfig）。只有值为 `"Y"` 才算开，空值和其他值都算关；设置卡片取消勾选时写 `"N"`（F2）。不经 `permission()`、`is_permission_enabled_locally`、`option2bool`，不映射进 ControlPermissions（会合报文里的权限位图），不看 access-mode（"完全访问 / 仅共享屏幕 / 自定义"），不要求 `enable-tunnel`（A5、A7）。
- `leapgate-exit-allow-nets`：存 Config；CIDR 或单个地址，用逗号、空白或换行分隔，不带端口、不写域名；只能打开 B3 的软拒档（B4）。心跳不上报（D1）。
- 两个 key 服务端策略都写不了（A7）。判断 `leapgate-` 前缀的函数只有一个，由 02 放进已经是 pub 的 `libs/leapgate/src/options.rs`：`pub fn is_leapgate_local_option(key: &str) -> bool`。Leapgate 心跳的 `merge_strategy` 本来就跳过 `leapgate-` 开头的 key（`libs/leapgate/src/report/heartbeat.rs:281`），02 把那处改成调它；上游回落路径 `src/hbbs_http/sync.rs:296` 的 `handle_config_options` 开头由 02 加一行，也调它（`report/mod.rs:12` 的 `mod heartbeat;` 是私有的，函数放在 heartbeat.rs 里 sync.rs 调不到）。leapgate-server 的 `strategy set` 本来就拒收（D10）。
- `leapgate::exit::allowed() -> bool`：`cfg!(windows) && Config::get_option("leapgate-allow-exit") == "Y"`（非 Windows 恒假：出口要用的 `lan::nics()` 只有 Windows 实现）。心跳的 `exit`、登录关口、每个 open、每秒定时器的断开检查（B8）都只调它（D6），不另写判断。
- `leapgate::exit::login_refusal(multiplex: bool, secured: bool) -> Option<&'static str>`：函数体就是 `refusal(allowed(), multiplex, secured)`。私有纯函数 `fn refusal(enabled: bool, multiplex: bool, secured: bool) -> Option<&'static str>` 依次查 `enabled`、`multiplex`、`secured`，返回 §2.4 对应的文案，全过返回 `None`（A11、C10）。

### 2.4 被控端回的固定文案
英文是线上原样（常量在 S0 的 `exit/mod.rs`），控制端经上游 `translate` 显示，中文放 `libs/leapgate/src/lang.rs`（F6）。opened 失败文案靠上游现成的去重（`src/port_forward_mux.rs:651-674`：同一文案 10 秒只弹一次，最多记 8 种；空文案不弹，`:660`），所以都不带地址。被控端日志（B7）按原因码记，和这里无关。

| 常量 | 英文原文 | 中文 | 何时 |
|---|---|---|---|
| `MSG_NOT_ENABLED` | `Exit node is not enabled on the remote device` | 对方设备没有开启出口 | 登录错误：开关不是 `"Y"` |
| `MSG_NEED_MUX` | `The remote device only accepts multiplexed port forwarding. Update your client and turn on "Reuse one connection for port forwarding" in its settings` | 对方设备只接受多路复用的端口转发。请升级客户端，并在设置里打开"端口转发复用同一条连接" | 登录错误：出口登录不是多路复用（A11）；任何不是多路复用的端口转发登录（B5，对所有端口转发生效）。选项名照上游设置页（`desktop_setting_page.dart:558`，中文 `src/lang/cn.rs:769`） |
| `MSG_NEED_ENCRYPTION` | `The exit node only accepts encrypted connections` | 出口只接受加密的连接 | 登录错误：流没加密（C10） |
| `MSG_NOT_ENABLED`（同第一行） | 同第一行 | 同第一行 | opened 失败：出口隧道上 `allowed()` 为假（会话中途关了开关）。按文案去重，只弹一次；被控端日志不记目标；整条会话随后由 B8 的每秒定时器断开。实现见 §3.1 的 M-2 |
| `MSG_BLOCKED` | `The exit node blocked this destination: it is on the remote device's local network or is the device itself, or the remote network's DNS returned a fake-ip address` | 出口拒绝了这个目标：它在对方的局域网里或就是对方设备本机，或者对方网络的 DNS 返回了 fake-ip 地址 | opened 失败：原因码 `reserved`、`loopback`、`link_local`、`local`、`lan`、`fake_ip` |
| `MSG_FAKE_IP_LITERAL` | `The destination is a fake-ip address from this computer's proxy software. Set the program to resolve names through the proxy (socks5h)` | 目标是本机代理软件分配的 fake-ip 地址，请在程序的代理设置里改用远程 DNS（socks5h） | opened 失败：`fake_ip_literal`（C12） |
| 空串 | — | — | opened 失败：`invalid_target`、`nxdomain`、`resolve_failed`、`no_route`、`timeout`、`refused`、`unreachable`，控制端不弹框 |

出口通道连接失败时不走上游 `server/port_forward_mux.rs:227` 的 debug 行和 `:228` 的 `unreachable_message`（前者把目标写进日志文件，后者的文案带目标地址、让去重失效），由 M-5 的挂钩按原因码回上表的文案（§3.1）。

### 2.5 心跳、能力宣告和目录接口（细节以 01 §2 为准）
- 签名心跳 `POST /api/leapgate/v1/heartbeat` 的请求体加 `exit`（bool）：`allowed()` 为真才带 `"exit": true`，否则不带；服务端只放内存（01 §2.1）。填写在 `report/heartbeat.rs` 的 `Req` 和 `body()`，归 02。
- 心跳响应的 `features` 变成 `["ice", "exit"]`；`"exit"` 只表示服务端有目录接口。控制端用 `leapgate::report::has_feature("exit")` 判断，为假时不发目录请求、也不靠 404/405 猜（01 §2.2，F3）。
- `GET /api/leapgate/user/v1/exits`，头 `Authorization: Bearer <用户令牌>`，成功 200 `{"exits":[{"id","hostname","owner","own"}]}`（空列表 `{"exits":[]}`，`hostname`、`owner` 可能是 `""`）。客户端只把"200 且带 `exits` 数组"当成功，401 当"没登录或登录已失效"，其余一律当网络错误；不签名，只在打开目录时取一次（01 §2.3，03 §3.4）。
- 可用判据：UDP 注册在 30 秒内、最近一次签名心跳在 180 秒内、`exit` 为真，三条同时成立（01 §2.4，D6）。

### 2.6 共用骨架提交 S0（客户端）
两侧共用的东西先做成一个小提交 S0，合进 leapgate-client main 之后 02、03 再从它开分支，各改各的文件：
- `libs/base/protos/message.proto`：§2.2 的字段。
- `libs/leapgate/Cargo.toml` 版本 0.4.0；`Cargo.lock` 只改 leapgate 那一项的版本号（`Cargo.lock:4348`）；`libs/leapgate/src/lib.rs` 加 `pub mod exit;`、`pub mod lang;`。
- `libs/leapgate/src/exit/mod.rs`：声明子模块 `pub mod dial;`（02：B1、B2、B11；主 crate 的 M-3~M-5 要用 `dial::Target`、`connect`、`failure_message`）、`mod policy;`（02：B3、B4、B12，只有 `dial` 用）、`pub mod directory;`、`pub mod proxy;`（03，主 crate 的 `src/leapgate_hooks/exit.rs` 要用），四个空文件一并建好；常量 `SENTINEL_HOST`、`SENTINEL_PORT: i32 = 65536`、`OPTION_ALLOW_EXIT`、`OPTION_ALLOW_NETS`、§2.4 的五条文案；函数 `is_exit_target`、`allowed`、`login_refusal` 和私有纯函数 `refusal`。单测：03 §5.1 的 T8（含 std 解析 `leapgate-exit.invalid:65536` 返回 `InvalidInput`）、`refusal` 的三项顺序（八种组合，纯函数，不读写 Config；`allowed()` 只认 "Y" 靠审查把关）。
- `libs/leapgate/src/lang.rs`：`pub fn get(lang: &str, key: &str) -> Option<&'static str>`，只在 `lang == "zh-cn"` 时查两张静态表 `CONTROLLER`（03 填；S0 先放 §2.4 的五条）和 `CONTROLLED`（02 填，S0 为空）。`get()` 先查 `CONTROLLER` 再查 `CONTROLLED`，两张表的 key 合起来不得重复。文件里依次是 `CONTROLLER`、`get()`、`CONTROLLED`、`#[cfg(test)] mod tests`；T10（两张表合起来 key 不重复、中文非空、每条中英文的 `{}` 个数相同）由 S0 写进这个 tests 模块，02、03 只往各自的表里加行，都不改 tests 模块。带 `{}` 的条目照上游占位规则（`src/lang.rs:297-314`）。
- `src/lang.rs` `translate_locale` 的挂钩：03 §3.7 的 H-3 原样挪进 S0（286 行之后、287 行 `if lang != "en" {` 之前）。
- `flutter/lib/leapgate/exit_tunnel.dart`：只放 `kLeapgateExitHost`、`kLeapgateExitPort = 65536`、`bool isLeapgateExit(String host, int port)` 和 `bool isLeapgateExitAddress(String addr) => addr == '$kLeapgateExitHost:$kLeapgateExitPort';`；03 之后往里加控件。CM（`server_page.dart:524-528`，拿到的是整串 `client.portForward`）用 `isLeapgateExitAddress(client.portForward)`，TCP 隧道页（03）用 `isLeapgateExit(host, port)`。

## 3. 分块和文件表

### 3.1 各块的文件
| 块 | 仓库 | 新文件 | 改的 Leapgate 自有文件 | 上游文件挂钩 |
|---|---|---|---|---|
| S0 | leapgate-client | `exit/mod.rs` 及四个空子模块、`lang.rs`、`exit_tunnel.dart`（只有常量） | `libs/leapgate/src/lib.rs`、`Cargo.toml`、`Cargo.lock`（只改 leapgate 那一项的版本号，`:4348`） | `message.proto` 1 个字段；`src/lang.rs` H-3 |
| 01 | leapgate-server | `src/api/exit.rs`、`migrations/0007_exit_grant.sql` | 硬分叉，不分自有和上游：`api/mod.rs`、`api/device.rs`、`api/account.rs`、`api/group.rs`、`peer.rs`、`ice_signal.rs`、`main.rs`、`cli/mod.rs`、`cli/manage.rs`、`cli/ops.rs`、测试里两处字面量、`LEAPGATE.md`（01 §3.1） | — |
| 02 | leapgate-client | `exit/policy.rs`、`exit/dial.rs` 的内容；共用 DNS 模块（`ice/dns.rs` 挪成 `libs/leapgate/src/dns.rs`，B2）；`flutter/lib/leapgate/exit_settings.dart`（设置页的 part 文件） | `lib.rs`（加 `dns` 模块）、`ice/`（改用共用 DNS 模块，B11 复用 STUN 探测）、`lan.rs`（IPv4 前缀长度，B3 要本机链路网段；`Nic` 另加一个字段，收本机全部 IPv6 单播地址，不看 DadState、含已弃用的临时地址，在 `nics()` 的 `:425`（IPv4 的 `extend`）旁加一行 extend，和 IPv4 的收法一致，供 B3 的"本机所有网卡地址"硬拒用。现有 `ipv6` 字段的 Preferred 筛选不改：ICE 收候选（`ice/gather.rs:81`）和 `is_physical` 用它）、`options.rs`（A7 的共用判断函数 `is_leapgate_local_option`，§2.3）、`report/heartbeat.rs`（`exit` 字段，`merge_strategy` 改调 options 里的判断）、`lang.rs` 的 `CONTROLLED` 表、`Cargo.toml`（`cidr-utils = "0.5"`，主 crate 已有同版本）、`Cargo.lock` | `connection.rs`：登录守卫分支（§1.4）、B5 一处（上游端口转发分支 `enable-tunnel` 检查之后）、`connect_port_forward_if_needed` 建 mux 之后一行（M-1）、Features 一行、B8 每秒定时器约 3 行；`server/port_forward_mux.rs`：M-1~M-5 五处（见表下）；`sync.rs:296` 一行；`desktop_setting_page.dart` 2 行；`server_page.dart` 1 处判断（`isLeapgateExitAddress(client.portForward)`）加 1 行 import |
| 03 | leapgate-client | `exit/proxy.rs`、`exit/directory.rs` 的内容；`src/leapgate_hooks/exit.rs` | `exit/mod.rs`（控制端常量和 `after_login`）、`api.rs`（`get_user`）、`lang.rs` 的 `CONTROLLER` 表、`exit_tunnel.dart`（控件）、`flutter/lib/leapgate/exit_nodes.dart`（新）、`src/leapgate_hooks.rs`（`pub(crate) mod exit;`） | `ui_session_interface.rs` H-1、`flutter_ffi.rs` H-2、`port_forward.rs` H-4/H-5（C11）、H-6 和 V-1~V-3、`port_forward_page.dart` 约 15 行、`connection_page.dart` 菜单 1 项加 1 行 import（03 §3.7、§3.8） |

02 在 `server/port_forward_mux.rs` 的五处改动写死如下（行号对照 `a57605c2f`；为什么允许改上游语句见 §3.2）：
- **M-1**：`struct PortForwardMux`（`:34-41`）加字段 `pub(super) leapgate_exit: Option<String>`（出口隧道时是控制端 ID，否则 `None`），`new()`（`:44-51`）里加一行 `leapgate_exit: None,`；`new` 的签名和 `connection.rs:1814` 的调用都不改。`connection.rs` 的 `connect_port_forward_if_needed` 在 `:1815` `});` 之后、`:1816` `return` 之前插一行：用 `:1806` 取出的原始 `pf` 判 `leapgate::exit::is_exit_target(&pf.host, pf.port)`，为真时把 `self.lr.my_id` 写进这个字段。B8 定时器也看这个字段。
- **M-2**：`on_open` 在 `:107` `retain` 之后、`:108` `if !permitted` 之前插入两句。第一句：出口隧道且 `leapgate::exit::allowed()` 为假时，回 `opened_msg(id, false, MSG_NOT_ENABLED, 0)` 并返回（B8，§2.4）。第二句：`let permitted = permitted || self.leapgate_exit.is_some();`（出口不看 enable-tunnel，A5）。纯插入。
- **M-3**：`on_open` 的 `:120-136`：出口隧道时不调 `normalize_port_forward_target`、不做 `:128` 的比较，具体是改 `:125`、`:128` 两行（条件里加出口判断）；另在 `:149` 的 spawn 之前插一句 `let exit_target = …`，用 `pf.host`、`pf.port` 和控制端 ID 组成 `Option<exit::dial::Target>`（出口时没有规范化，这两个就是 open 帧里的原值；`open.host` 已经在 `:121` 移进了 `pf`），由 M-4 作为多出的那个实参传给 spawn。不复制 `:138-158` 的建通道代码。
- **M-4**：`run_controlled_channel` 签名（`:185-194`）加一个出口目标参数（`Option<…>`，类型定义在 `exit/dial.rs`），`:149` 的 spawn 多传 M-3 组好的 `exit_target`。`:197` 在出口时换成 `exit::dial` 的连接（B1：解析 2 秒、连接 8 秒、整体 10 秒；普通转发的 3 秒不变），两种连接装成同一个 future 类型。
- **M-5**：`run_controlled_channel` 里连接完成的那个 select 臂（`:221` `res = &mut connect => {`，成功和失败都进这里）之内、`:222` `let err = match res {` 之前插入：出口通道调 `leapgate::exit::dial::failure_message(&res)`，返回 `Some(文案)` 时发 `opened_msg(id, false, 文案, 0)`（文案是 §2.4 的 `MSG_BLOCKED`、`MSG_FAKE_IP_LITERAL` 或空串）后 return；连接成功时它返回 `None`，照常走 `:223` 的 `Ok(Ok(s)) => break s`。必须插在 `:222` 之前，因为那里的 `match res` 按值绑定、把 `res` 移走了，错误也在 `:224-225` 变成了字符串，再往后就拿不到原因码。这样出口通道失败时不走 `:227` 的 debug 行和 `:228` 的 `unreachable_message`。拒绝日志由 `exit::dial` 按 B7 打，限频 warn，格式 `leapgate exit: <控制端 ID> refused <ip>:<port> (<原因>)`，普通失败只打 trace。

proto 只在 `libs/base`，三块都不动 cardo，不需要两条 cardo 线的 proto 提交。

### 3.2 两侧共用文件的规矩
- `exit/mod.rs`：S0 之后只有 03 往里加东西；02 的全部代码放 `policy.rs`、`dial.rs`，不改 `mod.rs`。
- `lang.rs`：02 只改 `CONTROLLED` 表，03 只改 `CONTROLLER` 表，两张表之间隔着 `get()`，合并不会冲突。02 不得用 `CONTROLLER` 里已有的 key（如 `Exit node`、`Exit nodes`）另配中文，要另起 key。
- `lib.rs`、`Cargo.toml`、`Cargo.lock`：S0 之后只有 02 改。`src/leapgate_hooks.rs`：只有 03 改。`exit_tunnel.dart`：只有 03 改，02 只 import。
- 上游文件两侧没有重叠。F7 例外清单就是上表"上游文件挂钩"一列里的四个 Dart 文件和 `ui_session_interface.rs`、`flutter_ffi.rs`、`lang.rs` 三处界面挂钩，新 Dart 文件都放 `flutter/lib/leapgate/`。超出清单的上游界面改动要维护者同意。
- 本期上游 Rust 的非界面改动：`connection.rs`、`server/port_forward_mux.rs`、`sync.rs`（02），`port_forward.rs`（03）。合并上游正式版本前要再查一次 `port_forward_mux.rs`、`server/port_forward_mux.rs`、`port_forward.rs` 有没有被改（清单"写契约前还缺的事实"最后一条）。
- `server/port_forward_mux.rs` 是 C8 下允许的上游修改：除了 03 在 `port_forward.rs` 的 V-1~V-3（只改可见性）和 H-6（一处绑定改名、`LoginOutcome` 加一个字段、返回值带上它），它是本期唯一既插入、又改上游语句（函数签名、条件、调用实参）的非界面 Rust 文件（C8 不许另写一份通道处理）。改动以 §3.1 的 M-1~M-5 为限，超出要维护者同意；合并上游时，冲突面就是这五处。
- `client/LEAPGATE.md`：由主会话在 02、03 都合入后，在 leapgate-client 上单独一个提交一次改完（§8.2），02、03 的 coder 都不改它。

## 4. 实施顺序

| 步 | 内容 |
|---|---|
| 0 | 整份契约经维护者确认；同时按 §8.1 改架构和笔记，和契约用同一个提交 |
| 1 | S0 合进 leapgate-client main（不挪子模块指针，S0 不改任何行为） |
| 2 | 三路并行：01 在 leapgate-server 的 `p4/exit` 分支；02 在 leapgate-client 的 `p4/exit-controlled`，03 在 `p4/exit-controller`，都从 S0 开。03 的第一个提交单独做 C11（H-4、H-5 和它们用的两个常量），出口相关的放后面的提交 |
| 3 | 各块单测、审查后合进各自 main（merge，不 rebase main）。客户端 03 审完就可以合；02 要等 B15 (a)(b) 有了记录才合（控制端要用能开出口通道的 03 分支构建，见下面的"风险"）。后合的一方变基；按 §3.2 不会有文本冲突。01 和客户端之间没有编译依赖，合入先后不限（01 §4） |
| 4 | 三块都合入后跑一次联合冒烟（§6.1；B15 (a)(b) 在 02 合入前已经跑过，沿用记录） |
| 5 | 总仓库挪子模块指针：服务端在 01 合入后挪一次；客户端在 02、03 都合入后，主会话先在 leapgate-client 上单独一个提交改完 `client/LEAPGATE.md`（§3.2），再挪一次指针。提交说明英文；同时按 §8.2 同步文档 |

风险：02 的 B2（连接绑物理网卡地址、DNS 问那块网卡自己的服务器）有一个前提还没验证：被控端开着 fake-ip TUN 时，绑物理网卡地址的出站 TCP 会不会绕过 TUN（第三期只测过 UDP）。所以 B15 (a)(b) 不等联合冒烟，在 02 合入 leapgate-client main 之前先跑：被控端用 02 分支的构建，控制端用 03 分支的构建。两条分支都从 S0 开，各自就能编，不做临时合并，也不写测试驱动。这一步算开发期那一次冒烟的前置部分，联合冒烟（第 4 步）沿用它的记录、不重跑。(a) 不成立，或 (b) 出现经本机代理或 VPN 绕过地址过滤的结果（02 §5.2），02 就不合入，B2、B9 回到设计关卡；strict-route 挡住物理网卡的 DNS 属于 B10 的已知限制，只记录。

## 5. 兼容矩阵

| # | 组合 | 结果 | 依据 |
|---|---|---|---|
| ① | 两端第四期，出口开着 | 正常 | C3 |
| ② | 被控端第四期，出口关着（或登录不是多路复用、流没加密） | 密码校验和审批之前回 §2.4 的登录错误；控制端弹 "Login Error"，这条出口监听关闭 | A11、C9 |
| ③ | 被控端是原版 1.5.0 以上，或第三期及以前的 Leapgate | 照常过认证：密码模式下登录后控制端发现没有出口位立即断开，对方的连接卡片一闪而过；点击确认模式下对方看到目标为 `leapgate-exit.invalid:65536` 的端口转发卡片等批准，批准后同样立即断开。控制端弹"对方设备不支持作为出口"，监听关闭，一个通道都不开 | C3、§1.4 第 3 条 |
| ④ | 被控端是 1.5.0 以前的原版 | 它不认 `multiplex`、走裸管道，分版本表现不同。两种都不查 DNS，监听都关闭；`enable-tunnel` 关着时，两种都在密码校验之前回 "No permission of IP tunneling"。**1.4.6~1.4.9**：认证通过后（点击确认模式下，主人先看到目标为 `leapgate-exit.invalid:65536` 的审批卡片），在 `connect_port_forward_if_needed` 里连，端口解析失败，回登录错误 "Failed to access remote leapgate-exit.invalid:65536. Please make sure it is reachable/open."。**1.4.5 及以前**：在登录分支里、密码校验之前就连，不弹审批，当场回 "Failed to access remote leapgate-exit.invalid:65536, please make sure if it is open"。Leapgate 控制端对这类被控端的普通映射和 RDP，照旧按 C11 报"对方版本过旧" | C3、C11 |
| ⑤ | 原版或旧版控制端连第四期被控端 | 发不出出口请求；多路复用的普通端口转发照旧；不是多路复用的（1.5.0 以前的原版、关掉复用选项的控制端）按 B5 回 `MSG_NEED_MUX`，被控端不弹审批 | B5、B13 |
| ⑥ | 服务端是原版 hbbs（含配 rustdesk-api）或第四期以前的 leapgate-server | 出口照常能用（手填 ID），只是没有目录：`has_feature("exit")` 为假，目录对话框显示"当前服务器不提供出口目录"、不发请求 | C3、F3、01 §4 |
| — | 第四期服务端，原版或第三期被控端 | 不发 `exit`，永远不进目录 | 01 §4 |
| — | 第三期 Leapgate 控制端，第四期服务端 | `features` 里的 `"exit"` 只存不用 | 01 §4 |
| — | 两端第四期，流没加密（没配 Key、直接 IP 访问） | 被控端按 C10 拒；不是直接 IP 访问时，控制端先弹一次上游的"不安全连接"确认框 | C10 |
| — | 控制端用"ID@其他服务器" | 出口照常能用；目录只在自己的服务端上，不涉及 | 清单"明确不做" |
| — | 任何服务端下发策略 | 写不进两个出口 key（Leapgate 心跳、上游回落路径、`strategy set` 三处都挡） | A7、D10 |

## 6. 测试与验收

### 6.1 开发期：每块单测加一次冒烟
- **单测**：S0 见 §2.6；01 见 01 §5.1（Linux 测试机 `cargo test`，含变异验证）；03 见 03 §5.1；02 见 02 §5.1，至少包括：B3 分类函数按每一类地址的穷举表（含 `::ffff:0:0/96` 映射、`64:ff9b::/96`、Teredo、6to4、本机地址（其中一项用构造的 `Nic` 数据：某个 IPv6 地址只出现在新的全部单播字段里、不在 `ipv6` 里，模拟已弃用的临时地址，它所在的 /64 写进放行列表后，仍按 `local` 硬拒）、198.18 字面量和解析结果分开）、B4 放行列表的解析和"打不开硬拒"、B1 的过滤与 Happy Eyeballs 顺序（用假解析结果，不连网）、不带方括号的 IPv6 "host:port" 在 std 里的解析（清单更正事实第 1 条，钉一个单测）；回落系统解析（用假解析结果钉住：回落系统解析得到的地址和网卡 DNS 的结果走同一个 B3 分类函数、同一套"丢掉被拒的、只连通过的"处理；输入要含严格 IP 解析会拒、系统解析器却能给出地址的主机串，如带区域 ID 的 IPv6 `fe80::1%2`、`127.1` 这类非标准 IPv4，它们解析出来的地址照样按硬拒类别拒）；M-5 用的原因码映射（把原因码映射成 opened 文案的纯函数，对 B12 的每个原因码都只回 §2.4 那几条固定文案之一或空串，不含目标）。
- **冒烟一次**（三块都合入后一起跑，B15 (a)(b) 除外，它们在 02 合入前跑，见 §4 风险；Linux 测试机起第四期服务端，两台第四期 Windows 客户端，被控端开出口）：01 §5.2 的四项、03 §5.2 的五项，加上 B15 的五项（(a)(b) 抄录 02 合入前的记录）和下面"关开关"一项。另备三样端点，各用在一项：第三期 Leapgate 便携版被控端（03 §5.2 第 3 项）；1.5.0 以前的原版控制端，或关掉"端口转发复用同一条连接"的上游 1.5.0 以上控制端（B15 (e)）；第三期服务端二进制（01 §5.2 第 4 项）。判据：
  - (a) 被控端开 mihomo fake-ip TUN，strict-route 开、关各一次：经出口访问一个回显来源 IP 的公网服务，看到的是被控端宽带出口的地址，不是代理节点的地址；代理软件的连接列表里没有这条连接。这一项和 (b) 在 02 合入前跑，不成立时 02 不合入（§4 风险）。
  - (b) 同样两种情况下，用域名目标经出口能连上，被控端日志没有 `fake_ip` 原因的拒绝行。strict-route 开时如果被挡（B10 的已知限制），记下结果、写进已知限制，不算失败。
  - (c) 被控端所在网络的路由器给局域网的 DNS 是否回 198.18.x：记下结果。是的话域名目标按 B10 被拒、弹 `MSG_BLOCKED`，IP 字面量照常能用，属预期。
  - (d) 私网地址、被控端本机地址、被控端本机公网 IPv4、169.254.169.254 都被拒：控制端看到连接被关并弹一次 `MSG_BLOCKED`；被控端日志里出现过 `leapgate exit:` 前缀的拒绝行（B7 的限频下 60 秒内只有第一类的那一行）。
  - (e) 用 1.5.0 以前的原版控制端，或关掉"端口转发复用同一条连接"的上游 1.5.0 以上控制端连一次端口转发（被控端的"允许建立 TCP 隧道"开着；关着时上游先回 "No permission of IP tunneling"）：收到 `MSG_NEED_MUX`，被控端不弹审批（Leapgate 控制端在 C11 之后发不出裸管道，测不了这一项）。
  - 关开关（B8、F2、A5）：出口会话进行中关掉被控端的出口开关：1~2 秒内控制端日志出现 `port forward tunnel ended`；下一个本地连接重建隧道时弹 `MSG_NOT_ENABLED`，监听关闭。会话期间被控端 CM 卡片显示"作为出口"。把访问模式切到"仅共享屏幕"后，设置卡片的勾选不变，出口照常能用（A5）；关掉被控端的"允许建立 TCP 隧道"后，出口照常能开通道（A5）。
  - 经出口的这些项里，至少一次是 ICE 胜出（控制端日志有 `leapgate ice: selected`）。
  - 顺手记一下下载速度（E1），只记不判。

### 6.2 统一验收（开发全部完成后，无人值守）
- **E1 吞吐**：ICE（第三期自研的直连）和强制中继两条路径，各测单流下载、4 个并行下载、单流上传，工具用 Windows 自带的 `curl.exe --socks5-hostname`。设 F = 256 KiB ÷ RTT，U 为不经隧道直接上下载的基线速度。单流达到 0.8 × min(F, U) 算符合预期；F < U 且单流低于 30 Mbit/s 时，先把窗口调到 512 KiB 复测，最多到 1 MiB（调大时 `UPDATE_THRESHOLD` 钉成字面量 128 KiB，E2）；单流低于 0.6 × min(F, U) 说明瓶颈在窗口之外，窗口不动、另立问题。同一轮核对 hbbr 的 `SINGLE_BANDWIDTH=256`（01 §5.3）。测完把 architecture §3.9 的吞吐数字换成实测值。
- **E7**：8 条下载跑满被控端上行时，新开一个通道到收到首字节的时间。只测量，结果写进已知限制。
- **局域网保护的穷举**：B3 的每一类地址各找一个真实目标（本机地址那一类另加一个被控端已弃用的临时 IPv6 地址，可用 `Get-NetIPAddress -AddressState Deprecated` 查到），分别用 IP 字面量和"解析到它的域名"（含把 IP 写进域名的公共 DNS 服务，模拟 DNS 重绑定）走一遍；答案里同时有被拒和允许的地址时只连允许的；放行列表逐一打开每个软拒类别、确认打不开任何硬拒类别；198.18 字面量回 `MSG_FAKE_IP_LITERAL`。在被控端不开 TUN、开 fake-ip TUN 两种环境各跑一轮，有路由器 fake-ip 的网络时再加一轮。
- **兼容矩阵逐格**：§5 每一行实测一次，结果和"结果"一列逐字对照。
- 安装版（服务进程）和便携版被控端各跑一轮 B15 (a)(b)(d)：出口连接由哪个进程、哪个账户发出会影响 DNS 和 TUN 是否接管（清单"写契约前还缺的事实"）。被控端开全隧道 VPN（例如 Tailscale 用了 exit node）时再跑一轮 B15 (a)：回显服务看到的是被控端宽带出口的地址，不是 VPN 出口的地址（B9，清单"写契约前还缺的事实"第 4 条）。控制端、被控端各有一台开着默认 Windows 防火墙。
- 01 §5.3、03 §5.3 列的其余项（服务端重启后目录恢复、控制端开 fake-ip 时各浏览器是否把域名交给代理、几十个并发连接、空闲一小时以上、窗口最小化、只设临时密码或点击确认时的隧道重建、不安全确认框路径）。

## 7. 明确不做、已知限制（汇总，正文在各块）

**明确不做**（清单"明确不做"一节为准）：
- UDP 出口；全局出口（编排 Tailscale/Headscale）、自研虚拟网卡 VPN、嵌入 tsnet 或 wireguard-go；Windows 以外的平台。
- 服务端签发出口凭证、免密码使用出口（A2 选 (a)，D12）；在会合信令上拦截出口连接；出口映射进 ControlPermissions；让原版控制端用出口、出口走裸管道。
- "设为系统代理"和"用出口打开浏览器"（C7）；等 opened 再应答（C5 (B)）；SOCKS4、SOCKS5 认证、UDP ASSOCIATE、HTTP 普通代理和 PAC；本地代理开给局域网；按域名分流、多出口负载均衡（03 §6）。
- 改 hbbr 代码、只给出口放宽限速、月流量机制（E3）；网页后台、配额计费；会话中途换中继；D15 的八项（01 §6）。
- 改 `enable-tunnel` 默认值或 access-mode 对其他权限的语义；改 `CHANNEL_WINDOW`（E2）和 `relay-fallback-delay` 的界面（E8）；在新界面轨道里做出口界面。
- 02 的明确不做（按清单 B 组）：不按目标端口限制（B14），不另设出口会话数、并发数和通道空闲超时（B6），不上报服务端审计（B7），出口不经本机代理（B9）。

**已知限制**（标题，正文见 01 §7、03 §7、02 §7）：
- 授权：目录不是关口，撤销授权不断开已有会话、挡不住知道密码的人；做不到只给出口不给远控；被控端看到的控制端身份都是自报的，出口审计落不到账号（A2）。A3 之前已经泄露的令牌仍有效（A3）。访问模式设成"仅共享屏幕"不关出口（A5）。
- 局域网保护只约束出口模式，密码持有者照样能用普通端口转发碰局域网（A8、C15）；家宽 IPv6 前缀会变，按全局 /64 写的放行第二天就失效（B4）；路由器 fake-ip 网络里默认用不了域名，非默认 fake-ip 网段判不出，本机 strict-route 可能挡住物理网卡的 DNS（B10）；IPv6 只认本机地址所在的 /64，同一委派前缀下的其他 /64 和路由器 WAN 侧的 IPv6 地址按公网放行（02 §7）；查不到本机公网 IPv4 时少一条硬拒（B11）。
- 出口从物理网卡出去：经出口进不了主人公司的内网，被控端网络打不开的网站经出口也打不开（B9）。
- 资源和吞吐：被控端单会话最坏缓存两个方向各约 64 MiB、主循环卡在一次发送上最多 120 秒（B6），这段时间里 B8 关开关后的断开也会跟着推迟，1~2 秒只在正常负载下成立；发送队列共用（E7）；队头阻塞、KCP 不做拥塞控制、隧道不换路径（E4）。
- 控制端：本地端口不认证（A10）；乐观应答（C5 (A)）；不安全确认框（C10）；连接状态不随断开更新（F4）；10 秒冷却（C9）；空闲不拆、经中继时一直占一对 hbbr 连接（C14）；重建要照上游认证（A6）；C11 之后对 1.5.0 以前的原版做不了端口转发和 RDP；Chrome、Edge 要装扩展或带启动参数（C7）；建隧道期间删除这条出口映射，要等登录结束才停（关窗口不受影响，03 §7 第 14 条）；普通映射和 RDP 经 KCP 时登录后即失效（03 §7 第 15 条）。
- 服务端：状态延迟、只列 UDP 注册在线的设备、已锁定设备换主人要先登出、ID 被继承等（01 §7 的 12 条，含第 12 条：没有主人的已锁定设备，登录先到先得）。

## 8. 要同步的文档

`AGENTS.md` 的状态行由主会话写，不归任何一块。

### 8.1 随契约定稿同步
派 coder 之前改完，和契约用同一个提交（§4 第 0 步）。这些都是决定或读码更正，和实现无关，不等合入。
- `docs/architecture.md`：
  - §3.9 `:331` 按 A9 改括号里那半句，注明 2026-10-27 读码更正。
  - `:342` "多条流并行可以叠加"补一句：只在 TCP 路径成立，ICE（KCP）路径的整条隧道另受约 1.15 MiB ÷ RTT 的限制。
  - `:343` 按清单改写：降速判据是"会话从配对起算的平均速率超过约 84.5 Mb/s 且已超过 30 分钟（每秒检查，降了不恢复，重连后从头算）"；"空闲 30 秒断开"改成"静默 31~34 秒断开，多路复用的出口会话有 TestDelay（被控端每秒一次的测延迟报文）保活，不会触发"；"TCP 套 TCP"改成队头阻塞和单条拥塞窗口；hbbr 参数名写全大写加下划线。
  - `:344` 和 §5 第四期 `:423` 按 E1 改成"第一版窗口不动，吞吐实测并进统一验收，判定规则见第四期契约 README §6.2"。
  - `:225` 补一句"配了 `-k` 也只挡住没拿到会合公钥的人，而公钥随每个客户端分发"。
  - §3.9 末尾加 2026-10-27 的细化说明，指向本契约：出口开关不进权限卡片、不受访问模式管（A5）；局域网默认拒绝只约束出口模式（A8）；放行打不开回环和本机（B4）；出口流量从物理网卡出去（B9）；系统代理不进第一版（C7）；"改 `on_open` 那一处判断"细化为过滤点在实际连接那一步（C8，`on_open` 只看得到字符串，挡不住域名解析到内网）；拒绝裸管道只影响 1.5.0 以前的原版控制端和关掉复用选项的控制端（清单更正事实）。
  - §3.3 加 F7 例外的一句，指向本文 §3.2；§7 决策记录的 Exit Node 一条加 2026-10-27 的细化说明。
- `docs/research/04-ExitNode与传输层复用.md` 第 82 行"KCP 和 WebRTC 底层没有这个问题"：加更正注（KCP 也是可靠有序流，同样有队头阻塞），只加注、不改原文。

### 8.2 实施合入时同步
只留按最终代码写的两份：
- `server/LEAPGATE.md`：按 01 §3.8 的逐节表。
- `client/LEAPGATE.md`（主会话在 02、03 都合入后单独一个提交改，§3.2、§4 第 5 步）：§2 模块列表加 `exit/`、`lang.rs`、`dns.rs`；新增 §9"应用出口（第四期）"：上游挂钩全表（§3.1 最后一列和 M-1~M-5，含 F7 例外）、`leapgate exit:` 固定日志（03 §3.9；02 §3.3 的 B7 拒绝行和 B11 的 `public IPv4 unavailable` 行）、兼容（本文 §5）、已知限制、合并上游时要核对的三个文件；§8"不配也能用"加一行：被控端开 TUN 或全隧道 VPN 时出口仍从物理网卡出去，不用配规则（B9）。

## 9. 工作量估计【推测】

| 块 | 人天 |
|---|---|
| S0 骨架 | 0.5 |
| 01 服务端：心跳、目录、迁移 0007、A1 加固、`device owner`、`exit` 命令行、测试 | 3 |
| 02 被控端：地址过滤和放行（1.5）、解析和连接（Happy Eyeballs、绑网卡、共用 DNS 模块，2）、本机公网 IPv4（0.5）、`lan.rs` 前缀长度和本机全部地址（0.5）、上游挂钩和心跳字段（1）、设置卡片和 CM（1）、测试（0.5） | 7 |
| 03 控制端：本地代理握手（1.5）、出口监听（2）、目录（0.5）、译文（0.3）、Dart（1.5）、C11（0.2） | 6 |
| 联合冒烟、文档同步 | 2 |
| 合计 | 约 18.5 |

统一验收（§6.2）约 2~3 天，开发全部完成后无人值守跑，不计在内。
