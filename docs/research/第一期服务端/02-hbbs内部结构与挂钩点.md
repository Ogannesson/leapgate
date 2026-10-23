# 02 原版 hbbs 内部结构与 Porta 挂钩点

> Porta 是当时的工作名，2026-10-24 改名为 Leapgate（跃门）。

调研日期 2026-10-22。只读代码，没有运行。

- 服务端 `rustdesk-server@873230e`，下文写 `srv:`，路径相对 `upstream/rustdesk-server/`。
- 客户端 `rustdesk@bd92623`，下文写 `cli:`，路径相对 `upstream/rustdesk/`。
- hbb_common：客户端钉的 `5d52530`（下文 `hbb@5d52530`），服务端原来钉的 `69cea8d`（`hbb@69cea8d`）。
- 标注：【读码】附文件 + 函数/行号；【推测】是推断、没验证。
- 术语：A = 控制端（发起方），B = 被控端（常驻注册的一方）。

---

## 0. 先看这几条（会改变实现方案）

1. **原版 hbbs 不做 TCP 密钥交换，登录过的原版客户端连它会在 18 秒后失败**【读码】。控制端只要配了 key 且登录过（有 `access_token`），`_start_inner` 就要求 hbbs 先发 `KeyExchange`，等不到就报 `Failed to secure tcp: deadline has elapsed`，整次连接失败（`cli:src/client.rs` L860 `legacy_secure`、L887-891；`cli:src/common.rs` L2259 `key_exchange` 里 `timeout(READ_TIMEOUT=18s, conn.next()).await?` 超时直接返回 Err）。回落的 `request_relay` 也一样（L1808-1810）。porta-server 第一期**必须**在 21116/TCP 上实现服务端一侧的 KeyExchange（§6.2），否则装了 API、用户一登录就连不上任何设备。`docs/research/03` L271 提到 lejianwen 的 hbbs fork "解决 API 连接超时"，很可能就是这个问题【推测】。
2. **原版 hbbs 根本不转发 `socket_addr_v6`，IPv6 打洞在它下面不会发生**【读码】。`srv:src/rendezvous_server.rs` 里搜不到 `socket_addr_v6`、`udp_port`、`force_relay`、`upnp_port`、`webrtc`、`token`、`switch_code` 任何一个字。构造 `PunchHole`（L806-811）、`FetchLocalAddr`（L794-798）、`PunchHoleResponse`（L671-676、L705-711）时都是 `..Default::default()`。所以 IPv6 地址两个方向都丢。只有 `RelayResponse` 是整条透传的。porta-server 要补转发（§6.5）。（01 号笔记也发现了这一条，结论一致。）
3. **原版 hbbs 不支持 TCP 注册**【读码】。`handle_tcp`（L522-609）没有 `RegisterPeer` 分支，TCP 上的 `RegisterPk` 回 `NOT_SUPPORT`（L596-604）。客户端在用代理、WebSocket、或禁用 UDP 时走 `start_tcp`（`cli:src/rendezvous_mediator.rs` L647-659），这类被控端在原版 hbbs 上永远是离线。研究笔记 02 §1.4 说"走 ws/代理时是 TCP 注册"，在原版 hbbs 上并不成立。
4. **"经 hbbs 的 RequestRelay/RelayResponse 就记中继，否则记直连"大体成立，但有 4 类误判**（§4.3）：没收到 B 回应就失败的、hbbs 自己回了失败的、分支 X 里 IPv6 抢先成功的、回落中继本身失败的。补一个"B 有没有回应"和"回应是什么类型"的状态就能分开。
5. **中继列表在 `RendezvousServer` 里不是共享状态，是每个 clone 一份快照**（`relay_servers: Arc<Vec<String>>`，§1.6）。同进程的 API 模块拿不到实时列表，也改不了它，只能经 `tx` 发 `Data::RelayServers0`。要换成一个 `Arc<Router>` 共享对象（§1.7、§3.5）。
6. 控制台 `always-use-relay Y|N` 有 bug：会把 `"Y"` 当成中继列表发给主循环，把中继列表清空（§3.4）【读码；DNS 结果为推测】。
7. 所有 UDP 消息（注册、RegisterPk 里的数据库写）都在主循环里串行执行，数据库连接池默认只有 1 个连接（§1.5、§2.4）。API 模块和它共用连接池会卡住注册。

---

## 1. 进程结构

### 1.1 源文件与编译单元【读码】
| 文件 | 编进哪个二进制 | 内容 |
|---|---|---|
| `src/main.rs`（45 行） | hbbs | 参数串、`init_args`、调 `RendezvousServer::start_with_bind` |
| `src/lib.rs` | hbbs（lib 名 `hbbs`） | `mod rendezvous_server; pub use rendezvous_server::*; pub mod common; mod database; mod peer; mod version;` |
| `src/rendezvous_server.rs`（1454 行） | hbbs | 全部会合逻辑 |
| `src/peer.rs` | hbbs | `Peer`、`PeerMap`、限流用的全局表 |
| `src/database.rs` | hbbs | sqlx + deadpool 的 SQLite |
| `src/common.rs` | hbbs、hbbr 各编一份 | 参数、监听、key 文件、版本检查 |
| `src/hbbr.rs` + `src/relay_server.rs` | hbbr | 中继，Porta 不改 |
| `src/utils.rs` | rustdesk-utils | genkeypair / validatekeypair / doctor |
| `src/mod.rs` | 不编译（没人 `mod` 它，引用的 `sled_async` 也不存在） | 死文件 |
| `version.rs` | 由 `build.rs` 的 `hbb_common::gen_version()` 生成 | `VERSION` |

`Cargo.toml` 里已经声明了 `axum = "0.5"`、`tower-http 0.3`、`jsonwebtoken`、`bcrypt`、`headers`，但 `src/` 里**一处都没用**（Pro 版遗留）。Porta 换成新版 axum 没有兼容包袱。sqlx 锁定 `0.6.0`，tokio `1.53.1`（`Cargo.lock`）。

### 1.2 参数解析【读码】
- `srv:src/main.rs`：clap 2 的 `args_from_usage` 串，选项有 `-c/--config`、`-b/--bind`、`-p/--port`、`-s/--serial`（废弃）、`-R/--rendezvous-servers`（废弃）、`-u/--software-url`（废弃）、`-r/--relay-servers`、`-M/--rmem`、`--mask`（标废弃但仍生效）、`-k/--key`。注意 `(default=21116)` 只是写在值名里的说明，clap 不会真的设默认值。
- `srv:src/common.rs` L122-150 `init_args`：依次把 `.env`（工作目录下的 INI）、`--config` 指定的 INI、命令行参数，全部经 `set_arg` 写进**进程环境变量**，后写的覆盖先写的。`set_arg` 用 `arg_name`（L111-113：转大写、`_` 换 `-`），所以 `--relay-servers` 落成环境变量 `RELAY-SERVERS`。
- L152-175 `get_arg_opt(name)`：先按 `RELAY-SERVERS`、`RELAY_SERVERS`、`relay-servers`、`relay_servers` 四种拼法查，查不到再遍历全部环境变量、按 `arg_name` 归一后比对（多个命中取排序后第一个）。所以继承的 `RELAY_SERVERS` 也能读到，但会被 `.env` / 命令行写的 `RELAY-SERVERS` 盖掉。
- 主要读取点：`get_arg_or("port", "21116")`、`parse_bind_address(get_arg("bind"))`、`get_arg("rmem")`、`get_arg("serial")`、`get_arg_or("key", "-")`（main.rs）；`get_arg("relay-servers")`、`get_arg("mask")`、`get_arg_or("local-ip", 自动探测)`、`get_arg("TEST_HBBS")`、`get_arg("ALWAYS_USE_RELAY")`、`get_arg("software-url")`、`get_arg("rendezvous-servers")`（start_with_bind）；`get_arg_opt("DB_URL")`（peer.rs L73）；`get_arg_or("MAX_DATABASE_CONNECTIONS","1")`（database.rs L54）；`get_arg("MAX_PUNCH_REQUESTS")`（rendezvous_server.rs L71-72）。
- Porta 加新参数（API 端口、IP 库路径等）：往 main.rs 的 usage 串里加一行即可，读的时候用 `get_arg`，环境变量和 `.env` 自动支持。
- `RUST_LOG` 在读 `.env` 之前就初始化了日志，只能经继承的环境变量设置。

