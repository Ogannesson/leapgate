# 06 · 智能路由第一级：GeoIP/ASN 库落地细节

> Porta 是当时的工作名，2026-10-24 改名为 Leapgate（跃门）。

查证日期：2026-10-22。标注约定：【官方】= 一手网页（附 URL）；【实测】= 当天对官方下载地址发 HEAD 请求（没下载文件本体）；【读码】= 读了源码（附路径和函数名）；【旁证】= 第三方仓库或文章；【推测】= 自己的判断，没有一手依据。

对应方案：`docs/architecture.md` §3.7（第一级只改服务端，用 GeoIP/ASN 估算延迟，推荐 DB-IP Lite，备选 MaxMind GeoLite）。

---

## 0. 结论速览（给写代码的 agent）

| 项 | 定论 |
|---|---|
| 数据库 | DB-IP **City Lite** + **ASN Lite**，MMDB 格式，`.mmdb.gz` |
| 下载 URL | `https://download.db-ip.com/free/dbip-city-lite-{YYYY-MM}.mmdb.gz`、`https://download.db-ip.com/free/dbip-asn-lite-{YYYY-MM}.mmdb.gz` |
| 发布时间 | 每月 1 日，约 06:30 UTC 上线；没发布的月份返回 404；上个月的文件还在，一年前的已删 |
| 大小（2026-10） | City：gz 60,193,321 B，解压后 126,998,165 B（约 121 MiB）；ASN：gz 5,186,202 B，解压后约 9.1 MB |
| 读库 crate | `maxminddb = { version = "0.32.0", features = ["mmap"] }`（2026-09-12 发布，已满两周） |
| 字段 | City：`location.latitude` / `location.longitude`（f64）、`country.iso_code`；ASN：`autonomous_system_number`（u32）、`autonomous_system_organization`（str）。和 GeoLite2 键名一致 |
| 换库只改配置？ | **读取这一侧成立，下载这一侧不成立**（MaxMind 要账号、Basic 认证、tar.gz 打包，EULA 要求 30 天内删旧库），见 §1.4 |
| HTTP 客户端 | 用服务端已有的 `reqwest`（rustdesk-org fork）+ 已有的 `flate2` 解压；**`minreq` 在上游没开 `https` feature，不能用** |
| 校验 | gzip 尾部 CRC32 + 长度（flate2 自动校验）+ Content-Length + 用 maxminddb 打开并抽查几个 IP；官方**没有**能用机器读的校验和文件 |
| RTT 估算 | `rtt_ms = d_km × 2 × k / 200 + 惩罚`，`k` 默认 2.0 |

---

## 1. DB-IP Lite

### 1.1 下载 URL、命名、更新时间

- 【官方】Lite 总页 https://db-ip.com/db/lite.php ：三个 Lite 库（Country / City / ASN），都有 CSV 和 MMDB 两种格式，每月更新；当天页面上写的版本是 October 2026。
- 【官方】City Lite 下载页 https://db-ip.com/db/download/ip-to-city-lite 和 ASN Lite 下载页 https://db-ip.com/db/download/ip-to-asn-lite ，下载链接的 href 是：
  - `https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz`
  - `https://download.db-ip.com/free/dbip-asn-lite-2026-10.mmdb.gz`
  - CSV 版本把 `.mmdb.gz` 换成 `.csv.gz`。
  - 规律：`dbip-{city|asn|country}-lite-{YYYY-MM}.mmdb.gz`，按月命名，gzip 压缩（单文件 gzip，**不是** tar）。
- 【实测】2026-10-22 对官方下载地址发 HEAD 请求：

  | URL 的文件名部分 | 状态 | Content-Length | Last-Modified |
  |---|---|---|---|
  | `dbip-city-lite-2026-10.mmdb.gz` | 200 | 60193321 | Thu, 01 Oct 2026 06:29:28 GMT |
  | `dbip-asn-lite-2026-10.mmdb.gz` | 200 | 5186202 | Thu, 01 Oct 2026 06:29:28 GMT |
  | `dbip-city-lite-2026-09.mmdb.gz` | 200 | 60287600 | Tue, 01 Sep 2026 06:27:03 GMT |
  | `dbip-city-lite-2026-11.mmdb.gz`（还没发布） | 404，`Content-Type: text/html` | — | — |
  | `dbip-city-lite-2025-10.mmdb.gz`（一年前） | 404 | — | — |
  | `dbip-city-lite-latest.mmdb.gz` | 404（官方没有 latest 别名） | — | — |
  | `dbip-city-lite-2026-10.mmdb.gz.sha1sum` | 404（官方不提供校验和文件） | — | — |

  - 响应头：`server: cloudflare`、`Cache-Control: max-age=28800`（8 小时），**404 响应也带同样的缓存头**。所以每月 1 日刚过 0 点就请求新月份，可能拿到被 CDN 缓存的 404，最多 8 小时后才能拿到新文件。【推测】实现时每天重试一次就够，不用在 1 日密集轮询。
  - 推论【实测 + 推测】：发布时间是每月 1 日约 06:30 UTC；官方至少保留上个月的文件，第一次部署时当月文件 404 可以退回上个月。
