# 05 · 从 rustdesk-api 的 SQLite 迁移用户和地址簿（字段级）

> Porta 是当时的工作名，2026-10-24 改名为 Leapgate（跃门）。

日期：2026-10-22。基线：`lejianwen/rustdesk-api@c5687e1`（`cmd/apimain.go` 里 `DatabaseVersion = 265`）、客户端 `rustdesk@bd92623`。
标注：【读码】附文件和函数；【实测】是在本机用同版本 gorm 复现 AutoMigrate 和写入路径后读出来的；【推测】是没核实的。

## 0. 怎么核实的

- 表结构不靠猜 gorm 的命名规则，而是实测：把 `model/*.go` 原样拷到 scratch 模块，钉住和上游 `go.mod` 相同的版本（`gorm.io/gorm v1.25.10`、`gorm.io/driver/sqlite v1.5.6`、`github.com/mattn/go-sqlite3 v1.14.23`），按 `cmd/apimain.go` `Migrate()` 的顺序 `AutoMigrate`，再模拟几条真实写入路径（PeerAdd、PeerUpdate、BatchUpdateTags），用 `sqlite3` 读 `sqlite_master` 和 `typeof()`/`quote()`。
  - 复现程序是一个只引用上游 `model/` 的小 Go 模块（调研时在临时目录里跑，没有入库），按上面的版本重跑即可得到同样的 DDL。
- gorm 配置：没有自定义 `NamingStrategy`、`TablePrefix`、`SingularTable`，也没有任何模型实现 `TableName()`【读码】`lib/orm/sqlite.go` `NewSqlite`，全仓 grep 无 `TableName`。所以表名就是 gorm 默认的蛇形复数，列名是蛇形单数。
- 数据库文件：容器里是 `/app/data/rustdeskapi.db`（`lib/orm/sqlite.go` 写死 `./data/rustdeskapi.db`，`Dockerfile` `WORKDIR /app`、`VOLUME /app/data`）【读码】。库类型由 `RUSTDESK_API_GORM_TYPE` 决定，默认 sqlite（`conf/config.yaml` `gorm.type`，`config/config.go` 环境变量前缀 `RUSTDESK_API`）【读码】。现网是不是 SQLite 没核实【推测：默认配置，大概率是】。
- 没有 WAL 设置（DSN 只有文件名）【读码】，默认 rollback journal。导出时先停容器或用 `sqlite3 rustdeskapi.db ".backup out.db"`，避免拷到半截写入。
- 版本检查：`versions` 表每次迁移插一行，`SELECT MAX(version) FROM versions` 是 265 才和本文一致【读码】`cmd/apimain.go` `DatabaseAutoUpdate`/`Migrate`。旧版本库在新版启动时会被 AutoMigrate 补列，所以只要现网跑的是最新镜像，列就齐。

## 1. 表一览：迁不迁

| SQLite 表名 | gorm 模型 | 迁移 | 理由 |
|---|---|---|---|
| `users` | `User` | **迁** | 账号、密码哈希、管理员、启用状态、所属组 |
| `groups` | `Group` | **只读用于展开** | 组共享规则 `type=2` 要靠 `users.group_id` 展开成人；`groups.type` 还决定组面板可见范围（§4.4） |
| `address_book_collections` | `AddressBookCollection` | **迁** | 共享簿 |
| `address_book_collection_rules` | `AddressBookCollectionRule` | **迁**（展开成每人权限） | 共享簿权限 |
| `address_books` | `AddressBook` | **迁** | 个人簿和共享簿的条目 |
| `tags` | `Tag` | **迁** | 每本簿的标签和颜色 |
| `peers` | `Peer` | 可选 | 设备归属（`user_id`）和硬件信息；登录、sysinfo 会重新填，见 §7 |
| `device_groups` | `DeviceGroup` | 可选 | 设备组名，只在组面板显示；个人部署大概率为空【推测】 |
| `user_thirds`、`oauths` | `UserThird`、`Oauth` | 不迁 | Porta 第一期没有 OIDC；但要据此找出只能靠 OAuth 登录的用户（§3.4） |
| `user_tokens` | `UserToken` | 不迁 | 见 §7 |
| `login_logs`、`audit_conns`、`audit_files`、`share_records`、`server_cmds`、`versions` | — | 不迁 | 日志、审计、Web Client 分享、hbbs 命令模板、迁移版本号 |

**没有软删除**：所有模型都不含 `gorm.DeletedAt`，所有 `Delete` 都是物理删除【读码】`model/*.go`。`login_logs.is_deleted` 是业务字段，不是 gorm 软删除。

**通用列**：`IdModel` → `id integer PRIMARY KEY AUTOINCREMENT`；`TimeModel` → `created_at timestamp`、`updated_at timestamp`（可为 NULL）【实测】。gorm 自动填这两列，map 方式的 `Updates` 也会刷新 `updated_at`【实测】。

**时间的实际存储格式**【实测】：TEXT，mattn 驱动的 `SQLiteTimestampFormats[0]`，例如 `2026-10-22 18:37:17.4472008+08:00`（小数位数不固定，末尾 0 会被去掉；时区取容器的 `TZ`，示例 compose 里是 `Asia/Shanghai`）。chrono 解析：`DateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S%.f%:z")`，失败就当 NULL。时间戳没什么迁移价值，建议只搬 `users.created_at`，其余用导入时间。