### 1.3 启动流程 `start_with_bind`（rendezvous_server.rs L125-264）【读码】
它带 `#[tokio::main(flavor = "multi_thread")]`，是一个**同步函数，自己建 tokio 运行时**。所以 API 模块（axum）要在这个函数里面 `tokio::spawn`，或者把 main 改成自己建运行时。顺序：
1. `get_server_sk(key)` → `(key: String, sk: Option<sign::SecretKey>)`（§6.1）。
2. `nat_port = port - 1`，`ws_port = port + 2`。
3. `PeerMap::new()`（打开数据库、建表）。
4. `create_udp_listener(bind, port, rmem)`；`mpsc::unbounded_channel::<Data>()`。
5. 算 `mask`、`local_ip`（§6.3）；构造 `RendezvousServer`。
6. `std::env::set_var("PORT_FOR_API", port)`（Pro 遗留，开源版没人读）。
7. `parse_relay_servers(get_arg("relay-servers"))`。
8. 建 TCP 监听：`listener`(port)、`listener2`(port-1)、`listener3`(port+2，WebSocket)、`listener_console`（只在 `-b` 绑了非 0.0.0.0/非 127.0.0.1 的地址时，额外在 127.0.0.1:port-1 开一个，`common.rs` L39-63）。
9. `ALWAYS_USE_RELAY` 读环境变量。
10. 除非 `TEST_HBBS=no`，spawn `test_hbbs`：每秒给自己的 UDP 端口发 `RegisterPeer{id:"(:test_hbbs:)"}`，12 秒收不到回包就 `std::process::exit(1)`（L1344-1379）。
11. `main_task`：死循环调 `io_loop`，按返回的 `LoopFailure` 重建对应的 socket；和 `listen_signal()`（unix 下 SIGTERM/SIGINT/SIGQUIT）做 `select!`。
12. 另外 main.rs 里的 `check_software_update()` 每天起线程向 RustDesk 官方版本接口发一次请求（`common.rs` L428-453）。Porta 应删掉（外呼、品牌）。

### 1.4 端口表【读码】
| 端口（默认） | 协议 | 处理函数 | 收什么 |
|---|---|---|---|
| 21116 = `port` | UDP | `handle_udp`（L364-520），**主循环内联执行** | `RegisterPeer`、`RegisterPk`、`ConfigureUpdate`（仅 loopback）、`SoftwareUpdate`；`PunchHoleRequest`/`PunchHoleSent`/`LocalAddr` 在 UDP 上**直接丢弃**（L475-484） |
| 21116 = `port` | TCP | `handle_listener` → spawn `handle_listener_inner`（L1174-1242）→ `handle_tcp`（L522-609） | `PunchHoleRequest`、`RequestRelay`、`RelayResponse`、`PunchHoleSent`、`LocalAddr`、`TestNatRequest`、`RegisterPk`（回 `NOT_SUPPORT`）。其他（`KeyExchange`、`HttpProxyRequest`、`HealthCheck`、`IceCandidate`、`OnlineRequest`）一律忽略 |
| 21115 = `port-1` | TCP | `handle_listener2`（L1134-1172） | 来源是 loopback：当作控制台命令（读一次最多 1024 字节，1 秒超时）；否则读一条消息（30 秒超时）：`TestNatRequest` → `TestNatResponse{port}`，`OnlineRequest` → `OnlineResponse` |
| 21118 = `port+2` | TCP/WebSocket | 同 21116/TCP，`ws=true` | 同上；握手时信任 `X-Real-IP` / `X-Forwarded-For`（§5） |
| 21114 | — | 原版不监听 | Porta 的 API 用这个 |

### 1.5 `io_loop` 主循环（L266-362）【读码】
`tokio::select!` 七个分支：
1. `timer_check_relay.tick()`（3 秒）：`relay_servers0.len() > 1` 时 spawn `check_relay_servers`。
2. `rx.recv()`：`Data::Msg(msg, addr)` → `socket.send(msg, addr)`（从 UDP 端口发给某台被控端）；`Data::RelayServers0(s)` → `parse_relay_servers(&s)`；`Data::RelayServers(v)` → `self.relay_servers = Arc::new(v)`。
3. `socket.next()`（UDP）→ `self.handle_udp(...).await`，**内联**。出错就返回 `LoopFailure::UdpSocket` 重建 UDP socket。
4. `listener2.accept()` → `handle_listener2`（内部 spawn）。
5. `accept_or_pending(listener_console)` → 同上。
6. `listener3.accept()` → `handle_listener(ws=true)`（spawn）。
7. `listener.accept()` → `handle_listener(ws=false)`（spawn）。

要点：
- UDP 处理不 spawn。`RegisterPk` 分支里的 `pm.update_pk` 会 `await` 数据库写（`insert_peer`/`update_pk`），这段时间整个主循环（包括 TCP accept、发往被控端的 UDP）都停着【读码】。
- 往被控端发东西只能经 `tx` 让主循环用 UDP socket 发（`Data::Msg`）。TCP handler 自己不碰 UDP socket。
- `enum Data` 是私有的（L43-48），API 模块要用得改成 `pub(crate)`。

### 1.6 共享状态清单【读码】
`RendezvousServer`（L101-110）是 `#[derive(Clone)]`，每个 TCP 连接、控制台连接在 accept 时 `self.clone()`。

| 状态 | 位置 / 类型 | 锁 | 谁写 | 共享性 |
|---|---|---|---|---|
| `tcp_punch` | `Arc<tokio::sync::Mutex<HashMap<SocketAddr, Sink>>>` | tokio Mutex | TCP handler 收到 `PunchHoleRequest`/`RequestRelay` 时插入（key = `try_into_v4(A 的地址)`）；回包时 `remove` | 所有 clone 共享 |
| `pm: PeerMap` | `peer.rs` L65-69：`map: Arc<tokio::RwLock<HashMap<String, LockPeer>>>` + `db: Database` | 外层 tokio RwLock，每个 peer 一把 `Arc<tokio::RwLock<Peer>>` | UDP 注册（主循环）、`get()` 从库里加载 | 共享（Arc 在里面） |
| `tx` | `mpsc::UnboundedSender<Data>` | — | 任何人 | 共享 |
| `relay_servers` | `Arc<Vec<String>>` | **无锁** | 主循环那份 `self` 重新赋值 | **每个 clone 一份快照**，TCP handler 用的是它 accept 那一刻的列表 |
| `relay_servers0` | `Arc<Vec<String>>` | 无锁 | 同上 | 同上 |
| `rendezvous_servers` | `Arc<Vec<String>>` | 无锁 | UDP `ConfigureUpdate`（仅 loopback）| 快照（废弃功能） |
| `inner: Arc<Inner>` | `serial, version, software_url, mask, local_ip, sk` | 不可变，整体替换 | `ConfigureUpdate` | 快照 |
| `IP_BLOCKER` | `peer.rs` L17，`tokio Mutex<HashMap<ip, ((u32,Instant),(HashSet<id>,Instant))>>` | tokio Mutex | `check_ip_blocker` | 全局 static |
| `IP_CHANGES` | `peer.rs` L19，`tokio Mutex<HashMap<id,(Instant,HashMap<ip,i32>)>>` | tokio Mutex | RegisterPk | 全局 static |
| `USER_STATUS` | `peer.rs` L18 | tokio RwLock | 没人用 | — |
| `PUNCH_REQS` | L69，`once_cell Lazy<tokio Mutex<VecDeque<PunchReqEntry{tm, from_ip, to_ip, to_id}>>>` | tokio Mutex | `record_punch_req` | 全局 static |
| `ROTATION_RELAY_SERVER` | L59，`AtomicUsize` | 原子 | `get_relay_server` | 全局 static |
| `ALWAYS_USE_RELAY` | L62，`AtomicBool` | 原子 | 启动、控制台 `aur` | 全局 static |

### 1.7 API 模块的共享方式（建议）
最自然的做法：在 `start_with_bind` 里先把下面几样建好，同一份交给 `RendezvousServer` 和 axum 的 `State`。

```rust
#[derive(Clone)]
pub(crate) struct Shared {
    pub pm: PeerMap,                 // 现成的，Clone 即共享（内部是 Arc）
    pub router: Arc<Router>,         // 新增：替代 relay_servers / relay_servers0 两个快照字段
    pub tx: mpsc::UnboundedSender<Data>,   // 现成的：要往被控端发 UDP 时用
    pub conn_tracker: Arc<ConnTracker>,    // 新增：§4.4 的直连/中继记录
    pub server_pk: String,           // get_server_sk 返回的 key（公钥 base64）
    pub sk: Option<sign::SecretKey>, // 同上
}
```