- 【旁证】第三方镜像 https://dbip.mirror.framasoft.org/files/ 也是同样的命名，另外提供 `.md5sum` / `.sha1sum` / `.sha512sum` 和 `-latest` 别名。它不是官方的，**不要拿它当默认下载源**，只在文档里提一句"官方源不可达时可以手动换"。

### 1.2 文件大小与官方校验值

- 【官方】City Lite MMDB（October 2026）：7,786,864 条记录，标注大小 121.1 MB，MD5 `5966907981d3e82f338e823d1b83e002`，SHA1 `df17bd24390108ed1d24dcb7718dc60f6b9abd4f`。
- 【官方】ASN Lite MMDB（October 2026）：477,362 条记录，标注大小 9.1 MB，MD5 `918a033bb1424c310ea5dedbd2e6e173`，SHA1 `bc76615cd8f99b7b3a878803b1c84cbeda65769a`。
- 【旁证 + 实测】官方页面上的大小和 MD5 都是**解压后 .mmdb** 的：framasoft 镜像里 `dbip-city-lite-2026-10.mmdb.md5sum` 的值和官方页面一致（`5966…e002`），而 `.mmdb.gz` 的 MD5 是 `cea73c8f…e116`；解压后 126,998,165 B ≈ 121.1 MiB，和官方标注一致。
- 也就是说，官方校验值只出现在 HTML 页面上，没有机器可读的文件。**不建议抓 HTML 页面取校验值**，页面结构一改就坏。校验方案见 §3.3。
- 内存影响【推测】：City 库解压后约 127 MB。用 `Reader::open_readfile` 会整块读进堆内存（【读码】maxminddb `reader.rs` `open_readfile` 是 `fs::read`）；用 `mmap` 时这部分是可回收的文件页缓存，只有被访问到的页常驻。**必须开 `mmap` feature**，尤其在小内存机器上。

### 1.3 许可证与署名

- 【官方】许可证：Creative Commons Attribution 4.0 International（CC BY 4.0）。页面原意：只要注明数据来自 DB-IP.com 就可以在应用里使用；**Web 应用**必须在展示或使用查询结果的页面上放回链，官方给的 HTML 片段是：
  ```html
  <a href='https://db-ip.com'>IP Geolocation by DB-IP</a>
  ```
- 【官方】下载页注明下载即表示同意许可条款。
- 落地建议【推测】：
  - 第一期只有命令行、没有网页后台，就在 README 和 NOTICE 文件里写 `IP Geolocation by DB-IP (https://db-ip.com), licensed under CC BY 4.0`；服务端加载库时打一行 info 日志，带上同样的署名和库的版本月份。
  - 以后网页后台或客户端界面上只要显示"按地理位置选中继"的结果（比如显示对方城市），就在那一页放上面那段 HTML 回链。
  - **不把 mmdb 打进仓库或发布包**：运行时下载，免得仓库体积膨胀，也省掉再分发时附许可声明的麻烦。如果以后要打包，得在包里附 CC BY 4.0 声明和出处。

### 1.4 MMDB 字段结构，以及和 GeoLite2 是否一致

**City Lite**（【官方】格式说明 https://db-ip.com/db/format/ip-to-city-lite/mmdb.html ）：

| 键路径 | 类型 | 说明 |
|---|---|---|
| `city.names.{lang}` | map<utf8> | 城市名，多语言（en、zh-CN 等） |
| `continent.code` | utf8 | 两字母洲代码 |
| `continent.geoname_id` | uint32 | |
| `continent.names` | map<utf8> | |
| `country.geoname_id` | uint32 | |
| `country.iso_code` | utf8 | ISO 3166-1 alpha-2，**国家代码键** |
| `country.is_in_european_union` | bool | |
| `country.names` | map<utf8> | |
| `location.latitude` | double | **纬度** |
| `location.longitude` | double | **经度** |
| `subdivisions[].names` | map<utf8> | 省/州；官方示例里还出现了 `geoname_id`、`iso_code`，但 schema 没写 |

- 官方说法：格式符合 MMDB 2.0 规范，"尽量贴近现有工具期望的 schema"，nginx `ngx_http_geoip2_module`、Apache `mod_maxminddb` 都能读。官方页面**没有点名**和 GeoIP2 City 兼容。
- DB-IP City Lite **没有**这些 GeoLite2 City 有的字段：`location.accuracy_radius`、`location.time_zone`、`registered_country`、`postal`、`traits`。代码里不要依赖它们；要用 `accuracy_radius` 也必须处理 `None`。