**布尔列**：DDL 是 `numeric NOT NULL DEFAULT false`，实际存整数 0/1【实测】。读时 `CAST(x AS INTEGER)`。

## 2. 逐表结构（DDL 为实测原文）

### 2.1 `users`

```sql
CREATE TABLE `users` (`id` integer PRIMARY KEY AUTOINCREMENT,`username` text NOT NULL DEFAULT "",`email` text NOT NULL DEFAULT "",`password` text NOT NULL DEFAULT "",`nickname` text NOT NULL DEFAULT "",`avatar` text NOT NULL DEFAULT "",`group_id` integer NOT NULL DEFAULT 0,`is_admin` numeric NOT NULL DEFAULT false,`status` integer NOT NULL DEFAULT 1,`remark` text NOT NULL DEFAULT "",`created_at` timestamp,`updated_at` timestamp);
CREATE INDEX `idx_users_email` ON `users`(`email`);
CREATE INDEX `idx_users_group_id` ON `users`(`group_id`);
CREATE UNIQUE INDEX `idx_users_username` ON `users`(`username`);
```

| 列 | 含义 | 迁移处理 |
|---|---|---|
| `id` | 用户主键；其他表的 `user_id`、规则的 `to_id`（`type=1`）都指向它 | 建旧 id → 新 id 映射 |
| `username` | 登录名，唯一索引。`UserService.Create` 会去空格、转小写（`formatUsername`），但首个 admin 是直接 `DB.Create` 的 `"admin"`，LDAP 同步的用户名原样写入【读码】`service/user.go` `Create`/`formatUsername`、`cmd/apimain.go` `Migrate`、`service/ldap.go`。登录时按 `username = ?` 精确匹配（SQLite 默认 BINARY，大小写敏感）【读码】`InfoByUsernamePassword` | 原样搬；Porta 若改成大小写不敏感，导入时先查小写后是否撞名 |
| `email` | 可为空串 | 原样 |
| `password` | 见 §3：bcrypt `$2a$10$…`（60 字符）、旧版 MD5（32 位小写 hex）、或空串（OAuth/LDAP 注册的用户） | 原样存进 Porta 的哈希列，登录时识别格式 |
| `nickname`、`avatar`、`remark` | 显示名、头像 URL、备注 | 可选 |
| `group_id` | 所属用户组（单值），新用户默认 1【读码】`Register`、`RegisterByOauth` | 只用于展开组规则 |
| `is_admin` | 0/1 | 映射成 Porta 管理员标记 |
| `status` | **1=启用，2=禁用**（`model.COMMON_STATUS_*`）【读码】`model/model.go`。客户端的 `UserStatus` 是 0=禁用、1=正常、-1=未验证（注释见 `http/response/api/user.go`），rustdesk-api 把 2 原样回给客户端 | 2 → 禁用 |

### 2.2 `groups`

```sql
CREATE TABLE `groups` (`id` integer PRIMARY KEY AUTOINCREMENT,`name` text NOT NULL DEFAULT "",`type` integer NOT NULL DEFAULT 1,`created_at` timestamp,`updated_at` timestamp);
```

- `type`：1=默认组，2=共享组（`model.GroupTypeDefault/Share`）。首次建库时插入 id=1（默认组）和 id=2（共享组），名字按 `lang` 本地化【读码】`cmd/apimain.go` `Migrate`。
- `type` 的唯一用途：组面板 `/api/users`、`/api/peers` 里，非管理员只有在共享组（type=2）才能看到同组其他人和他们的设备，否则只看到自己；管理员看到本组全部【读码】`http/controller/api/group.go` `Users`/`Peers`。
- 删组不会改成员的 `group_id`【读码】`http/controller/admin/group.go` `Delete`，所以 `users.group_id` 可能指向不存在的组。组规则按数字匹配 `users.group_id`，组行不存在也照样生效【读码】`service/addressBook.go` `CollectionReadRules`/`UserMaxRule`。

### 2.3 `address_book_collections`（共享簿）

```sql
CREATE TABLE `address_book_collections` (`id` integer PRIMARY KEY AUTOINCREMENT,`user_id` integer NOT NULL DEFAULT 0,`name` text NOT NULL DEFAULT "",`created_at` timestamp,`updated_at` timestamp);
CREATE INDEX `idx_address_book_collections_user_id` ON `address_book_collections`(`user_id`);
```

- `user_id` = 主人。主人对自己的簿恒为完全控制（`UserMaxRule` 里 `user.Id == uid` 直接返回 3）【读码】。
- 没有 `note` 列，客户端 `AbProfile.note` 没处可存【读码】`model/addressBook.go`、客户端 `flutter/lib/common/hbbs/hbbs.dart` `AbProfile`。
- `name` 不唯一，见 §8.3 撞名问题。
- 删用户时连带删他的簿、条目、他建的规则（`user_id = ?`），但**指向他的规则（`to_id`）不删**【读码】`service/user.go` `Delete`。删簿时删规则和条目，但**不删标签**【读码】`DeleteCollection`。

### 2.4 `address_book_collection_rules`（共享规则）