- **在线状态**：`pm.get_in_memory(id).await` 拿到 `LockPeer`，`peer.read().await.last_reg_time.elapsed() < Duration::from_millis(30_000)`（`REG_TIMEOUT`，L50）。只看内存，不碰数据库，和 `handle_online_request`（L824-851）的判定完全一样。【读码】
- **设备公钥**：`peer.read().await.pk`（`Bytes`，32 字节 Ed25519 公钥）；不在内存时用 `pm.get(id)`，它会从库里加载并**塞进内存表**（副作用，表只增不减）。也可以给 `database.rs` 加一个只读查询。【读码】
- **uuid**：`peer.uuid` 是客户端 `hbb_common::get_uuid()` 的原始字节（机器 UID）；API 上报（heartbeat/sysinfo）里的 `uuid` 字段是它的 base64（01/03 号笔记）。API 校验设备时比 `base64(peer.uuid) == body.uuid`。【读码 + 推测：base64 变体要和客户端 `crate::encode64` 一致】
- **列出全部设备**：`PeerMap.map` 是私有字段，没有遍历接口，`database.rs` 也没有列表查询。要加 `PeerMap::snapshot()` 或 `Database::list_peers()`。
- **改中继列表**：现在只能 `tx.send(Data::RelayServers0("a,b,c"))`（控制台 `rs` 就是这么做的）。读当前列表做不到（API 手里的 clone 是旧快照）。所以要引入 `Router`（§3.5）。
- **锁**：hbbs 全用 `hbb_common::tokio::sync` 的异步锁。`get_relay_server` 是同步函数，`Router` 内部可以用 `std::sync::RwLock` 或 `arc_swap`（临界区里没有 await），或者把 `get_relay_server` 改成 async（三个调用点都在 async 函数里）。
- **数据库**：别和 hbbs 共用那个 1 连接的 deadpool（§2.4），API 自己开一个池，或者把 `MAX_DATABASE_CONNECTIONS` 调大并开 WAL。

---

## 2. 设备注册

### 2.1 内存结构（peer.rs）【读码】
```rust
pub(crate) struct PeerInfo { pub(crate) ip: String }   // serde，落库成 info 列的 JSON：{"ip":"..."}
pub(crate) struct Peer {
    socket_addr: SocketAddr,   // 最近一次 UDP 注册的源地址（B 的公网 ip:port）
    last_reg_time: Instant,    // 在线判定用
    guid: Vec<u8>,             // 数据库主键（UUIDv4 16 字节）；空 = 还没入库
    uuid: Bytes,               // 客户端机器 UID
    pk: Bytes,                 // 客户端 Ed25519 公钥
    info: PeerInfo,
    reg_pk: (u32, Instant),    // RegisterPk 限流计数
}
Default: socket_addr 0.0.0.0:0，last_reg_time = now-3600s（get_expired_time），reg_pk (0, 过期)
```
- `PeerMap::get(id)`（L138-158）：内存有就返回；没有就查库，构造 `Peer{guid, uuid, pk, info, ..Default}`（`socket_addr` 端口为 0、`last_reg_time` 过期）塞进内存。
- `get_or(id)`（L160-172）：`get` 不到就插一个空 `Peer`（双重检查）。
- `get_in_memory` / `is_in_memory`：只看内存。
- 内存表**永不清理**。
- `info.ip` 存的是 `addr.ip().to_string()` 原样。hbbs 的 UDP/TCP 监听都是 `[::]` + `set_only_v6(false)`（`hbb@5d52530:src/udp.rs` L42、`src/tcp.rs` `listen_any`），IPv4 客户端的地址是 `::ffff:a.b.c.d`，所以库里存的多半是 `"::ffff:1.2.3.4"` 这种形式【读码；运行时表现为推测】。做 GeoIP、展示前都要先 `try_into_v4` / `to_ipv4_mapped()`。

### 2.2 `RegisterPeer`（UDP，L374-389 → `update_addr` L611-653）【读码】
- 条件：`1 <= id.len() <= 253`（`MAX_PEER_ID_LEN`，peer.rs L27）。
- `update_addr`：
  - 内存里没有这个 id → `request_pk = true`（不插内存、不写库）。
  - 有：`ip_change` = 内存 `socket_addr` 端口非 0 时比 IP，否则比 `info.ip` 字符串；loopback 不算变。`request_pk = pk 为空 || ip_change`。
  - `request_pk == false` 才更新 `socket_addr` 和 `last_reg_time`。**IP 变了时不刷新在线时间**，要等 RegisterPk 成功。
  - 回 `RegisterPeerResponse{request_pk}`（UDP）。
- `inner.serial > rp.serial` 时再回一个 `ConfigUpdate`（废弃功能）。
- 客户端节奏：`REG_INTERVAL = 15_000` ms 发一次（`hbb@5d52530:src/config.rs` L51；`cli:src/rendezvous_mediator.rs` `start_udp` L367-486）；key 未确认时 `register_peer` 改发 `register_pk`（L1291-1319）。

### 2.3 `RegisterPk`（UDP，L390-474）【读码】
按顺序：
1. `uuid` 或 `pk` 为空 → **静默丢弃**，不回包。
2. `id.len() < 6 || > 253` → 回 `UUID_MISMATCH`（不是 `INVALID_ID_FORMAT`）。
3. `check_ip_blocker(ip, id)`（L923-951）不过 → `TOO_FREQUENT`。规则：同一 IP 60 秒内超过 30 次；同一 IP 一天内注册超过 300 个不同 id 时新 id 一律拒。
4. `peer = pm.get_or(id)`：
   - 内存 `uuid` 为空（新设备）→ `changed = true`。
   - `uuid` 不同 → `UUID_MISMATCH`。
   - `uuid` 相同，但 **IP 和 pk 都变了** → `UUID_MISMATCH`（防冒名）。
   - 否则 `changed = pk 变 || ip 变`。
5. 限流 `reg_pk`：6 秒内第 3 次以上 → `TOO_FREQUENT`。
6. IP 变了记进 `IP_CHANGES`（控制台 `ic` 用）。
7. `changed` → `pm.update_pk(id, peer, addr, uuid, pk, ip)`（peer.rs L95-136）：改内存 `socket_addr / uuid / pk / last_reg_time / info.ip`；`guid` 空则 `insert_peer`（新 guid = UUIDv4），否则 `update_pk`（按 guid 改 `id, pk, info`，**uuid 列从不更新**）。
   - 注意：`update_pk` 返回的 `SERVER_ERROR` 被调用方丢掉了（L466 没接返回值），**数据库写失败也照样回 OK**。
8. 回 `RegisterPkResponse{result: OK}`（`keep_alive` 不填）。
- 客户端收到 `UUID_MISMATCH` 会**自己换一个随机 ID**（`cli:src/rendezvous_mediator.rs` L1276-1289 `handle_uuid_mismatch` → `hbb@5d52530:src/config.rs` L1276 `update_id`：`1_000_000_000..2_000_000_000` 随机）。所以服务端回 `UUID_MISMATCH` 的代价是设备改号。
- `RegisterPk.old_id`、`no_register_device` 原版不看。
- TCP 上的 `RegisterPk` 回 `NOT_SUPPORT`（L596-604）。客户端"修改 ID"功能走的就是这条：TCP 发 `RegisterPk{old_id, id, uuid}`，原版回 `NOT_SUPPORT` → 界面显示 `server_not_support`（`cli:src/ui_interface.rs` L1502-1620 `change_id_shared_` / `check_id`）。Porta 要支持改 ID 就在这里加。

### 2.4 数据库（database.rs）【读码】
- 连接：`deadpool::managed::Pool<DbPool>`，`DbPool::create` 用 `SqliteConnectOptions::from_str(url)` + `log_statements(Debug)`；池大小 `MAX_DATABASE_CONNECTIONS`，默认 **1**。每次查询 `self.pool.get().await?`。没有显式设 `journal_mode` / `busy_timeout`，用 sqlx 0.6 的默认值（默认是不是 WAL 我没核实【推测】；仓库里那份 `db_v2.sqlite3` 现在是 `journal_mode=delete`）。
- 路径：`DB_URL`，默认 `./db_v2.sqlite3`（Windows release 版在 `Config::icon_path()` 的目录）。文件不存在先 `File::create`。
- 建表（`create_tables` L70-93，每次启动执行，`if not exists`）：
```sql
create table if not exists peer (
    guid blob primary key not null,
    id varchar(100) not null,
    uuid blob not null,
    pk blob not null,
    created_at datetime not null default(current_timestamp),
    user blob,
    status tinyint,
    note varchar(300),
    info text not null
) without rowid;
create unique index if not exists index_peer_id on peer (id);
create index if not exists index_peer_user on peer (user);
create index if not exists index_peer_created_at on peer (created_at);
create index if not exists index_peer_status on peer (status);
```
  `user / status / note` 原版不读不写（`status` 本来是"禁用"，代码里注释掉了）。
- 查询：`get_peer`：`select guid, id, uuid, pk, user, status, info from peer where id = ?`；`insert_peer`：`insert into peer(guid, id, uuid, pk, info) values(?,?,?,?,?)`；`update_pk`：`update peer set id=?, pk=?, info=? where guid=?`。
- **全部用 `sqlx::query!` / `query_as!` 编译期宏**。编译时 sqlx 要连一个真库校验 SQL：仓库根目录 `.env` 里的 `DATABASE_URL` 指向仓库里检入的 `db_v2.sqlite3`（`docs/environment-variables.md` "Do not confuse DB_URL with DATABASE_URL"；`.env` 本身被本机权限规则挡住没读到）。这个检入的库只有 `peer` 表和 2 行数据（我用只读模式查过）。
  - 影响：Porta 新表要么用运行时的 `sqlx::query()`（推荐，不依赖编译期库），要么同步更新这个检入库的表结构，要么用 sqlx 离线模式。
  - 坑：在仓库根目录直接跑 hbbs，运行时默认库和编译期库是**同一个文件**。