**ASN Lite**：
- 【官方】下载页只说包含"AS number、AS organization"。官方格式说明页 https://db-ip.com/db/format/ip-to-asn-lite/mmdb.html 的内容**疑似贴错了**：列的是 country/continent 键，示例也是国家数据（2026-10-22 页面现状）。不能拿它当依据。
- 【旁证】实际文件用 `mmdblookup` 查 1.1.1.1 返回 `autonomous_system_number: 13335 <uint32>`、`autonomous_system_organization: "Cloudflare, Inc." <utf8_string>`；元数据 `database_type` 是 `DBIP-ASN-Lite (compat=GeoLite2-ASN)`（https://github.com/oschwald/geoip2-golang/issues/69 ）。sapics/ip-location-db 的 npm 包说明也写的是这两个键（https://registry.npmjs.org/%40ip-location-db%2Fdbip-asn-mmdb ）。
- 【官方】MaxMind GeoLite ASN 的键名同样是 `autonomous_system_number`（uint32）和 `autonomous_system_organization`（string）（https://dev.maxmind.com/geoip/docs/databases/asn/binary/ ，检索摘要里看到的，没有逐字打开这一页）。

**和 MaxMind GeoLite2 对比：**

| 维度 | 是否一致 | 依据 |
|---|---|---|
| City 键名（`location.latitude/longitude`、`country.iso_code`） | 一致 | maxminddb crate 的 `geoip2::City` 按 GeoIP2 schema 定义（§2），能直接解出 DB-IP 的这几个字段；wp-statistics 等项目直接用 GeoIP2 的读库代码读 DB-IP City Lite【旁证】 |
| ASN 键名 | 一致 | 见上 |
| `database_type` 元数据 | **不一致**（DB-IP 是 `DBIP-…-Lite (compat=…)`） | 严格检查类型的读库代码会拒绝（Go 的 geoip2-golang 出过这个问题）。**Rust maxminddb 打开和查询时都不检查 `database_type`**（【读码】`reader.rs` `validate_metadata_for_reader` 只查格式主版本、ip_version、node_count、build_time、record_size；`database_type` 只在 `verify()` 里要求非空），所以不受影响 |
| 下载方式 | **不一致** | MaxMind：要注册账号拿 license key，用 Basic 认证请求 `https://download.maxmind.com/geoip/databases/GeoLite2-City/download?suffix=tar.gz`，会 302 到 R2 预签名地址；返回 tar.gz，里面是带日期的目录加 mmdb；GeoLite 账号每天限 30 次下载（https://dev.maxmind.com/geoip/updating-databases/ 、https://support.maxmind.com/knowledge-base/articles/download-and-update-maxmind-databases ） |
| 更新频率 | 不一致 | GeoLite City 每周二、五更新，GeoLite ASN 每个工作日更新（同上 support 页）；DB-IP Lite 每月一次 |
| 许可证义务 | 不一致 | GeoLite EULA 要求新版发布后 30 天内删除旧库（https://dev.maxmind.com/geoip/geolite2-free-geolocation-data/ ），也就是必须自动更新 |

**结论**："换库只改配置"在**读取层**成立：同一个 `geoip2::City` / `geoip2::Asn` 结构体，换个文件路径就行。**下载层**不成立。建议【推测】：
- 自动下载只实现 DB-IP 一种（`geoip.provider = "dbip"`）。
- 另外提供 `geoip.provider = "file"`：只给 `city_path` / `asn_path`，由运维自己用 MaxMind 官方的 `geoipupdate` 维护文件，服务端每天看一次文件 mtime，变了就重新加载。这样切换 GeoLite 也只改配置，不用写 MaxMind 的下载代码，也不用保管 license key。

---

## 2. Rust 读 MMDB：maxminddb crate

- 【官方】crates.io 版本列表（https://crates.io/api/v1/crates/maxminddb/versions ）：

  | 版本 | 发布时间（UTC） | 备注 |
  |---|---|---|
  | 0.32.0 | 2026-09-12 | **选这个**（满 40 天）；去掉了 `simdutf8` feature |
  | 0.31.0 | 2026-09-07 | 修复了构造恶意数据库导致的 DoS（解码加资源上限），City 的 subdivisions 限 32 条 |
  | 0.30.x | 2026-07 / 08 | |

  不要低于 0.31（DoS 修复，见 https://github.com/oschwald/maxminddb-rust/releases ）。
- Cargo：
  ```toml
  maxminddb = { version = "0.32.0", features = ["mmap"] }
  ```