```sql
CREATE TABLE `address_book_collection_rules` (`id` integer PRIMARY KEY AUTOINCREMENT,`user_id` integer NOT NULL DEFAULT 0,`collection_id` integer NOT NULL DEFAULT 0,`rule` integer NOT NULL DEFAULT 0,`type` integer NOT NULL DEFAULT 1,`to_id` integer NOT NULL DEFAULT 0,`created_at` timestamp,`updated_at` timestamp);
CREATE INDEX `idx_address_book_collection_rules_collection_id` ON `address_book_collection_rules`(`collection_id`);
```

| 列 | 含义 |
|---|---|
| `user_id` | 簿的主人（建规则时校验 `CheckCollectionOwner(user_id, collection_id)`）【读码】`http/controller/admin/addressBookCollectionRule.go` `CheckForm` |
| `collection_id` | 共享簿 id（校验 `required`，> 0） |
| `type` | **1=授权给个人（`to_id` 是 `users.id`），2=授权给用户组（`to_id` 是 `groups.id`，匹配 `users.group_id`）** |
| `to_id` | 被授权对象；`type=1` 时不能等于主人 |
| `rule` | **1=只读，2=读写，3=完全控制**；校验 `gte=1,lte=3` |

- 和客户端完全同值：客户端 `enum ShareRule { read(1), readWrite(2), fullControl(3) }`【读码】`flutter/lib/common/hbbs/hbbs.dart`。rustdesk-api 直接把 `rule` 放进 `/api/ab/shared/profiles` 的 `rule` 字段【读码】`http/controller/api/ab.go` `SharedProfiles`。
- 同一 `(type, to_id, collection_id)` 建规则时查重，只有一条【读码】`CheckForm` 末尾 `RuleInfoByToIdAndCid`。
- 有效权限 = max(主人?3 : 0, 个人规则, 组规则)【读码】`UserMaxRule`。各接口门槛：读（列表、标签列表）≥1；写（加条目、改条目、加/改名/改色标签）≥2；完全控制（删条目、删标签）=3【读码】`ab.go` 各 handler。

### 2.5 `address_books`（条目）

```sql
CREATE TABLE `address_books` (`row_id` integer PRIMARY KEY AUTOINCREMENT,`id` text NOT NULL DEFAULT "0",`username` text NOT NULL DEFAULT "",`password` text NOT NULL DEFAULT "",`hostname` text NOT NULL DEFAULT "",`alias` text NOT NULL DEFAULT "",`platform` text NOT NULL DEFAULT "",`tags` text NOT NULL,`hash` text NOT NULL DEFAULT "",`user_id` integer NOT NULL DEFAULT 0,`force_always_relay` numeric NOT NULL DEFAULT false,`rdp_port` text NOT NULL DEFAULT "",`rdp_username` text NOT NULL DEFAULT "",`online` numeric NOT NULL DEFAULT false,`login_name` text NOT NULL DEFAULT "",`same_server` numeric NOT NULL DEFAULT false,`collection_id` integer NOT NULL DEFAULT 0,`created_at` timestamp,`updated_at` timestamp);
CREATE INDEX `idx_address_books_collection_id` ON `address_books`(`collection_id`);
CREATE INDEX `idx_address_books_id` ON `address_books`(`id`);
CREATE INDEX `idx_address_books_user_id` ON `address_books`(`user_id`);
```

- 主键是 `row_id`；`id` 是 RustDesk 设备 ID（字符串）。
- **个人簿条目：`collection_id = 0`，`user_id` = 主人。共享簿条目：`collection_id = 簿 id`，`user_id` = 簿主人**（不是添加者）：所有接口都用 guid 里解析出的 `uid`（簿主人）和 `cid` 读写【读码】`ab.go` `PeerAdd`（`f.UserId = uid`、`ab.CollectionId = cid`）、`Peers`（`ListByUserIdAndCollectionId(uid, cid)`）。后台建条目也校验 `CheckCollectionOwner`【读码】`http/controller/admin/addressBook.go` `Create`/`Update`。
- 逻辑键 `(user_id, collection_id, id)` **没有唯一索引**，`PeerAdd` 不查重（靠客户端查），可能有重复行。更新、删除用 `InfoByUserIdAndIdAndCid(...).First()`，gorm `First` 按主键升序取第一条，所以 rustdesk-api 实际改的是 **row_id 最小**的那条【读码 + gorm `First` 语义】。导入时同键保留 `MIN(row_id)`。
- 字段逐个见 §5。

### 2.6 `tags`

```sql
CREATE TABLE `tags` (`id` integer PRIMARY KEY AUTOINCREMENT,`name` text NOT NULL DEFAULT "",`user_id` integer NOT NULL DEFAULT 0,`color` integer NOT NULL DEFAULT 0,`collection_id` integer NOT NULL DEFAULT 0,`created_at` timestamp,`updated_at` timestamp);
CREATE INDEX `idx_tags_collection_id` ON `tags`(`collection_id`);
CREATE INDEX `idx_tags_user_id` ON `tags`(`user_id`);
```

见 §6。

### 2.7 `peers`（可选）