- 单元测试 `test_insert` 在当前目录建 `test.sqlite3` 插 1 万行，不清理；第二次跑会因唯一索引冲突 panic【读码；运行结果推测】。

### 2.5 在线判定【读码】
- 在线 = 内存里有且 `last_reg_time.elapsed() < 30_000ms`（`REG_TIMEOUT`）。客户端 15 秒注册一次，等于允许丢一个包。
- 用在两处：`handle_punch_hole_request`（L745-757，超时回 `Failure::OFFLINE`）和 `handle_online_request`（L837）。
- 不落库。重启后全部离线，直到设备下一次注册。
- TCP 注册的设备（代理/WS/禁 UDP）在原版里永远离线（§0 第 3 条）。

### 2.6 uuid / pk / id 变更规则汇总【读码】
| 情况 | 结果 |
|---|---|
| 新 id 第一次 RegisterPk | 绑定 uuid + pk，入库 |
| 同 uuid，pk 不变，IP 变 | 接受，更新 IP |
| 同 uuid，pk 变，IP 不变 | 接受，更新 pk |
| 同 uuid，pk 和 IP 都变 | `UUID_MISMATCH` → 客户端换随机 ID |
| 不同 uuid 抢同一个 id | `UUID_MISMATCH` → 后来者换随机 ID |
| 改 id（`old_id`） | 不支持（TCP 回 `NOT_SUPPORT`） |
| uuid 列 | 入库后永不更新 |

---

## 3. 选中继

### 3.1 `get_relay_server` 的全部调用点【读码】
函数本体 L959-967：列表空返回 `""`，1 个返回它，多个用全局 `ROTATION_RELAY_SERVER.fetch_add(1) % len` 轮询。两个 IP 参数没用。

| # | 位置 | 调用 | 第 1 个参数 | 第 2 个参数 | 何时生效 |
|---|---|---|---|---|---|
| 1 | `handle_punch_hole_request` L770 | `get_relay_server(addr.ip(), peer_addr.ip())` | `addr` = **A** 的打洞连接源地址（TCP 21116 的 peer addr；WS 时可能是 `X-Real-IP:0`） | `peer_addr` = **B** 内存里的 `socket_addr`（最近 UDP 注册源地址） | 每次在线目标的打洞请求都算，结果放进 `PunchHole` / `FetchLocalAddr` 的 `relay_server`。即使后面被 `local_ip` 覆盖或走同内网也先算一次（轮询计数也会加 1） |
| 2 | `handle_tcp` 的 `RelayResponse` 分支 L569 | `get_relay_server(addr.ip(), addr_b.ip())` | `addr` = **B**（发 RelayResponse 的临时 TCP 连接源地址） | `addr_b` = 解出来的 `rr.socket_addr` = **A** | **参数顺序和 #1 相反**。只在 `rr.relay_server` 非空、B 不在 mask 内网、且 `rr.relay_server == inner.local_ip` 时调用；没配 `--mask` 时 `local_ip` 为空，外层又要求 `relay_server` 非空，所以**实际永远不会走到** |
| 3 | 控制台 `test-geo`/`tg` L1116-1128 | `get_relay_server(a, b)` 或 `(a, a)` | 命令行给的 IP | 同左 | 调试用；也会推进轮询计数 |

注意：#1 的两个 IP 都可能是 `::ffff:x.x.x.x`（§2.1），路由模块要先归一。

### 3.2 `parse_relay_servers` / `get_servers`【读码】
- `parse_relay_servers(s)`（L953-957）：`get_servers(s, "relay-servers")`，同时写 `relay_servers0`（配置原表）和 `relay_servers`（当前可用表）。
- `get_servers`（common.rs L98-107）：按逗号切，过滤空串和 `test_if_valid_server` 失败的（L82-96：带冒号就 `to_socket_addrs`，否则拼 `:0` 再解析，**会做 DNS 解析**，解析不了就丢掉并打 error 日志）。所以启动时 DNS 不通，中继会被整个丢掉。
- 值的格式：`host` 或 `host:port`，原样发给客户端；客户端自己 `check_port(relay, 21117)`。

### 3.3 健康检查 `check_relay_servers`（L1316-1341）【读码】
- 由 `io_loop` 的 3 秒定时器 spawn，**只在 `relay_servers0.len() > 1` 时跑**；只有一台中继时永不检查，挂了也照发。
- 对每个中继 spawn 一个 `FramedStream::new(host[:21117], None, 3000)`，连上就算活，立刻断开（hbbr 那边会看到一条空连接）。不测延迟。
- 收集结果后：非空 → `tx.send(Data::RelayServers(活的列表))`，主循环替换 `self.relay_servers`；**全部失败 → 不发，保留上一次的列表**。
- 每 3 秒一轮、没有防重入：上一轮还没结束（3 秒超时）下一轮就可能开始【推测：偶尔重叠，影响不大】。

### 3.4 控制台命令（`check_cmd` L969-1132）【读码】
连 127.0.0.1:21115（或 `-b` 时的专用控制台监听），发一行文本：
- `h`：帮助。列了 `reload-geo(rg)` 但**没实现**。
- `rs [a,b,c]`：带参数 → `tx.send(Data::RelayServers0(...))`；不带 → 打印本 clone 的 `relay_servers`（控制台连接 accept 时从主循环 clone 的，是当时的可用表）。
- `ib [ip|n] [-]`、`ic [id|n] [-]`、`pr [n] [page] | -`：查看/清除 `IP_BLOCKER`、`IP_CHANGES`、`PUNCH_REQS`。
- `aur [Y|N]`：改 `ALWAYS_USE_RELAY`，然后**多了一句 `self.tx.send(Data::RelayServers0(rs.to_owned()))`**（L1107），把 `"Y"`/`"N"` 当中继列表交给 `parse_relay_servers`。`get_servers("Y")` 会去 DNS 解析主机名 `Y`，一般解析失败 → 列表变空 → `relay_servers0` 和 `relay_servers` 都被清空，之后 `get_relay_server` 返回 `""`，被控端退回"hbbs 主机:21117"，健康检查也停了。Porta 分叉时删掉这一行。【读码；DNS 结果推测】
- `tg ip1 [ip2]`：见 §3.1。
- 安全：任何来自 loopback 的连接都能执行，没有认证。容器端口转发让外部连接看起来来自 127.0.0.1 时（比如部分 rootless 容器方案）会暴露【推测】。Porta 的命令行管理建议另走 unix socket 或带认证的本地通道。

### 3.5 改成"调路由模块"的最小侵入挂钩
1. `RendezvousServer` 里删掉 `relay_servers`、`relay_servers0`，加 `router: Arc<Router>`（所有 clone 共享同一个）。
2. `parse_relay_servers(&mut self, s)` → `self.router.set_configured(get_servers(s, ...))`；`Data::RelayServers0` 分支照旧调它（控制台兼容），`Data::RelayServers` 分支和 `io_loop` 里的定时器分支删掉。
3. 健康检查挪进 `Router` 自己的任务：在 `start_with_bind` 里 `tokio::spawn(router.clone().health_loop())`，结果直接写进 router 的状态，顺便记 RTT（`Instant` 包住 connect）。保留"全失败时不清空"的语义，并且一台中继也要检查。
4. `get_relay_server(&self, pa, pb)` 的函数体换成 `self.router.select(...)`。为了支持"按设备固定中继"和第二级测速，#1 调用点改调一个带上下文的新函数，其余两处保留旧签名：
```rust
pub(crate) struct RouteQuery<'a> {
    pub a_ip: IpAddr,        // try_into_v4(addr).ip()，发起方
    pub b_ip: IpAddr,        // try_into_v4(peer_addr).ip()，被控端
    pub b_id: &'a str,       // ph.id，用于固定中继
    pub a_token: &'a str,    // ph.token，登录后能反查发起方（§5）
    pub conn_type: i32,      // ph.conn_type
}
// handle_punch_hole_request L770:
let mut relay_server = self.router.select(&RouteQuery{...});
```
5. 控制台 `rs` 无参数时改为打印 `router` 的当前状态（含健康、RTT、权重）。`tg` 调 `router.select`。
6. 返回值仍是单个 `String`（原版客户端只认一个）。空串的语义保持：被控端会退回"hbbs 主机:21117"。

另外，Y 路径（B 回 `PunchHoleSent`）里，hbbs 可以在 `handle_hole_sent` / `handle_local_addr` 里把转给 A 的 `relay_server` 改写成自己选的值；A 之后发 `RequestRelay` 用这个值，B 的 `handle_request_relay` 直接用 A 给的值（`cli:src/rendezvous_mediator.rs` L661-686），两边一致。分支 X 不能改写（B 已经拿自己的值去连 hbbr 了）。这和研究笔记 02 §3.3 的结论一致【读码】。