- 依赖【官方】（https://crates.io/api/v1/crates/maxminddb/0.32.0/dependencies ）：普通依赖只有 `ipnetwork ^0.21.1`、`memchr ^2.4`、`serde ^1.0`（derive）、`thiserror ^2.0`，可选 `memmap2 ^0.9`（`mmap` feature）。edition 2021，没声明 `rust-version`。很轻。
  - 注意【读码】上游 rustdesk-server 的 `Cargo.toml` 钉的是 `ipnetwork = "0.20"`，加上 maxminddb 后会同时编进两个版本的 ipnetwork。能编译，只是 `LookupResult::network()` 返回 0.21 的类型，不要和服务端现有的 0.20 `IpNetwork` 混着用。
- API（0.32，【官方】docs.rs https://docs.rs/maxminddb/0.32.0/ ，以及 README 示例）。**0.2x 以前的 `reader.lookup::<T>(ip)` 写法已经不能用了**，现在 lookup 返回句柄，再 decode：
  ```rust
  use maxminddb::{geoip2, Reader, Mmap};
  // SAFETY: 文件只会被整体 rename 替换，不会被原地修改或截断
  let city: Reader<Mmap> = unsafe { Reader::open_mmap(path)? };
  let r = city.lookup(ip)?;                 // Result<LookupResult, MaxMindDbError>
  if let Some(c) = r.decode::<geoip2::City>()? {  // Option：没有记录时为 None
      let lat: Option<f64> = c.location.latitude;
      let lon: Option<f64> = c.location.longitude;
      let cc: Option<&str> = c.country.iso_code;
  }
  let asn_r = asn_reader.lookup(ip)?;
  if let Some(a) = asn_r.decode::<geoip2::Asn>()? {
      let n: Option<u32> = a.autonomous_system_number;
      let org: Option<&str> = a.autonomous_system_organization;
  }
  ```
  - 字段类型【官方 docs.rs】：`geoip2::City<'a>` 的 `location: city::Location<'a>`，`Location { latitude: Option<f64>, longitude: Option<f64>, accuracy_radius: Option<u16>, time_zone: Option<&'a str>, metro_code(废弃) }`；嵌套结构体总是存在，字段缺失时是默认值（None 或空）。`geoip2::Asn<'a> { autonomous_system_number: Option<u32>, autonomous_system_organization: Option<&'a str> }`。字符串借用自 Reader 的缓冲区，要存进缓存就 `.to_owned()`。
  - 只要几个字段时可以用 `r.decode_path(&path!["location","latitude"])`，少解一些结构；`r.offset()` 可以当缓存键（同一网段的记录共享同一个 offset）。
  - `Reader::open_mmap` 是 `unsafe fn`。文档要求 Reader 存活期间文件不能被修改或截断（【读码】`reader.rs` `open_mmap` 的 Safety 注释）。**更新时只能写新文件再 rename，或者换文件名，绝不能原地覆盖。**Linux 上 rename 或 unlink 一个正被 mmap 的文件是安全的：旧 inode 会一直保留到映射解除。Windows 上替换或删除正被映射的文件会失败（开发机上要容忍这个错误）。
  - IPv4 地址可以直接查 IPv6 库（DB-IP 的库同时含 v4 和 v6），crate 内部会处理（【读码】`lookup` 对 v4 走 `find_address_in_tree_v4`）。
- 能不能读 DB-IP：能。见 §1.4，crate 不检查 `database_type`，键名一致。
- 线程共享：`Reader<Mmap>` 是只读的，可以放进 `Arc` 跨线程共享。热更新用 `RwLock<Arc<GeoDb>>`（读的时候 clone 一下 Arc，几乎没有开销）就够，不必引入 `arc-swap`。

---

## 3. 自动更新：最简做法

### 3.1 HTTP 客户端选型

- 【读码】`upstream/rustdesk-server@873230e:Cargo.toml`：
  - `minreq = { version = "2.4", features = ["punycode"] }`：**没开 `https` feature，发不了 HTTPS**，而且 `src/` 里根本没用到它。不要选它。
  - `reqwest`（git `rustdesk-org/reqwest`）：Linux 上 features 是 `blocking, socks, json, rustls-tls, rustls-tls-native-roots, gzip`，`default-features=false`；Windows/macOS 上用 `native-tls`。已经用在 `src/common.rs` 的 `check_software_update_` 里（`reqwest::Client::builder().build()?.post(url)…`）。
  - `flate2 = "1.0"` 已经在依赖里。