```sql
CREATE TABLE `peers` (`row_id` integer PRIMARY KEY AUTOINCREMENT,`id` text NOT NULL DEFAULT "",`cpu` text NOT NULL DEFAULT "",`hostname` text NOT NULL DEFAULT "",`memory` text NOT NULL DEFAULT "",`os` text NOT NULL DEFAULT "",`username` text NOT NULL DEFAULT "",`uuid` text NOT NULL DEFAULT "",`version` text NOT NULL DEFAULT "",`user_id` integer NOT NULL DEFAULT 0,`last_online_time` integer NOT NULL DEFAULT 0,`last_online_ip` text NOT NULL DEFAULT "",`group_id` integer NOT NULL DEFAULT 0,`alias` text NOT NULL DEFAULT "",`created_at` timestamp,`updated_at` timestamp);
-- 索引：alias, group_id, id, user_id, uuid（均非唯一）
```

- `id` 设备 ID，`uuid` 客户端上报的机器 uuid 字符串；`cpu/memory/os/username/hostname/version` 来自 `/api/sysinfo`【读码】`http/controller/api/peer.go` `SysInfo`。
- `user_id`：设备归属。登录时按登录表单里的 `uuid` 找到 peer 写入（`UuidBindUserId`），登出清零；sysinfo 新建 peer 时从 `login_logs` 找最近一次登录补上【读码】`service/user.go` `Login`、`service/peer.go`、`SysInfo`。
- `last_online_time`（Unix 秒）/`last_online_ip`：心跳每 30 秒以上才更新一次【读码】`http/controller/api/index.go`。
- `group_id` → `device_groups.id`；`alias` 只在后台用。
- `id` 也无唯一索引，`FindById` 取 row_id 最小那条【读码】。

### 2.8 不迁的表（DDL 实测，供参考）

```sql
CREATE TABLE `user_tokens` (`id` integer PRIMARY KEY AUTOINCREMENT,`user_id` integer NOT NULL DEFAULT 0,`device_uuid` text DEFAULT "",`device_id` text DEFAULT "",`token` text NOT NULL DEFAULT "",`expired_at` integer NOT NULL DEFAULT 0,`created_at` timestamp,`updated_at` timestamp);
CREATE TABLE `user_thirds` (`id` integer PRIMARY KEY AUTOINCREMENT,`user_id` integer NOT NULL,`open_id` text NOT NULL,`name` text,`username` text,`email` text,`verified_email` numeric,`picture` text,`union_id` text NOT NULL DEFAULT "",`third_type` text NOT NULL DEFAULT "",`oauth_type` text NOT NULL DEFAULT "",`op` text NOT NULL DEFAULT "",`created_at` timestamp,`updated_at` timestamp);
CREATE TABLE `device_groups` (`id` integer PRIMARY KEY AUTOINCREMENT,`name` text NOT NULL DEFAULT "",`created_at` timestamp,`updated_at` timestamp);
CREATE TABLE `login_logs` (`id` integer PRIMARY KEY AUTOINCREMENT,`user_id` integer NOT NULL DEFAULT 0,`client` text,`device_id` text,`uuid` text,`ip` text,`type` text,`platform` text,`user_token_id` integer NOT NULL DEFAULT 0,`is_deleted` integer NOT NULL DEFAULT 0,`created_at` timestamp,`updated_at` timestamp);
-- 另有 oauths、share_records、audit_conns、audit_files、server_cmds、versions，略
```

`user_tokens.token`：配了 `jwt.key` 时是 JWT，否则是 `md5(username + time.Now().String())` 的 32 位 hex【读码】`service/user.go` `GenerateToken`。

## 3. 用户密码哈希

### 3.1 rustdesk-api 怎么存、怎么验【读码】`utils/password.go`

- 新建、改密码：`bcrypt.GenerateFromPassword(pw, bcrypt.DefaultCost)`，Go `golang.org/x/crypto/bcrypt`（v0.33.0），产出 `$2a$10$` 开头、60 字符。实测样例前缀 `$2a$10$`、长度 60【实测】。
- 校验 `VerifyPassword(hash, input)`：
  1. 先 `bcrypt.CompareHashAndPassword`，通过即成功。
  2. 若 bcrypt 报 `InvalidHashPrefixError` 或 `ErrHashTooShort`（即存的不是 bcrypt），再比 **`hash == hex(md5(input + "rustdesk-api"))`**（`utils.Md5` = `fmt.Sprintf("%x", md5.Sum(...))`，小写 hex）。通过则返回新的 bcrypt 哈希，调用方 `InfoByUsernamePassword` 写回 `password` 列（登录即升级）。
  3. 空串 `""`：bcrypt 报 `ErrHashTooShort`，MD5 也比不上，返回错误 → 不能用密码登录。OAuth 自动注册（`RegisterByOauth`）和 LDAP 同步的用户 `password` 都是空串【读码】`service/user.go`、`service/ldap.go`。
- 客户端登录接口 `/api/login` 里密码是明文 JSON 字段，校验规则 `username` 2~32、`password` 4~32 字符【读码】`http/request/api/user.go` `LoginForm`。

### 3.2 Porta 登录校验（建议实现）

按 `password` 列内容分派：