---

## 4. 直连 / 回落中继的判定

### 4.1 一次连接在 hbbs 上能看到的消息（默认：只开 TCP 打洞，可能开了 IPv6）【读码】
时序里的 `A:p1` 是 A 打洞用的那条 TCP 连接的源地址，`A:p3` 是 A 回落时新开的 TCP 连接的源地址。

**阶段 1：A 发起**（`cli:src/client.rs` `_start_inner` L795-1390）
- A → hbbs，TCP 21116（或 WS 21118），连接 `A:p1`：`PunchHoleRequest`（L953-975），字段：
  - `id` = **B 的 id**；`nat_type`（A 强制中继时改成 `SYMMETRIC`）；`licence_key` = A 配的 key；`conn_type`；`token` = A 的 `access_token`（未登录为空）；`version` = A 的版本；`udp_port`（开 UDP 打洞时 >0）；`force_relay`；`socket_addr_v6`（开 IPv6 打洞且有公网 v6 时非空）；`switch_code`；`webrtc_sdp_offer`。
  - **没有 A 自己的 id**。
  - 同一条连接上最多重发 3 次（等待窗口 3/6/9 秒，L977-998）。
  - 开了 UDP 打洞或 WebRTC 时，`_start` 会再并行开一条纯 TCP 打洞的连接（`fallback_fut`，L567-597），即 `A:p2`，也发一份 `PunchHoleRequest`。只开 IPv6 时不会（L586-591）。
- hbbs（`handle_punch_hole_request` L721-822）：
  - key 不符 → 回 `PunchHoleResponse{failure: LICENSE_MISMATCH}`；库里没有 → `ID_NOT_EXIST`；不在线 → `OFFLINE`。经 `send_to_tcp_sync` 回给 A，结束。
  - 在线：`record_punch_req`；算 `relay_server`；`ALWAYS_USE_RELAY` 或"恰好一方在 mask 内网"时把 `nat_type` 改成 `SYMMETRIC`；`same_intranet`（非 WS，且双方都在 mask 内网或公网 IP 相同）→ 经 `tx` 用 UDP 给 B 发 `FetchLocalAddr{socket_addr=A:p1, relay_server}`，否则发 `PunchHole{socket_addr=A:p1, nat_type, relay_server}`。

**阶段 2：B 回应**（`cli:src/rendezvous_mediator.rs`）。B 每次都**新开一条 TCP 连接**到 hbbs（源地址记作 `B:t`）：
- (a) `PunchHoleSent{socket_addr=A:p1, id=B, relay_server=B 选的, nat_type=B 的, version, socket_addr_v6, webrtc_sdp_answer}`（`handle_punch_hole` L1155-1194，打 TCP 洞的路径）。hbbs `handle_hole_sent`（L655-687）→ 回 A：`PunchHoleResponse{socket_addr=B:t, pk=签名, relay_server, nat_type}`。
- (b) `LocalAddr{socket_addr=A:p1, local_addr=B 内网地址, relay_server, id=B, version, socket_addr_v6}`（`handle_intranet_` L810-856）。hbbs `handle_local_addr`（L689-719）→ 回 A：`PunchHoleResponse{socket_addr=local_addr, pk, relay_server, is_local=true}`。
- (c) **分支 X**：`RelayResponse{socket_addr=A:p1, uuid=新, relay_server=B 选的, id=B, version, socket_addr_v6, webrtc_sdp_answer}`（`create_relay` L688-751，`initiate=true`）。触发条件（`handle_punch_hole` L1091-1131）：`ph.nat_type == SYMMETRIC` 或 B 自己是 SYMMETRIC 或 B 走 WS/代理 或 `ph.force_relay` 或（禁 TCP 监听且 `udp_port<=0`）；同内网时 `handle_intranet_` 失败也走这里（L783-797）。hbbs `handle_tcp` 的 `RelayResponse` 分支（L555-574）→ 签 pk、按 mask 改写 relay → 整条转给 A。B 同时自己去连 hbbr。
- 所有回 A 的包都经 `tcp_punch[try_into_v4(A:p1)]` 发，发完就从表里删掉（`send_to_tcp` / `send_to_tcp_sync` 都是 `remove`）。同一个 `A:p1` 的第二个回应会被丢掉。

**阶段 3：A 的结果**（`_start_inner` / `connect` L1395-1700）
- 收到 (a)/(b)：A 用同一个本地端口直连（TCP 打洞）、IPv6 KCP（如果 B 的 v6 地址到了）、局域网直连并行竞争（L1453-1532）；超时 `connect_timeout`：局域网或对端 SYMMETRIC 时 1 秒；中继为空 18 秒；双方都是 ASYMMETRIC 且没失败记录时 18 秒；其余 `打洞耗时 × 6`（失败过 ×3），最少 1 秒（L1417-1450）。
  - 成功 → 直连，**hbbs 之后什么都看不到**。
  - 失败且 `relay_server` 非空 → `request_relay`（L1788-1851）。失败且 `relay_server` 为空 → 报错结束，hbbs 也什么都看不到。
- 收到 (c)：A 并行跑"连 hbbr"（`create_relay`，连上并发出 `RequestRelay` 就算成功，不等配对）和"IPv6 KCP"（只有 `rr.socket_addr_v6` 非空时），取先成功的（L1051-1260）。hbbs 之后看不到结果。
- 3 次都没等到回应 → `peer_addr.port()==0` → 报 "Failed to connect via rendezvous server"（L1344-1353）。

**阶段 4：回落中继**（只在阶段 3 直连失败时）
- A → hbbs，**每次新开 TCP 连接** `A:p3`，最多 3 次，每次新 uuid：`RequestRelay{id=B, uuid, relay_server=R（来自 PunchHoleResponse）, secure, token, switch_code}`，**不带 `licence_key`**（L1806-1832）。每次等 `RelayResponse` 最多 18 秒。
- hbbs（L541-554）：把 sink 存进 `tcp_punch[A:p3]`；B 在内存里就把 `rf.socket_addr = A:p3` 后经 UDP 转给 B；**不检查 B 是否在线，也不检查 key**；B 不在内存就什么都不做（A 干等 18 秒）。
- B → hbbs 新 TCP：`RelayResponse{socket_addr=A:p3, version, socket_addr_v6=空}`，**没有 uuid、没有 id、没有 relay_server**（`create_relay` 的 `initiate=false`）。hbbs 原样转给 A（`relay_server` 空 → 不改写；id 空 → 不签 pk）。
- A 连 hbbr（不经过 hbbs）。

### 4.2 能做关联键的字段【读码】
| 关联 | 键 | 出现在 |
|---|---|---|
| 打洞请求 ↔ B 的回应 | `try_into_v4(A:p1)` | `PunchHole.socket_addr` / `FetchLocalAddr.socket_addr` 发出，B 在 `PunchHoleSent` / `LocalAddr` / `RelayResponse` 的 `socket_addr` 里原样带回。hbbs 的 `tcp_punch` 本来就靠它 |
| 回落请求 ↔ B 的回应 | `try_into_v4(A:p3)` | 同理，`RequestRelay.socket_addr`（hbbs 填的）↔ `RelayResponse.socket_addr` |
| 回落请求 ↔ 之前的打洞 | **没有显式键** | 只能用（A 的公网 IP，B 的 id，时间窗）近似；再加 `RequestRelay.relay_server == 之前 B 回的 relay_server` 校验；登录时还能比 `token` |
| B 的身份 | `PunchHoleRequest.id`、`PunchHoleSent.id`、`LocalAddr.id`、分支 X 的 `RelayResponse.id`、`RequestRelay.id` | 回落阶段 B 的 `RelayResponse` 没有 id |
| A 的身份 | 无 id；只有 `token`（登录时） | §5 |
| uuid | 分支 X 的 `RelayResponse.uuid`；回落阶段的 `RequestRelay.uuid` | 是 hbbr 配对用的，每次新生成，不跨阶段 |

坑：WS 连接用了 `X-Real-IP` 后地址是 `ip:0`（L1205-1215），同一 IP 后面的多个 WS 客户端在 `tcp_punch` 和关联表里会撞键。