- 结论：**用现成的 reqwest 加 flate2，不新增依赖。**
  - 没开 `stream` feature，所以没有 `bytes_stream()`。用 `resp.chunk().await?` 循环写临时文件，不用开新 feature，也不会把 60 MB 整块读进内存。
  - 开了 `gzip` feature 的 reqwest 会发 `Accept-Encoding: gzip`，响应带 `Content-Encoding: gzip` 时会自动解压。DB-IP 返回的是 `application/octet-stream`，不带 Content-Encoding（【实测】响应头里没有），所以拿到的就是 .gz 原始字节，要自己用 flate2 解压。【推测】万一 CDN 哪天对它再套一层传输压缩，reqwest 会透明解掉一层，拿到的仍然是 .gz 文件本身，逻辑不受影响。
  - reqwest 默认会跟随重定向（最多 10 次）；DB-IP 现在不重定向。
  - 下载在 tokio 后台任务里跑（不要用 `check_software_update` 那种每次新建 runtime 的写法），设好总超时（比如 10 分钟）和连接超时（比如 30 秒）。

### 3.2 文件布局与流程（建议）

数据目录（比如 `{data_dir}/geoip/`）：
```
dbip-city-lite-2026-10.mmdb     # 当前使用中
dbip-asn-lite-2026-10.mmdb
*.part                          # 下载或解压中的临时文件，启动时清理
```
**用"文件名带月份"代替"同名覆盖 + 旁边放版本文件"**：版本信息就在文件名里，不需要额外的状态文件。新文件 rename 成最终名字之后才算"有效"，部分写入的文件永远不会被当成可用文件加载。

**启动时：**
1. 删掉目录里残留的 `*.part`。
2. 在目录里找文件名月份最大的 city 和 asn 文件。找到就 `open_mmap` 加 §3.3 的抽查，通过就装进 `RwLock<Arc<GeoDb>>`；打开失败就记 error，删掉这个文件，退到下一个较旧的文件。
3. 本地一个都没有：GeoIP 先禁用（路由走回退逻辑，见 §5），**不阻塞服务启动**；后台立即触发一次更新。
4. 启动后台更新任务：启动后马上跑一次，之后每 24 小时跑一次。

**每次更新检查：**
1. `want = 当前 UTC 年月`。本地 city 和 asn 的月份都已经 ≥ `want`，就跳过。
2. 依次下载 `want`；遇到 404 时，如果本地完全没有库，再试上个月（第一次部署正赶上 1 日 06:30 UTC 之前，或者 CDN 还缓存着 404 的情况）；本地已经有旧库，就保持旧库，等明天再试。
3. 下载到 `X.mmdb.gz.part`：检查 HTTP 状态是 200，**`Content-Type` 不是 `text/html`**，写入的字节数等于 `Content-Length`，并设上限（city gz ≤ 256 MiB，asn gz ≤ 64 MiB，防止异常响应把磁盘写满）。
4. 用 `flate2::bufread::GzDecoder`（或 `read::GzDecoder`）流式解压到 `X.mmdb.part`，要读到 EOF（`std::io::copy`），解压后大小也设上限（比如 1 GiB）。解压读到流末尾时 flate2 会核对 gzip 尾部的 CRC32 和长度，对不上就返回错误 `corrupt gzip stream does not have a matching checksum`（【读码】flate2 `src/gz/bufread.rs` 读 trailer 时比较 `crc` 和 `amount`；`src/gz/mod.rs` `fn corrupt`）。解压会占几秒 CPU，放进 `spawn_blocking`。
5. 对 `X.mmdb.part` 做 §3.3 的校验。
6. `fsync` 之后 `rename(X.mmdb.part → dbip-city-lite-{YYYY-MM}.mmdb)`。同一目录内的 rename 在 Linux 上是原子的。
7. city 和 asn **两个都成功**之后，再一起 `open_mmap` 新文件，换进 `RwLock` 里（新 Arc 换掉旧 Arc）。之后删旧月份的文件：旧 Reader 可能还被正在处理的请求持有，Linux 上 unlink 不影响已有的映射；Windows 上删除失败就忽略，下次启动再删。
8. 任何一步失败：删掉这次的 `*.part`，**保留并继续使用旧文件**，记 warn，24 小时后重试。可以加一个计数，连续失败 N 次（比如本地库已经落后 2 个月以上）就升级成 error 日志，不做别的处理。

**配置项（最少）：**
```toml
[geoip]
provider = "dbip"          # "dbip" | "file" | "off"
dir = "/var/lib/porta/geoip"   # provider=dbip 时使用
# provider=file 时：
# city_path = "/usr/share/GeoIP/GeoLite2-City.mmdb"
# asn_path  = "/usr/share/GeoIP/GeoLite2-ASN.mmdb"
```
下载 URL 模板写成代码常量，不做成配置项：配置项越少越好，真要换镜像源再加。

### 3.3 校验方式（只校验会变的东西）