| 存储值 | 判定 | 校验 | 通过后 |
|---|---|---|---|
| `$argon2id$…` | Porta 自己的 | `argon2` crate `PasswordHash::new` + `Argon2::default().verify_password` | — |
| `$2a$`/`$2b$`/`$2y$` 开头 | bcrypt（旧） | `bcrypt` crate：`bcrypt::verify(input, stored) -> Result<bool>` | 立即用 argon2 重算，写回 |
| 恰好 32 位 `[0-9a-f]` | 旧 MD5 | `hex::encode(Md5::digest(format!("{input}rustdesk-api")))` 与存储值比较（`md-5` + `hex`，比较可用 `subtle::ConstantTimeEq`） | 同上 |
| 空串 | 无本地密码 | 一律失败 | 用命令行重设密码 |

Rust crate 建议：`argon2`（RustCrypto，含 `password-hash` 的 PHC 字符串）、`bcrypt`（Keats/rust-bcrypt）、`md-5`、`hex`、`subtle`（可选）。

- bcrypt 72 字节：Go x/crypto 新版对超过 72 字节的密码直接拒绝生成【推测：记得是 2024 年加的，未查 changelog】；rust-bcrypt 的 `verify` 默认把输入截到 72 字节。登录接口本身限制 32 字符，不影响。
- 不能在导入时把 bcrypt 转成 argon2（没有明文），只能"登录即升级"。不登录的账号会一直留着 bcrypt，可以接受。

### 3.3 只能靠 OAuth/LDAP 登录的用户

`password = ''` 的用户迁过去无法登录（Porta 第一期不做 OIDC）。导入器要列出这些用户，提示维护者用命令行设密码。查哪些人绑过第三方：`SELECT user_id, op, oauth_type, username, email FROM user_thirds`。

## 4. 个人簿、共享簿和权限

### 4.1 区分方式【读码】

- 个人簿：**`address_books.collection_id = 0`** 且 `user_id` = 主人；标签同理 `tags.collection_id = 0`。没有独立的"个人簿"行，每个用户隐含一本。
- 共享簿：`address_book_collections` 一行一本，条目和标签用 `collection_id = 簿 id`、`user_id = 簿主人`。
- `/api/ab/personal` 在 `rustdesk.personal = 1`（默认）时回 `{"guid": "<group_id>-<user_id>-0", "name": username, "rule": 3}`；为 0 时回 `null`，客户端退回旧版 `/api/ab`【读码】`ab.go` `Personal`。旧版 `/api/ab` 读写的也是 `collection_id = 0` 的行，所以两种模式的数据在同一张表里。

### 4.2 guid 格式不用沿用

rustdesk-api 的 guid 是 `"{users.group_id}-{簿主人 user_id}-{collection_id}"`，个人簿 cid=0【读码】`ab.go` `ComposeGuid`/`ParseGuid`/`CheckGuid`。客户端每次拉列表都重新取 `/api/ab/personal` 和 `/api/ab/shared/profiles` 的 guid，不依赖旧值【读码】客户端 `flutter/lib/models/ab_model.dart` `_pullAb`（"Read personal guid every time"）。迁移后 Porta 用自己的 guid 即可。

### 4.3 规则 → Porta "多本 + 权限"

- 个人规则（`type=1`）：直接成为 (簿, 用户, rule)。
- 组规则（`type=2`）：rustdesk-api 在访问时按当前 `users.group_id` 动态匹配。Porta 第一期没有用户组概念时，导入时**按当时的组成员快照展开**成每人一条，和个人规则取 max（与 `UserMaxRule` 一致）。代价：以后有人换组，权限不会跟着变。这是要主会话定的点（§9）。
- 主人不写规则，Porta 里主人恒为完全控制。
- rustdesk-api 列共享簿时有个隐含条件：`SharedProfiles` 用**规则的 `user_id`**去加载主人，再按**簿的 `user_id`**查表，两者不一致的簿会被跳过（客户端看不到）【读码】`ab.go` `SharedProfiles`（`allUserIds[rule.UserId]` 与 `allUserIds[collection.UserId]`）。正常写入路径都保证两者一致，导入时加 `r.user_id = c.user_id` 过滤，并把不一致的记日志。
- `rule` 不在 1~3 的行跳过（`CollectionReadRules` 只取 `rule > 0`）。`collection_id` 指向不存在的簿、`type=1` 的 `to_id` 指向已删用户、或 `to_id` 就是主人的规则都跳过。

### 4.4 组面板语义（顺带记下，非迁移数据）

`/api/users`、`/api/peers`：管理员或共享组（`groups.type=2`）成员看到同组所有用户及其 `peers`（按 `peers.user_id`），其他人只看到自己【读码】`api/group.go`。Porta 若要保持这个行为，需要迁 `users.group_id` 和 `groups.type`；若第一期简化（比如只看自己），就不必迁。

## 5. 条目字段 ↔ 客户端 Peer

客户端 Peer 的 JSON 键见 `flutter/lib/models/peer_model.dart` `Peer.fromJson`/`toJson`【读码】。rustdesk-api 用 `model.AddressBook` 的 json tag 直接序列化返回【读码】`ab.go` `Peers`。