### 4.3 "过了 RequestRelay 或 RelayResponse 就记中继，否则记直连"——逐条评估
| 场景 | hbbs 看到 | 原规则判为 | 实际 | 结论 |
|---|---|---|---|---|
| TCP 打洞成功 | 请求 + PunchHoleSent | 直连 | 直连 | ✅ |
| IPv6 打洞成功（Y 路径） | 请求 + PunchHoleSent | 直连 | 直连 | ✅（分不清是 TCP 还是 v6） |
| 局域网直连成功 | 请求 + LocalAddr | 直连 | 直连 | ✅ |
| 直连失败 → 回落中继成功 | + RequestRelay + RelayResponse(无 uuid) | 中继 | 中继 | ✅ |
| 分支 X（对称 NAT、强制中继、B 走 WS/代理…） | 请求 + RelayResponse(有 uuid) | 中继 | 通常中继 | ✅；但如果 A、B 都有 v6，A 会让 v6 和中继赛跑，v6 赢了就是直连 → **误判为中继**【读码：赛跑逻辑；谁赢是推测】。只开 TCP 打洞时不存在 |
| hbbs 强制中继（`ALWAYS_USE_RELAY`、mask 异或） | 请求 + RelayResponse | 中继 | 中继 | ✅；但见 §6.4：同公网 IP 的两台不受 `ALWAYS_USE_RELAY` 约束 |
| A 强制中继（`/r`、`force-always-relay`、WS、代理） | 请求（`nat_type=SYMMETRIC`、`force_relay=true`）+ RelayResponse | 中继 | 中继 | ✅ |
| hbbs 直接回失败（OFFLINE/ID_NOT_EXIST/LICENSE_MISMATCH） | 只有请求 | **直连** | 没连上 | ❌ 误判。hbbs 自己知道，单独记 |
| B 没回应（UDP 丢了、B 刚掉线、B 的打洞槽位满） | 只有请求 | **直连** | 失败 | ❌ 误判。要看"有没有回应" |
| B 回了 PunchHoleSent，A 直连失败且 relay 为空 | 请求 + PunchHoleSent | **直连** | 失败 | ❌ 误判。B 的 `get_relay_server` 两者都空时会填"hbbs 主机:21117"，实际很少出现 |
| 回落中继本身失败（B 不在内存、hbbr 连不上） | + RequestRelay，无 RelayResponse；或有 RelayResponse 但 hbbr 连不上 | 中继 | 失败 | ⚠️ 前者能分出来；后者 hbbs 看不到 |
| 同一次连接的多次请求（同连接重发 3 次、`fallback_fut` 并行第二条连接、io_loop 断线重连） | 多条请求 | 多条 | 一次 | ⚠️ 要合并：同 `A:p1` 合成一条；同（A IP，B id）2 秒内的合成一组 |
| UDP 打洞 | — | — | — | 原版 hbbs 不转发 `udp_port`，B 永远不做 UDP 打洞（§6.5），不会出现 |
| WebRTC | — | — | — | 原版不转发 offer，且 A 要求加密信令（§6.2），不会出现 |
| 认证失败、密码错 | 照常 | 照常 | 传输层已建好 | 与传输判定无关 |

另外：被控端审计 `POST /api/audit/conn` 的 `ip` 字段，走中继时是 hbbs 报给 B 的 A 地址（`cli:src/server.rs` L369-427 `create_relay_connection` 把 `peer_addr` 传给 `create_tcp_connection`；`cli:src/server/connection.rs` L1504-1529 `on_open` 记 `addr.ip()`），所以**分不清 TCP 打洞和中继**；但 IPv6 直连时是 v6 地址、局域网直连时是内网地址，可以拿来交叉验证这两类【读码；`create_tcp_connection` 内部没细追，推测】。

### 4.4 建议的记录模型
**内存跟踪器**（不阻塞热路径，定时落库）：
```rust
pub(crate) struct ConnTracker {
    inner: tokio::sync::Mutex<TrackerState>,
    db_tx: mpsc::UnboundedSender<FinalizedAttempt>,  // 单独的写库任务
}
struct TrackerState {
    by_punch_addr: HashMap<SocketAddr, u64>,          // try_into_v4(A:p1) -> attempt id
    by_pair: HashMap<(IpAddr, String), Vec<u64>>,     // (A 公网 IP, B id) -> 最近的 attempt
    by_relay_addr: HashMap<SocketAddr, u64>,          // try_into_v4(A:p3) -> attempt id
    attempts: HashMap<u64, Attempt>,
}
```
每 5 秒扫一遍，到期的定稿写库。

**表**（运行时 `sqlx::query` 建，不用编译期宏）：
```sql
create table if not exists conn_attempt (
  id                  integer primary key autoincrement,
  started_at          integer not null,   -- unix ms，第一条 PunchHoleRequest
  a_ip                text not null,      -- try_into_v4(addr).ip()
  a_port              integer not null,   -- A:p1 端口；WS 为 0
  via                 text not null,      -- 'tcp' | 'ws'
  a_user              text,               -- PunchHoleRequest.token 反查的账号；未登录为 NULL
  a_device_id         text,               -- 同上，登录时上报的设备 id（若 API 记了）
  a_version           text,               -- PunchHoleRequest.version
  b_id                text not null,      -- PunchHoleRequest.id
  b_ip                text,               -- try_into_v4(peer.socket_addr).ip()
  conn_type           integer not null,   -- PunchHoleRequest.conn_type
  a_nat_type          integer not null,   -- PunchHoleRequest.nat_type
  a_force_relay       integer not null,
  a_has_v6            integer not null,   -- socket_addr_v6 非空
  a_udp_port          integer not null default 0,
  attempts            integer not null default 1,  -- 合并进来的重复请求数
  signal              text not null,      -- 'punch_hole' | 'fetch_local_addr' | 'fail_offline' | 'fail_id_not_exist' | 'fail_license'
  server_forced_relay integer not null,   -- ALWAYS_USE_RELAY 或 mask 异或
  relay_offered       text,               -- hbbs 放进 PunchHole/FetchLocalAddr 的 relay_server
  route_reason        text,               -- 路由模块给的理由（geo/fixed/rr/none）
  reply               text,               -- 'punch_hole_sent' | 'local_addr' | 'relay_response' | NULL
  reply_at            integer,
  b_version           text,
  b_nat_type          integer,            -- PunchHoleSent.nat_type
  b_has_v6            integer,
  b_relay             text,               -- B 回的 relay_server；≠ relay_offered 说明 B 本地写死了中继
  relay_uuid          text,               -- 分支 X 的 uuid，或回落时第一个 RequestRelay.uuid
  relay_req_at        integer,            -- 回落：匹配到的第一个 RequestRelay
  relay_req_count     integer not null default 0,
  relay_resp_at       integer,            -- 回落：B 回的 RelayResponse 转给 A 的时间
  outcome             text,               -- 见下
  finalized_at        integer
);
create index if not exists idx_ca_started on conn_attempt(started_at);
create index if not exists idx_ca_b on conn_attempt(b_id, started_at);
```
`b_relay ≠ relay_offered` 这一列顺带能验收架构 §3.7 前提一（"被控端本地写死的中继能被远程清掉"）。

**挂钩位置**（全部在 `srv:src/rendezvous_server.rs`，地址一律先 `try_into_v4`）：
| 钩子 | 位置 | 调用 |
|---|---|---|
| H1 | `handle_punch_hole_request` L721-822，三个失败分支（L730-738、L750-757、L815-820）和成功分支（L786-813）各一处；`ph` 被 move 前取字段 | `on_punch_request(a_addr, ws, &ph 摘要, b_id, peer_addr, relay_server, signal, forced)`；同 `a_addr` 已有记录就 `attempts += 1` |
| H2 | `handle_hole_sent` L655-687 | `on_reply(addr_a, PunchHoleSent, phs.id, phs.relay_server, phs.nat_type, phs.version, has_v6)` |
| H3 | `handle_local_addr` L689-719 | `on_reply(addr_a, LocalAddr, ...)` |
| H4 | `handle_tcp` `RelayResponse` 分支 L555-574，在改写 `relay_server` 之前 | `rr.uuid` 非空（或 `rr.id()` 非空）→ 按 `by_punch_addr` 记分支 X；否则按 `by_relay_addr` 记回落响应 |
| H5 | `handle_tcp` `RequestRelay` 分支 L541-554 | `on_request_relay(addr, rf.id, rf.uuid, rf.relay_server, rf.token, found_in_memory)`：按 `by_pair` 找 60 秒内、已收到 (a)/(b) 回应的最近一条，优先 `relay_server == b_relay` 的；挂上 `by_relay_addr`。找不到就单独记一条 `signal='relay_only'` |

**定稿规则**：
- `signal` 以 `fail_` 开头 → `rejected`。
- 最后一次请求后 20 秒仍无 `reply` → `no_reply`。
- `reply = relay_response`（分支 X）→ `relay`；若 `a_has_v6 && b_has_v6` → `relay_or_v6`。
- `reply ∈ {punch_hole_sent, local_addr}`：
  - `reply_at` 后 45 秒内有匹配的 `RequestRelay`：有 `relay_resp_at` → `relay`，没有 → `relay_failed`。
  - 45 秒内没有 → `direct`（再细分：`local_addr` → `direct_lan`；`a_has_v6 && b_has_v6` → `direct_tcp_or_v6`；否则 `direct_tcp`）。
- 45 秒的依据：A 直连最长等 18 秒（`CONNECT_TIMEOUT`），之后才发 `RequestRelay`；留余量【推测：窗口值要实测调】。
- **中继回落率** = (`relay` + `relay_or_v6`) / (`relay*` + `direct*`)，排除 `rejected`、`no_reply`、`relay_failed`。
- 原版已有的 `PUNCH_REQS`（L64-89，`from_ip / to_ip / to_id`，60 秒去重）可以作为起点，但它只记请求、不记结果。