官方没有机器可读的校验和（§1.1、§1.2），HTTPS 已经保证了传输来源。下面三层足够，而且每次都必须做，因为下载内容每个月都不一样：
1. **传输完整性**：字节数等于 Content-Length，gzip 尾部的 CRC32 和长度由 flate2 自动核对。
2. **格式有效**：`Reader::from_source` / `open_mmap` 成功（会校验 metadata：格式主版本 2、ip_version、node_count、record_size，【读码】`validate_metadata_for_reader`）。`metadata().database_type` 应包含 `City` 或 `ASN`（【推测】DB-IP City 的具体字符串没核实，ASN 是 `DBIP-ASN-Lite (compat=GeoLite2-ASN)`；只做包含检查，不要等值比较），这样能防止把 city 和 asn 的文件弄反。
3. **抽查内容**：city 库查 `8.8.8.8` 和 `1.1.1.1`，至少一个返回 `location.latitude/longitude` 都是 `Some` 且 `country.iso_code` 非空；asn 库查 `8.8.8.8`，`autonomous_system_number == Some(15169)`（【推测】Google 的 AS15169 长期稳定，适合做哨兵；万一哪天不是了，只检查 `is_some()` 也行）。
- 不建议对 127 MB 的库每次都跑 `Reader::verify()`（会走一遍全部数据，CPU 开销大）；手动诊断命令里可以提供。

---

## 4. 从经纬度估算 RTT

### 4.1 公式

```
d_km   = haversine(lat1, lon1, lat2, lon2)，地球半径 R = 6371 km
rtt_ms = 2 × d_km × k / v_fiber + Σ惩罚
       = d_km × k / 100 + Σ惩罚        （v_fiber = 200 km/ms）
```
- **v_fiber ≈ 200 km/ms（2/3 c）**：光纤折射率约 1.47，信号在光纤里约走真空光速的 2/3。【官方·论文】Gueye 等，Constraint-Based Geolocation（IMC 2004），https://www.cs.bu.edu/fac/crovella/paper-archive/imc04-geolocation-full.pdf ，原文表述为"almost exactly 2/3 the speed of light in a vacuum"；Katz-Bassett 等（IMC 2006）沿用同一个说法。换算下来：每 100 km 大圆距离对应理想往返 1 ms。
- **绕行系数 k（相对光纤直线距离）**：
  - Singla 等，The Internet at the Speed of Light（HotNets 2014，https://pbg.cs.illinois.edu/papers/singla14cspeed.pdf ）：最小 ping 的中位数约是真空光速大圆往返时间的 3.2 倍；按路由器路径算，中位数 2.3 倍，扣掉光纤本身的 1.5 倍后还剩约 1.53 倍；Internet2 和 GÉANT 的点到点光纤长度通常是公路距离的 1.5~2 倍。
  - Bozkurt 等，Why Is the Internet so Slow?!（PAM 2017，https://cspeedweb.web.engr.illinois.edu/assets/publications/bozkurt-pam2017.pdf ）：最小 ping 中位数约 3.1 倍真空光速时延（检索摘要里的数字，没有逐字打开 PDF）。
  - Katz-Bassett 等，Towards IP Geolocation Using Delay and Topology Measurements（IMC 2006，http://conferences.sigcomm.org/imc/2006/papers/p7-bassett.pdf ）：25000 多次测量里，按时延折算的"有效速度"几乎都不超过 4/9 c（只有不到 0.04% 超过），也就是 k ≥ 1.5 几乎一定成立。超过 20% 的测量达到 2/9 c，相当于 k ≈ 3。
  - 换算：3.1~3.2 倍真空光速时延 ÷ 1.5 ≈ **k 中位数 2.1**（测量对象是 PlanetLab 这类网络条件好的节点，家宽和移动网络会更差）。
  - **默认 k = 2.0**，配置里可以改。选 1.5 太乐观：这是物理下限，只在两端都在同一张骨干网上直连时才接近。
- 抽查（用上面的公式，k = 2，不加惩罚）：

  | 两地 | 大圆距离 | 估算 RTT | 公开数据参照 |
  |---|---|---|---|
  | 北京 ↔ 上海 | 1067 km | 21 ms | C114 网友 2025-11 晚高峰实测上海电信 → 北京电信 28 ms【旁证】 |
  | 香港 ↔ 法兰克福 | 9158 km | 183 ms | 【推测】常见 160~200 ms |

- **常数项**：接入网（家宽第一跳、4G/5G 空口）会带来固定延迟，但它对每个候选中继都一样，比较中继时会被抵消。只有和直连比较时才有影响，所以**默认不加**，可以配置 `base_ms = 0`。

### 4.2 惩罚项（默认值都是【推测】，可配置）