| 客户端键（fromJson） | 客户端类型/解析 | `address_books` 列 | rustdesk-api 实际行为 | 导入 / Porta 处理 |
|---|---|---|---|---|
| `id` | String | `id` | 正常 | 原样；空串跳过 |
| `hash` | String，个人簿用 | `hash` | 个人簿：客户端只传 hash、删掉 password（`addPeers` 里 `removePassword`）；连接成功后自动同步（`sync_peer_hash_password_to_personal_ab`）【读码】客户端 `ab_model.dart` `addPeers`、`src/client.rs` | 原样搬。它是 `base64(标准字母表, 带填充)(sha256(明文密码 + 对端 salt))`，客户端在 `handle_hash` 里直接当预哈希密码用（`try_get_password_from_personal_ab`）【读码】`src/client.rs` `handle_hash`、`src/ui_interface.rs` `peer_to_map`。**能直接登录对端，等同明文**，建议和共享簿密码一样加密落盘 |
| `password` | String，共享簿用 | `password` | 共享簿：客户端明文上传、删掉 hash（`removeHash`）【读码】；后台也能给任意条目设 | 两种簿都可能非空，一律加密后落盘 |
| `username` | String | `username` | `PeerAdd` 时若 platform/username/hostname 有空，从 `peers` 表补【读码】`ab.go` `PeerAdd` | 原样 |
| `hostname` | String | `hostname` | 同上 | 原样 |
| `platform` | String | `platform` | 补全时由 `PlatformFromOs` 给 `Windows`/`Linux`/`Mac OS`/`Android`/空 | 原样 |
| `alias` | String | `alias` | 正常 | 原样 |
| `tags` | `List<dynamic>`（标签名数组） | `tags` | JSON 数组文本；**存储类型混杂**：create 路径存 TEXT，`PeerUpdate`/`BatchUpdateTags` 用 `[]byte` 写入存成 **BLOB**；没传 tags 时存字符串 `null`（TEXT 或 BLOB）【实测，见 §0】 | `CAST(tags AS TEXT)` 后 JSON 解析；`null`/空串/解析失败 → `[]`；只保留字符串元素 |
| `forceAlwaysRelay` | **字符串**比较：`json['forceAlwaysRelay'] == 'true'`；上传时 `forceAlwaysRelay.toString()` | `force_always_relay`（0/1） | 上传时外层表单字段是 string，`== "true"` 转 bool 存库【读码】`http/request/api/peer.go` `PersonalAddressBookForm.ToAddressBook`；**返回时是 JSON 布尔**，客户端拿 `true == 'true'` 恒为 false | 原样搬 0/1；Porta 返回时给字符串 `"true"`/`"false"` |
| `rdpPort`、`rdpUsername` | String | `rdp_port`、`rdp_username` | 正常 | 原样 |
| `loginName` | String | `login_name` | 正常 | 原样 |
| `same_server` | `bool?`，键名带下划线 | `same_server` | rustdesk-api 的 json tag 是 `sameServer`，和客户端的 `same_server` 对不上，**上传和返回都失效**，列恒为 0（除非后台手改）【读码】 | 不值得迁；Porta 用 `same_server` 键 |
| `note` | String | **无此列** | 客户端上传的 note 被丢弃；`PeerUpdate` 白名单只有 `password`、`hash`、`tags`、`alias`【读码】`ab.go` `PeerUpdate` | 无数据可迁；Porta 要新增 |
| `device_group_name` | String | 无 | 不存 | 无 |
| `online` | 客户端不从 JSON 读 | `online` | 客户端不传，恒为 0 | 不迁 |

另外两条和迁移无关、但实现兼容接口时要知道的【读码】：
- 客户端 `syncFromRecent` 会经 `/api/ab/peer/update` 提交 `username`/`hostname`/`platform`，rustdesk-api 的白名单把它们丢了，所以库里这三列可能是加入时的旧值。
- 旧版 `POST /api/ab`（`UpdateAddressBook`、`TagService.UpdateTags`）按 `user_id` 全量对比，不区分 `collection_id`，会误删该用户名下共享簿的条目和标签。新版模式下不走这条路，只是解释现网数据里可能出现的缺失。

## 6. 标签

- 归属：`(user_id, collection_id)`，与条目相同：个人簿 `collection_id = 0`、`user_id` = 主人；共享簿 `collection_id` = 簿 id、`user_id` = 簿主人【读码】`ab.go` `TagAdd`（`t.UserId = uid; t.CollectionId = cid`）、`service/tag.go` `ListByUserIdAndCollectionId`（按 `name asc`）。
- `name`：标签名，条目 `tags` 数组里存的就是名字，**没有外键**。改名（`TagRename`）只改 `tags` 表，不改条目里的名字【读码】；删标签也不清条目里的名字。所以条目可能引用不存在的标签，导入照原样保留名字即可（客户端加条目时会 `removeNonExistentTags`，展示时怎么处理未查）。
- `color`：`uint`，Flutter `Color.value`，即 32 位 ARGB（`0xAARRGGBB`），存 INTEGER，最大 4294967295【读码】`model/tag.go` 注释；实测 `0xFF2196F3` 存为 4280391411。Rust 用 `i64` 读再 `u32::try_from`；客户端上传/读取都是整数（`"color": color.value`）【读码】客户端 `ab_model.dart`。
- 逻辑键 `(user_id, collection_id, name)` 无唯一索引，`TagAdd` 查重，但仍可能有重复；`InfoByUserIdAndNameAndCollectionId` 用 `First()` 取 id 最小那条，导入保留 `MIN(id)`。
- 删共享簿不删其标签 → 可能有 `collection_id` 指向不存在簿的孤儿标签，跳过。

## 7. 不值得迁的数据