---

## 5. 发起方身份与 IP

- `PunchHoleRequest` 没有发起方 id【读码，proto `hbb@5d52530:protos/rendezvous.proto` L31-47】。能用的线索：
  - `token` = A 的 `access_token`（`cli:src/ui_session_interface.rs` L1984），只在 A 登录过 API 时非空。porta-server 自己签发令牌，能反查账号；如果登录时把请求体里的 `id`/`uuid`（`docs/research/03` §2.2）和令牌一起存下来，还能反查到 A 的设备 id【读码：令牌来源；推测：反查方案】。前提是 §6.2 的 KeyExchange 已实现，否则带令牌的客户端根本连不上。
  - `switch_code`：只在"切换控制方向"时有。
  - 启发式：A 通常自己也是注册设备，可以按"A 的公网 IP == 某设备 `info.ip`"猜，但 NAT 后面多台设备会撞【推测】。
  - `OnlineRequest.id` 带了查询者自己的 id（`cli:src/client.rs` L5331），但走的是 21115 另一条连接，hbbs 也不看。
- A 的 IP 来源【读码】：
  - TCP 21116：`accept()` 拿到的对端地址；双栈监听下 IPv4 是 `::ffff:` 形式。前面套 TCP 反代 / Docker userland-proxy 时就变成代理的地址（不支持 PROXY protocol）。
  - WS 21118：`handle_listener_inner` L1192-1218，先找 `X-Real-IP`，没有再找 `X-Forwarded-For`，**整串**当 IP 解析，端口置 0，不做任何校验。`X-Forwarded-For: a, b` 这种多值解析失败，就退回 TCP 对端地址（代理的地址）。21118 直接暴露时谁都能伪造来源 IP，影响按 IP 选中继、IP 限流和记录。
  - B 的 IP：`peer.socket_addr`，最近一次 UDP 注册的源地址。

---

## 6. key 机制、mask/local_ip、ALWAYS_USE_RELAY、IPv6 信令

### 6.1 `-k` 与 `id_ed25519`【读码】
- `get_server_sk(key)`（L1269-1295）：
  - `key` 是 base64 的 64 字节私钥 → 用它签名，校验用的 key 换成后半段（公钥）的 base64。
  - `key` 为 `-`、`_` 或空 → `gen_sk(0)`（common.rs L349-390）：工作目录有 `id_ed25519` 就读（unix 下顺手修权限到 0600），没有就生成（公钥里避开 `/`、`:`），写 `id_ed25519` + `id_ed25519.pub`；`-`/`_` 时校验 key = 公钥，**空串时校验 key 保持为空（不校验）但仍有私钥用于签名**。
  - 其他字符串 → 当公钥用于校验，`sk = None`（不签名）。
- main.rs 默认 `get_arg_or("key", "-")`，即默认生成/读取密钥并强制校验。
- 校验点只有一个：`handle_punch_hole_request` L730-738，`ph.licence_key != key` → `LICENSE_MISMATCH`。`RequestRelay` 到 hbbs 时**不带也不查** key（A 只在发给 hbbr 的那份里带）。
- 签名 `get_pk(version, id)`（L1244-1267）：`version` 为空或 `sk` 为 None → 空；否则对 `IdPk{id, pk: 库里/内存里的 pk}` 编码后 `sign::sign`。用在 `PunchHoleResponse.pk` 和分支 X 的 `RelayResponse.pk`。客户端用配置的 key 验签，id 对上才信这个 pk（`cli:src/client.rs` `secure_connection` L1653 起）。
  - 升级到 `hbb@5d52530` 后 `hbb_common::message_proto` 已经不存在（`message.proto` 从 hbb_common 删了，`lib.rs` 只剩 `rendezvous_proto`），L1253 要改成 `hbb_common::rendezvous_proto::IdPk`。新 `IdPk` 多了 `dtls_fingerprint=3`、`kx_version=4`，服务端照旧只填 1、2 即可，客户端兼容【读码】。这是 hbbs 源码里唯一一处因升级 hbb_common 必须改的 API（其余用到的 `AddrMangle`、`try_into_v4`、`FramedSocket::new_reuse`、`tcp::listen_any`/`new_listener`、`get_version_from_url`、`gen_version`、`version_check_request` 在 5d52530 都还在）。

### 6.2 TCP 密钥交换（KeyExchange）：原版没有，Porta 必须做【读码】
- 客户端什么时候要求加密（hbbs 必须先发 `KeyExchange`）：
  - `_start_inner`：`legacy_secure = !key.is_empty() && (!token.is_empty() || !switch_code.is_empty())`（`cli:src/client.rs` L860）→ `secure_tcp(...).map_err(...)?`（L887-891）。
  - `request_relay`：同样条件（L1808-1810）。
  - 被控端 TCP 注册 `start_tcp`（`cli:src/rendezvous_mediator.rs` L594）、`hc_connection_`（`cli:src/client.rs` L5236，只在服务端回了 `feedback≠0` 时才有）、API 的 TCP 代理回落 `tcp_proxy_request`（`cli:src/common.rs` L1451）。
  - WebRTC 信令用 `secure_tcp_required`（不加密就放弃 WebRTC，不报错）。
- `key_exchange`（`cli:src/common.rs` L2259-2325）：`timeout(18s, conn.next()).await?`。**超时是 Err**（`hbb_common::timeout` 就是 `tokio::time::timeout`），只有"收到了但不是 KeyExchange"才返回 `Ok(false)` 被容忍。原版 hbbs 连上后一言不发 → 18 秒后报错 → `Failed to secure tcp: deadline has elapsed: Please try later`。1.5.0 正式版同样如此（我对过 `1.5.0:src/client.rs` L877-880、L1798-1800）。
- 其他读路径都用 `get_next_nonkeyexchange_msg`（L2148-2169）跳过 KeyExchange，说明协议设计就是"服务端每条 TCP 连接一上来先发 KeyExchange，不需要的客户端跳过"。`_start_inner` 的回包循环、`request_relay`、NAT 测试、`check_id`、在线查询都用它【读码】。被控端那几条临时连接（`PunchHoleSent`/`LocalAddr`/`RelayResponse`）只发不读，服务端先发的 KeyExchange 被忽略，没影响。
- 实现草图（客户端测试里有现成的服务端替身：`cli:src/common.rs` L3306-3460 `rendezvous_stub`、`signed_key_exchange`、`test_secure_tcp_legacy_and_signed_servers_exchange_application_data`）：
  1. 非 WS 的 TCP 连接 accept 后，若有 `sk`：`(eph_pk, eph_sk) = box_::gen_keypair()`。
     - v0（最简单）：发 `KeyExchange{keys: [sign::sign(&eph_pk.0, sk)]}`。
     - v1：`eph_pk.0[31] |= 0x80`；`params = KxParams{pk: eph_pk.0, version: 1}`；`signed_params = sign::sign(KX_PARAMS_DOMAIN ++ params.write_to_bytes(), sk)`；发 `KeyExchange{keys:[sign::sign(&eph_pk.0, sk)], version: 1, signed_params}`。
  2. 读第一帧：是 `KeyExchange` 且 `keys.len()==2` → `shared = Encrypt::decode(&keys[1], &keys[0], &eph_sk)`；`ex.version >= 1` → `Encrypt::new_split(shared, false, &KxTranscript{initiator_pk:&keys[0], responder_pk:&eph_pk.0（含高位）, advertised:1, picked:ex.version})`，否则 `Encrypt::new(shared)`。之后每帧收 `dec`、发 `enc`。
  3. 第一帧不是 KeyExchange → 按明文 `RendezvousMessage` 交给 `handle_tcp`，连接保持明文。
- 结构改动：`handle_listener_inner` 现在用 `Framed<TcpStream, BytesCodec>` 拆成读写两半，写半边存进 `tcp_punch` 的 `Sink::TcpStream`，不支持加密。要给写半边配一份 `Encrypt`（`hbb@5d52530:src/tcp.rs` L63 `Encrypt` 是 `Clone`，发送只动字段 0/1，接收只动 2/3，克隆两份分给读写两边可行【读码；可行性推测】），`Sink` 变成 `TcpStream(SplitSink, Option<Encrypt>)`。
- `Encrypt::new_split`、`KX_PARAMS_DOMAIN`、`KxParams`、`KeyExchange.version/signed_params` 只在 `hbb@5d52530` 有；`hbb@69cea8d` 只有 v0 需要的 `Encrypt::decode` / `set_key`。
- 顺带：实现了 KeyExchange 之后，`HttpProxyRequest`（API 经 21116 回落）才有意义；第一期可以不做（01 号笔记同结论）。