每一段（发起方 → 中继、被控端 → 中继）分别计算：

| 条件 | 默认 | 依据 |
|---|---|---|
| 同国、同运营商组 | 0 | — |
| 中国境内、跨三大运营商 | **+10 ms** | 公开数据：工信部和地方通信管理局公布的直联点数据，青岛直联点开通后骨干网网间时延从 35.4 ms 降到约 2 ms（https://sdca.miit.gov.cn/xwdt/gzdt/art/2023/art_a480054588c1445f9ea3ff30bf52edf4.html ）；长沙直联点开通后省内网间时延从 21 ms 降到 4 ms（http://gxt.hunan.gov.cn/xxgk_71033/gzdt/jxyw/202309/t20230916_29486563.html ）；宁波直联点开通后从 15 ms 降到 6 ms 以下（媒体报道）。网友实测【旁证】：2024 年天津同城跨网 < 10~20 ms；2024 年末南通电信到联通平均 42 ms，高峰最高 76 ms（https://www.orxy.cn/archives/36.html ）；2025-11 北京移动 → 北京电信晚高峰 66 ms（https://www.txrjy.com/thread-1414116-1-1.html ）。**结论：没有全国统一的公开网间时延数值**（工信部只给过"全国平均网间时延较 2013 年优化 56%"这种相对值）。有直联点的省份闲时只多几 ms，高峰时可能多 20~60 ms，移动到电信、联通往往最差。10 ms 是折中值，第二级测速上线后以实测为准 |
| 一端在中国大陆、另一端在境外（含港澳台） | **+30 ms** | 国际出口拥塞，加上运营商的国际线路质量不一（电信 CN2 和 163 差别很大）。【旁证】衡天云实测香港 163 线路晚高峰：电信 45~65 ms，联通 70~95 ms，移动 85~120 ms；重庆到香港的大圆估算只有 22 ms，差值大致在 20~60 ms。取 30 ms |
| 其他跨国 | 0 | 距离已经体现了大部分差异；Singla 提到的"绕道美国"属于长尾，无法从 GeoIP 预测 |

**"运营商组"怎么判断**【推测】：直接比较 ASN 是否相等太严格。中国运营商按省份和网络层次有很多 ASN（电信 AS4134 / AS4809（CN2）/ 各省 AS，联通 AS4837 / AS9929 / AS4808 / AS17816 等，移动 AS9808 / AS56040~56048 / AS58453（CMI）等），DB-IP ASN Lite 返回的是起源 AS。建议：
- 内置一张小的 ASN → 运营商组表，只列中国三大运营商的主要 ASN（这是 ASN 归属表，不是方案里否决的手写"区域延迟表"），配置里可以追加。
- 表里查不到时，退回"ASN 相等算同组"。
- **不要**拿 `autonomous_system_organization` 做字符串匹配，各个 ASN 的写法不统一。
- 具体 ASN 列表写代码前要再到 bgp.he.net 或 PeeringDB 核对一遍，这里没逐个核实。

### 4.3 代价函数（呼应 §3.7）
```
cost(R) = (rtt(A, R) + rtt(B, R)) × weight(R)
```
- 中继自己的位置：**配置里优先给出经纬度、国家和运营商组**（RustDesk Pro 也提供 Geo Override，因为 GeoLite 不准，见 `docs/research/02` 引用的 rustdesk-server-pro#954）；没配置时，启动时把中继主机名解析成 IP 再查 GeoIP，结果缓存起来。
- 客户端 IP 的查询结果可以按 IP 缓存（LRU，几千条就够），每次加载新库后清空。

---

## 5. 局域网和保留地址的回退

### 5.1 先把地址规范化
- hbbs 监听双栈时，IPv4 客户端的地址可能是 `::ffff:a.b.c.d`。查库和分类之前统一调用 `IpAddr::to_canonical()`（std 1.75 起稳定，【官方】https://doc.rust-lang.org/std/net/struct.Ipv6Addr.html ）。上游的做法是 `hbb_common::try_into_v4(addr)`（【读码】`upstream/rustdesk-server/src/rendezvous_server.rs` 第 486、536、761、1136 行等多处；`fn is_lan` 里用的是 `to_ipv4()`）。
- `Ipv4Addr::is_shared`（100.64/10）、`is_benchmarking`、`IpAddr::is_global` 都还是 nightly 才有（同一文档页；Ipv4 的部分来自页面截断后的常识，【推测】但大概率正确）；`Ipv6Addr::is_unique_local` 和 `is_unicast_link_local` 从 1.84 起稳定。**建议自己用位掩码判断，不依赖 MSRV**：