- `user_tokens`：Porta 的 token 格式和签发方式不同，不迁。后果：切换后所有客户端第一次调用用户态接口拿到 401，客户端会清 token、清地址簿和组缓存（`userModel.reset(resetOther: true)`），用户要在每台设备重新登录【读码，见 `docs/research/03` §2.x "失效"】。地址簿数据在服务端，重新登录后拉回来，不丢。用户只有几个人，可以接受。若想无感切换，可以把未过期的 `token`（opaque 字符串）连同 `user_id`、`expired_at` 导入并在过渡期接受，但不建议。
- `login_logs`、`audit_conns`、`audit_files`：历史日志；审计表因客户端重试大概率每条写了 3 份（`internal/environment.md` 记过）。
- `share_records`（Web Client 分享链接）、`server_cmds`（发给 hbbs/hbbr 的命令模板）、`oauths`（含 `client_secret`）、`versions`。
- `address_books.online`、`same_server`（见 §5），`created_at`/`updated_at`（除 `users.created_at` 外）。
- `peers`：可选。登录（按 uuid 绑定归属）和 sysinfo/心跳会重新填满；只有"切换后没人再在上面登录过、但想保留归属"的设备才需要迁。若 Porta 的设备表沿用 hbbs 的 `peer` 表，可以只补 `user_id` 归属。

## 8. 导入器 SQL 草稿

约定：只读打开源库（rusqlite `OpenFlags::SQLITE_OPEN_READ_ONLY`，或 sqlx `?mode=ro`）。导入器跑在 `porta-server` 命令行里（需要拿到共享簿密码的落盘加密密钥），整体放一个目标库事务里，先出一份 dry-run 报告（各表计数、空密码用户、重复、孤儿、撞名），确认后再写。

### 8.0 预检

```sql
SELECT MAX(version) FROM versions;                  -- 期望 265
SELECT name FROM pragma_table_info('address_books'); -- 必须含 collection_id、tags、hash、password
SELECT name FROM pragma_table_info('tags');          -- 必须含 collection_id、color
```

### 8.1 用户

```sql
SELECT id, username, email, password, nickname, avatar, remark,
       group_id,
       CAST(is_admin AS INTEGER) AS is_admin,
       status,                               -- 1 启用 / 2 禁用
       created_at
FROM users
ORDER BY id;
```

无本地密码的用户（导入后提示设密码）：

```sql
SELECT u.id, u.username,
       (SELECT group_concat(op) FROM user_thirds t WHERE t.user_id = u.id) AS oauth_ops
FROM users u WHERE u.password = '';
```

### 8.2 共享簿

```sql
SELECT c.id, c.user_id AS owner_id, c.name, c.created_at
FROM address_book_collections c
JOIN users u ON u.id = c.user_id      -- 主人已删的簿丢弃
ORDER BY c.id;
```

### 8.3 共享权限（已展开为每人，取最大）

```sql
SELECT collection_id, user_id, MAX(rule) AS rule
FROM (
  -- 个人规则
  SELECT r.collection_id, r.to_id AS user_id, r.rule
  FROM address_book_collection_rules r
  JOIN address_book_collections c ON c.id = r.collection_id AND c.user_id = r.user_id
  JOIN users u ON u.id = r.to_id
  WHERE r.type = 1 AND r.rule BETWEEN 1 AND 3 AND r.to_id <> c.user_id
  UNION ALL
  -- 组规则，按当前 users.group_id 快照展开（组行不存在也照样匹配，和 rustdesk-api 一致）
  SELECT r.collection_id, u.id AS user_id, r.rule
  FROM address_book_collection_rules r
  JOIN address_book_collections c ON c.id = r.collection_id AND c.user_id = r.user_id
  JOIN users u ON u.group_id = r.to_id
  WHERE r.type = 2 AND r.rule BETWEEN 1 AND 3 AND u.id <> c.user_id
)
GROUP BY collection_id, user_id;
```

被丢弃的规则（写进 dry-run 报告）：

```sql
SELECT r.* FROM address_book_collection_rules r
LEFT JOIN address_book_collections c ON c.id = r.collection_id
WHERE c.id IS NULL OR c.user_id <> r.user_id OR r.rule NOT BETWEEN 1 AND 3
   OR (r.type = 1 AND NOT EXISTS (SELECT 1 FROM users WHERE id = r.to_id))
   OR r.type NOT IN (1, 2);
```

**撞名检查**：客户端按名字给地址簿建 map，`/api/ab/shared/profiles` 里同名的后一条覆盖前一条，名字恰好是 `My address book` 的共享簿还会顶掉个人簿（个人簿在客户端的固定键就是这个字符串）【读码】客户端 `ab_model.dart` 常量 `_personalAddressBookName = "My address book"`、`_legacyAddressBookName = "Legacy address book"`、`_getSharedAbProfiles`（`indexWhere((e) => e.name == u.name)` 后覆盖）、`_pullAb`（`addressbooks[p.name] = ...`）。对每个用户算出他能看到的簿（自己的 + 被授权的），名字重复或等于这两个保留名的，导入时改名（如追加 `（主人用户名）`）并记日志。这在 rustdesk-api 下已经存在（被覆盖的那本在客户端里看不见），改名后会"冒出来"。

### 8.4 条目

个人簿：