### 6.3 mask / local_ip【读码】
- `--mask`（help 里标废弃，仍生效）：`get_arg("mask").parse::<Ipv4Network>().ok()`。
- `local_ip`：只有配了 mask 才算，`get_arg_or("local-ip", local_ip_address::local_ip())`；没配 mask 时为空串。
- `is_lan(addr)`（L1297-1313）：mask 包含该 IPv4（IPv6 先 `to_ipv4()`，`::1` 会被转成 `0.0.0.1` 之类）；没 mask 恒为 false。
- 用途：`handle_punch_hole_request` 里 `peer_is_lan ^ is_lan` → 强制中继，B 在内网时 relay 换成 `local_ip`；`same_intranet` 的条件之一；`RelayResponse` 改写（§3.1 #2）。
- Porta 的部署不需要 mask，可以不碰。

### 6.4 ALWAYS_USE_RELAY【读码】
- 启动时 `get_arg("ALWAYS_USE_RELAY").to_uppercase() == "Y"`；运行时控制台 `aur Y|N`（带 §3.4 的 bug）。
- 作用：`handle_punch_hole_request` L771-777 把转给 B 的 `nat_type` 改成 `SYMMETRIC`，B 因此走分支 X。
- 漏洞：`same_intranet` 的判断在它之后、和它无关（L778-785），**两台公网 IP 相同的设备会拿到 `FetchLocalAddr`，照样局域网直连**，不受 `ALWAYS_USE_RELAY` 约束。
- Porta 补了 v6 转发以后要注意：强制中继时还得把转发的 `socket_addr_v6` 清空、`force_relay` 置真，否则 B 会一边走中继一边做 v6 打洞，A 让两者赛跑，可能绕过强制中继（B 的 `punch_v6 = 有 v6 && !relay`，`relay` 只看 `ph.force_relay` 和自己的代理，`cli:src/rendezvous_mediator.rs` L1052-1097）。

### 6.5 IPv6 打洞信令：原版完全不处理【读码】
- 原版 hbbs 对 `socket_addr_v6` 不是"透传"，是**丢弃**（§0 第 2 条）。后果：B 收到的 `PunchHole.socket_addr_v6` 为空 → `punch_v6 = false` → 不起 v6；B 回的 `PunchHoleSent.socket_addr_v6` 也被 `handle_hole_sent` 丢掉；A 收到的 `PunchHoleResponse.socket_addr_v6` 为空，不建 v6 连接（`cli:src/client.rs` L1037-1046）。
- porta-server 要补的字段（全是加法，原版客户端兼容）：
  | 方向 | 位置 | 补什么 |
  |---|---|---|
  | `PunchHoleRequest` → `PunchHole` | L806-811 | `socket_addr_v6`、`force_relay`；`upnp_port` 可带可不带 |
  | `PunchHoleRequest` → `FetchLocalAddr` | L794-798 | `socket_addr_v6` |
  | `PunchHoleSent` → `PunchHoleResponse` | `handle_hole_sent` L671-676 | `socket_addr_v6`、`upnp_port` |
  | `LocalAddr` → `PunchHoleResponse` | `handle_local_addr` L705-711 | `socket_addr_v6` |
  | `RelayResponse` | L555-574 | 已整条透传，无需改 |
- **第一期建议不转发 `udp_port`**：转发了，开了 UDP 打洞的控制端会让 B 改用 UDP 发 `PunchHoleSent`，而 hbbs 丢弃 UDP 上的 `PunchHoleSent`（L479-481），连 v6 地址一起丢。不转发时 B 一律走 TCP 发 `PunchHoleSent`（`cli:src/rendezvous_mediator.rs` L1145、L1165-1182），v6 能带到。
- `webrtc_sdp_offer/answer`、`IceCandidate` 第一期不转发（WebRTC 不在范围内，且需要 §6.2）。
- 控制端要手动打开 `enable-ipv6-punch`（LocalConfig 选项，心跳下发改不到，见 01 号笔记 §4）；被控端不检查这个开关（`handle_punch_hole` / `start_ipv6` 里没有判断，L1425-1462）【读码】。

### 6.6 rendezvous.proto：`69cea8d` → `5d52530` 对服务端的影响【读码】
`git diff 69cea8d 5d52530 -- protos/`：`rendezvous.proto` +41 行，`message.proto` 整个删除（挪到客户端仓库）。
| 改动 | 对服务端 |
|---|---|
| 新增 `IdPk`（从 message.proto 挪来，加 `dtls_fingerprint=3`、`kx_version=4`） | `get_pk` 的路径要改（§6.1），编码兼容 |
| `PunchHoleRequest.webrtc_sdp_offer=12`、`PunchHole.webrtc_sdp_offer=10`、`PunchHoleSent/PunchHoleResponse/RelayResponse.webrtc_sdp_answer` | 只在要支持 WebRTC 时转发 |
| `ControlPermissions.usb=13` | 原版不用 |
| `KeyExchange.version=2`、`signed_params=3`，新增 `KxParams` | §6.2 的 v1 用 |
| `IceCandidate=29` | WebRTC 信令转发用，原版忽略 |
| `message_proto` 模块消失 | 唯一的编译破坏点 |
`HttpProxyRequest/Response`（27/28）、`HealthCheck`（26）在 69cea8d 就已经有，原版 hbbs 一直忽略。

---

## 7. 现有测试【读码】
| 测试 | 位置 | 内容 |
|---|---|---|
| `deeply_nested_unknown_groups_are_rejected_without_aborting` | `tests/protobuf_recursion.rs` | 子进程里解析 30 万层嵌套的 unknown group，要求 `parse_from_bytes` 返回错误而不是栈溢出崩溃（依赖 protobuf 的递归上限） |
| `udp_listener_uses_bind_address` | `rendezvous_server.rs` L1426-1431 | `-b` 绑 UDP |
| `punch_reqs_bounded` | L1433-1453 | `PUNCH_REQS` 上限和淘汰顺序 |
| `argument_names_ignore_case_and_separator` | `common.rs` L460-487 | `get_arg` 四种拼法、优先级 |
| `parses_bind_address`、`tcp_listener_uses_bind_address`、`console_addr_only_when_bind_does_not_cover_ipv4_localhost`、`console_listener_binds_ipv4_localhost` | `common.rs` L489-547 | 绑定地址、控制台监听 |
| `key_path_symlinks_are_bounded`、`private_key_file_permissions`（含子进程、rlimit） | `common.rs` L549-731，仅 unix | key 文件权限、符号链接、写失败恢复 |
| `test_insert` | `database.rs` L146-180 | 1 万行并发插入/读取，不清理 `test.sqlite3`，重复运行会失败 |
- CI（`.github/workflows/build.yaml`）只 `cargo build --release`，**不跑测试**。
- 没有任何会合流程（打洞、中继、注册）的集成测试。Porta 写挂钩时可以照 `cli:src/common.rs` 的 `rendezvous_stub` 写法，用回环地址起真实监听测 KeyExchange 和消息转发。

---

## 8. 其他坑
- `handle_udp` 里任何 `socket.send` 出错都会让主循环返回 `LoopFailure::UdpSocket` 并重建 UDP socket【读码】。
- `test_hbbs` 自测每秒往自己发一次注册，12 秒没回包直接 `exit(1)`；部署在 NAT/代理后可设 `TEST_HBBS=no`【读码】。
- `handle_udp_punch_hole_request`（L905-921）是死代码【读码】。
- `ConfigureUpdate` / `serial` / `rendezvous_servers` / `software_url` 都是废弃功能，Porta 可以删【读码】。
- `PunchHoleResponse.feedback` / `RelayResponse.feedback` 原版从不填。填了非 0，带令牌的控制端会在整个会话期间额外挂一条 `HealthCheck` TCP 连接到 hbbs（`cli:src/client.rs` L5208-5275 `hc_connection`），能当"会话持续时间"信号；但服务端得按 `keep_alive` 回心跳，否则客户端自己断。第一期不建议碰【读码；用途推测】。

---

## 9. 交给主会话的方向性问题
1. §6.2 的 KeyExchange 是不是第一期必做？按代码看是必做（否则登录用户全部连不上），工作量集中在 `handle_listener_inner` 的读写两半加密，要改 `Sink` 类型。v0 还是 v1 也要定（建议 v1，hbb_common 5d52530 已有全部原语）。
2. 现在的部署用的是哪个 hbbs 镜像（原版、lejianwen fork 还是 s6）？如果是 lejianwen fork，它可能已经实现了 KeyExchange 甚至 v6 转发，切到 porta-server 时功能不能倒退。
3. 要不要支持 TCP 注册（代理/WS/禁 UDP 的被控端）？原版不支持，Pro 支持。维护者的设备如果都走 UDP，第一期可以不做。
4. 架构 §3.8 的"IPv6 打洞读码成立"要改写：hbbs 要补转发，控制端要手动开开关（与 01 号笔记一致）。
5. API 和会合模块的数据库是共用一个连接池还是分开？建议分开或加大池子并显式开 WAL。