| 类别 | 网段 | 判断 |
|---|---|---|
| 私网 | 10/8、172.16/12、192.168/16 | `Ipv4Addr::is_private()`（stable） |
| 回环 | 127/8、::1 | `is_loopback()` |
| 链路本地 | 169.254/16、fe80::/10 | v4 用 `is_link_local()`；v6 用 `seg[0] & 0xffc0 == 0xfe80` |
| CGNAT / Tailscale | 100.64/10 | `o[0]==100 && (o[1] & 0xc0)==64` |
| IPv6 ULA | fc00::/7 | `seg[0] & 0xfe00 == 0xfc00` |
| 其他（0/8、198.18/15、文档网段、组播） | — | 当作"查不到" |

### 5.2 回退策略（【推测】，按顺序）
1. **保留上游已有的 LAN 逻辑**：hbbs 配置了 `--mask` 且对端在掩码内时，直接把中继设成 `local_ip`（【读码】`rendezvous_server.rs` `fn is_lan` 和调用处约第 565、768 行）。这一步排在 GeoIP 之前。
2. **私网、回环、链路本地、ULA 来源地址**：能用这种地址连到 hbbs，说明对端和 hbbs 在同一个局域网或私有网络里，**把对端的位置当成服务端自己的位置**（配置 `geoip.server_location = {lat, lon, country, carrier}`；没配置就当作查不到）。
3. **100.64/10**：可能是运营商 CGNAT 内部地址，也可能是 Tailscale 或 Headscale 的 tailnet 地址（现有环境里有 Headscale，而 tailnet 的对端物理上可能在任何地方），**当作查不到**，不要套第 2 条。
4. **公网地址但库里没有记录**（`decode` 返回 None，或者经纬度是 None）：当作查不到。
5. 合并：
   - A 和 B 都有位置：按完整代价公式算。
   - 只有一方有位置：`cost(R) = 2 × rtt(已知方, R) × weight(R)`，相当于假设另一方离中继和已知方差不多远。
   - 两方都没有位置：退回原有行为，也就是上游 `get_relay_server` 在在线中继里轮询，或者用配置的默认中继。
6. 中继自己的位置查不到也没配置：这个中继不参与按地理排序，只在第 5 条的"都不知道"分支里参与轮询。
7. 每次决策记一行 debug 日志（双方的国家、ASN、选中的中继、代价、走了哪个回退分支），方便上线前用 §3.7 要求的"各大洲真实 IP"做对比。

---

## 6. 意外与风险（会影响实现方案）

1. **"换库只改配置"只在读取层成立**：MaxMind 要账号和 license key，用 Basic 认证，返回 tar.gz，EULA 要求 30 天内删旧库，每天限 30 次下载；DB-IP 是不用认证的单文件 gz。建议只给 DB-IP 写自动下载，GeoLite 走"运维用 geoipupdate 维护文件 + 服务端按 mtime 重新加载"。`architecture.md` §3.7 里"换库只改配置"这句话需要加上这个限定。
2. **City 库约 127 MB**：用 `open_readfile` 会多出 127 MB 常驻堆内存，必须开 `mmap`。即便用 mmap，热路径访问到的页也会占用页缓存。如果 porta-server 部署在小内存机器上（现网的 ID 服务器内存很小，见 internal/environment.md），要先评估。
3. **mmap 的约束**：Reader 存活期间绝不能原地覆盖文件，只能换文件名或 rename；Windows 开发机上替换或删除正被映射的文件会失败。
4. **`minreq` 不能发 HTTPS**（上游没开 `https` feature），只能用 reqwest fork，而且没开 `stream` feature，要用 `chunk()` 循环。
5. **官方没有机器可读的校验和**，`-latest` 别名也没有；404 会被 CDN 缓存 8 小时；当月文件在 1 日约 06:30 UTC 才出现。实现必须容忍"当月 404"，首次部署要退回上个月。
6. **DB-IP 的 ASN Lite 格式说明页疑似贴错**（内容是 country 格式），ASN 的键名依据来自第三方实测。【推测】风险很低：多个独立来源一致，而且 database_type 声明 `compat=GeoLite2-ASN`。实现时用 §3.3 的哨兵查询兜底。
7. **DB-IP City Lite 没有 `accuracy_radius`**：代价模型如果想按精度加权，Lite 版做不到。
8. **跨运营商、跨境惩罚没有全国性的一手数据**，默认值都是【推测】，峰谷差异很大（几 ms 到 60 ms）。第一级的效果上限受这一点限制，要靠第二级测速修正。
9. maxminddb 0.32 依赖 ipnetwork 0.21，上游钉的是 0.20，会同时存在两个版本（只是编译体积稍大，不是错误）。
10. maxminddb 0.30 以前的 `lookup::<T>()` API 已经改掉，网上的旧示例不能照抄。