```sql
SELECT a.row_id, a.user_id, a.id AS peer_id,
       a.username, a.hostname, a.platform, a.alias,
       CAST(a.tags AS TEXT) AS tags_json,      -- 必须 CAST：部分行是 BLOB
       a.hash, a.password,
       CAST(a.force_always_relay AS INTEGER) AS force_always_relay,
       a.rdp_port, a.rdp_username, a.login_name
FROM address_books a
JOIN users u ON u.id = a.user_id
WHERE a.collection_id = 0
  AND a.id <> ''
  AND a.row_id IN (SELECT MIN(row_id) FROM address_books GROUP BY user_id, collection_id, id)
ORDER BY a.user_id, a.row_id;
```

共享簿：

```sql
SELECT a.row_id, a.collection_id, a.id AS peer_id,
       a.username, a.hostname, a.platform, a.alias,
       CAST(a.tags AS TEXT) AS tags_json,
       a.hash, a.password,
       CAST(a.force_always_relay AS INTEGER) AS force_always_relay,
       a.rdp_port, a.rdp_username, a.login_name
FROM address_books a
JOIN address_book_collections c ON c.id = a.collection_id AND c.user_id = a.user_id
JOIN users u ON u.id = c.user_id
WHERE a.collection_id > 0
  AND a.id <> ''
  AND a.row_id IN (SELECT MIN(row_id) FROM address_books GROUP BY user_id, collection_id, id)
ORDER BY a.collection_id, a.row_id;
```

重复和孤儿报告：

```sql
SELECT user_id, collection_id, id, COUNT(*) FROM address_books
GROUP BY user_id, collection_id, id HAVING COUNT(*) > 1;

SELECT a.row_id, a.user_id, a.collection_id, a.id FROM address_books a
LEFT JOIN address_book_collections c ON c.id = a.collection_id
LEFT JOIN users u ON u.id = a.user_id
WHERE u.id IS NULL OR (a.collection_id > 0 AND (c.id IS NULL OR c.user_id <> a.user_id));
```

`tags_json` 解析（Rust 侧）：`serde_json::from_str::<serde_json::Value>`，是数组就取其中的字符串元素，否则（`null`、空串、非法 JSON、非数组）当空数组。

### 8.5 标签

```sql
SELECT t.id, t.user_id, t.collection_id, t.name, t.color
FROM tags t
JOIN users u ON u.id = t.user_id
LEFT JOIN address_book_collections c ON c.id = t.collection_id
WHERE (t.collection_id = 0 OR (c.id IS NOT NULL AND c.user_id = t.user_id))
  AND t.name <> ''
  AND t.id IN (SELECT MIN(id) FROM tags GROUP BY user_id, collection_id, name)
ORDER BY t.user_id, t.collection_id, t.name;
```

### 8.6 （可选）用户组和设备

```sql
SELECT id, name, type FROM groups;                                  -- type: 1 默认 / 2 共享
SELECT p.id AS peer_id, p.uuid, p.user_id, p.hostname, p.os, p.username, p.version,
       p.alias, p.group_id, p.last_online_time, p.last_online_ip
FROM peers p
WHERE p.row_id IN (SELECT MIN(row_id) FROM peers GROUP BY id);
SELECT id, name FROM device_groups;
```

## 9. 意外 / 风险（影响实现方案）

1. **个人簿的 `hash` 等同明文密码**：它是 `base64(sha256(明文 + 对端 salt))`，客户端直接当预哈希密码登录对端（pass-the-hash）。架构 §3.6 只写了"共享簿明文密码加密落盘、个人簿哈希原样搬"，建议个人簿 hash 也加密落盘。
2. **`address_books.tags` 一列里 TEXT 和 BLOB 混存**（实测）：sqlx/rusqlite 按 `String` 直接取 BLOB 行会类型错误，SELECT 里必须 `CAST(tags AS TEXT)`；还会遇到字符串 `null`。
3. **组规则是动态的**：rustdesk-api 按访问时的 `users.group_id` 算权限。Porta 第一期若没有用户组，只能按导入时的成员快照展开；要不要在 Porta 里保留"组"概念，需要主会话定。`groups.type` 还决定组面板的可见范围（§4.4）。
4. **共享簿撞名**：客户端按名字区分地址簿，同名共享簿会互相覆盖，叫 `My address book` 的会顶掉个人簿。Porta 的接口层和导入器都要保证每个用户看到的簿名唯一。
5. **兼容接口要修 rustdesk-api 的两处键名错误**：`forceAlwaysRelay` 客户端按字符串 `"true"` 解析（rustdesk-api 回布尔，恒为 false）；`same_server` 键名带下划线（rustdesk-api 用 `sameServer`，恒失效）。`note` 在 rustdesk-api 里根本不存，Porta 要新增这一列。
6. **只靠 OAuth/LDAP 登录的用户 `password` 为空**，迁过去无法登录，需要命令行重设密码。
7. **切换后所有设备都要重新登录**（token 不迁，401 触发客户端清登录态和地址簿缓存）。
8. **逻辑键都没有唯一索引**，可能有重复行；rustdesk-api 的改、删作用在主键最小的那条，导入保留 `MIN(row_id)`/`MIN(id)`。
9. 现网是否真是 SQLite、版本是否 265 没核实，导入器先做预检。
