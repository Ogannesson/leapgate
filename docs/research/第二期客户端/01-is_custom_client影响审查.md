# 01 · 改名后 `is_custom_client()` 变真的影响审查

> Porta 是当时的工作名，2026-10-24 改名为 Leapgate（跃门）。

- 查证日期：2026-10-22
- 代码基线：`porta-client@dbf3af625`，和 `rustdesk@bd92623` 只差 `.gitmodules` 一行，下文统一写 `rustdesk@bd92623:路径`；`libs/hbb_common` 在 `5d52530`。
- 标注：【读码】附文件和函数；【一手来源】附 URL；【推测】是没跑过、只按代码推的结论。
- 对应方案：`docs/architecture.md` §3.3（改动纪律）、§3.10（品牌）、§3.11（更新相关的那句）、§5 第二期。

## 结论先说

1. **改名后哪些东西会变**。`is_custom_client()` 只做一件事：判断 `APP_NAME != "RustDesk"`。改名后它必然为真，没有其他条件能把它改回假。上游本来用它识别"官方客户端生成器做出来的定制客户端"，Porta 改名后会被当成这种客户端。
2. **实际调用点比方案里的数多**。Rust 侧有 15 个调用表达式，其中真正改变行为的 12 个，在 Windows 上生效的 10 个。Dart 侧直接调用 10 处；另外通过 7 个 `defaultOption*` 默认值函数间接影响 27 处。Sciter 旧界面有 23 行，但 Porta 不编 Sciter，可以不管。方案里"22 处 Dart、19 处 Rust"大概是按"字面含有 `isCustomClient` / `is_custom_client` 的行"数的，没算上 `defaultOption*` 那 27 处间接使用（见 §2.3）。
3. **绝大部分影响是好的或者无所谓**。跳过官方的"检查更新"、隐藏更新提示卡片和"启动时检查更新"开关，都是好事。`defaultOption*` 只改变"选项写进配置文件时存成什么值"，Porta 没有 `custom.txt` 默认值，所以运行时的语义不变。
4. **两处要处理**：
   - **【风险，需改】Windows 上的"自动更新"没有被跳过**。安装版 Porta 的服务进程里，只要 `allow-auto-update=Y`（默认关；设置页里这个勾选框对定制客户端仍然显示），就会去请求 RustDesk 官方的版本接口，下载**原版 RustDesk** 安装包，再用 `--update` 运行它。上游这样设计，是为了让定制客户端在"原版 exe + `custom.txt`"的模式下升级（rustdesk PR #13687，1.4.6 起）。Porta 不走 `custom.txt`，套不上这个模式。所以方案 §3.11 里"改名后不会去 RustDesk 官方拉取新版本"这句只对了一半：它只对"启动时检查更新"成立，对后台自动更新不成立。
   - **【品牌，需改】主界面左栏会多出一行"Powered by RustDesk"**，点击打开 rustdesk.com。这条和 AGENTS.md 里"Porta 构建中不出现 RustDesk 名字"的约定冲突。不用改 `flutter/`，把内置选项 `hide-powered-by-me` 设成 `Y` 就能隐藏。
5. **建议的最少改动**一共三处，都不碰 `flutter/`：
   - 在 `porta-cardo` 里改 `APP_NAME`/`ORG` 的默认值时，顺手预置 `hide-powered-by-me=Y`；
   - 在 `src/updater.rs` 的 `check_update` 开头加一行挂钩，关掉官方自动更新；
   - 可选：在 `load_custom_client` 加一行挂钩，不再读 `custom.txt`。

---

## 1. 判定逻辑

### 1.1 `is_custom_client()` 怎么判定
- 【读码】`rustdesk@bd92623:src/common.rs` `fn is_custom_client`：`get_app_name() != "RustDesk"`，没有其他条件。同文件的 `fn is_rustdesk` 判断的是 `APP_NAME == "RustDesk"`，正好和它相反。
- 【读码】`APP_NAME` 定义在 `libs/hbb_common/src/config.rs` 的 `lazy_static`，初值是 `"RustDesk"`。整个客户端只有一处会改写它：`src/common.rs` `fn read_custom_client`，读到经过 RustDesk 官方私钥签名的 `custom.txt` 后，用其中的 `app-name` 覆盖。
- 所以 Porta 只要改名，不管是在 `porta-cardo` 里改初值，还是启动时由挂钩写入，`is_custom_client()` 都恒为真。【读码】
- 【读码】服务端不受影响：`upstream/rustdesk-server/src` 里搜不到 `APP_NAME` 或 `get_app_name`。`porta-cardo` 里改 `APP_NAME` 默认值不会影响 `porta-server`。

### 1.2 Dart 侧的对应物
- 【读码】`src/flutter_ffi.rs` `fn is_custom_client` 原样转发给 Dart，生成 `bind.isCustomClient()`。
- 【读码】`flutter/lib/common.dart` 有带缓存的 getter `isCustomClient`，以及 7 个由它派生的默认值：`defaultOptionLang`（`'default'`）、`defaultOptionTheme`（`'system'`）、`defaultOptionYes`（`'Y'`）、`defaultOptionNo`（`'N'`）、`defaultOptionWhitelist`（`','`）、`defaultOptionAccessMode`（`'custom'`）、`defaultOptionApproveMode`（`'password-click'`）。非定制客户端时这 7 个都是 `''`。
- 【读码】`flutter/lib/web/bridge.dart` `isCustomClient` 是 Web 版的实现，Porta 不做 Web，可以忽略。
- 【读码】Sciter：`src/ui.rs` 有包装函数 `is_custom_client`，`src/ui/index.tis` 里有同名常量和 5 个 `default_option_*`。`src/lib.rs` 里 `mod ui` 只在没有 `flutter` feature 时编译，Porta 用 Flutter 构建，这部分不进产物。

### 1.3 `defaultOption*` 为什么存在
- 【读码】`libs/hbb_common/src/config.rs` `fn is_option_can_save`：如果某个值等于 `custom.txt` 下发的默认值（`DEFAULT_SETTINGS`），就不落盘；如果这个键在覆盖设置（`OVERWRITE_SETTINGS`）里，也不落盘。
- 【推测】定制客户端可能用 `custom.txt` 把某项默认值改成 `N`。这时用户打开开关，如果存成 `''`，会退回到默认值 `N`，所以要显式存 `'Y'`。这 7 个默认值就是为这种情况准备的。
- 【读码】Porta 没有 `custom.txt`，`DEFAULT_SETTINGS` 是空的。这时存 `'Y'` 和存 `''`、存 `','` 和存 `''`，Rust 侧读到的语义都一样，逐项核对见 §2.3。唯一的差别是配置文件里多了几个显式写出的键。
- 【读码】服务端通过心跳下发的策略（`src/hbbs_http/sync.rs` `fn handle_config_options`）直接覆盖本地选项，不受"本地是否显式存值"影响。以后 porta-server 用心跳策略控制选项（例如方案 §3.8 的 IPv6 打洞），不会被这点挡住。

---

## 2. 逐条审查

评价：**好** = 对 Porta 有利；**无所谓** = 语义不变，或 Porta 走不到这条路径；**坏** = 需要处理。
建议：**保留** = 不动；**挂钩** = 按 §3.3 加一行挂钩改回；**无所谓** = 不用管。

### 2.1 Rust（15 个调用表达式）

| # | 位置（`rustdesk@bd92623:`） | 平台 | 改名后的行为变化 | 评价 | 建议 |
|---|---|---|---|---|---|
| R1 | `src/common.rs` `fn check_software_update` | 全部 | 直接 return，不再在启动时请求 `api.rustdesk.com` 查新版，也就不再弹更新提示。Flutter 的 `main_get_software_update_url` 和 Sciter 的启动流程都走这里 | 好 | 保留 |
| R2 | `src/common.rs` `fn verify_login` | 全部 | 调用在注释块里，函数恒返回 `true` | 无所谓（死代码） | 无所谓 |
| R3 | `src/flutter_ffi.rs` `fn is_custom_client` | 全部 | FFI 转发给 Dart，影响见 §2.2 | — | — |
| R4 | `src/flutter_ffi.rs` `fn verified_update_artifact_for_release_page_url` | Windows | MSI 安装的定制客户端改为下载 exe 格式的更新包。只有点了更新卡片才会走到这里，而卡片对定制客户端是隐藏的（D4） | 无所谓（界面上走不到） | 无所谓 |
| R5 | `src/ipc.rs` 配置查询里的 `"hide_cm"` 分支 | 桌面 | 原来只有 `is_pro()` 为真时才返回 `hide_cm()` 的结果，现在定制客户端也返回。三个条件同时满足时，被控端连接管理窗口（CM）会隐藏：`approve-mode=password`、只用固定密码、`allow-hide-cm=Y`。设置页里那个勾选框在上游已经注释掉了（`desktop_setting_page.dart` 里的 `hide_cm(` 调用），只能通过配置或服务端策略设置 | 无所谓：`is_pro()` 在 API 服务器接受 sysinfo 上报后就为真（`src/hbbs_http/sync.rs`），porta-server 实现 sysinfo 后本来就会走这条分支。但"静默隐藏 CM"是一项隐私敏感能力，见 §5 问题 3 | 保留 |
| R6 | `src/manual_update.rs` `fn installed_update_package_id` | macOS | 更新包 ID 改用自己的 bundle ID | 无所谓（第一阶段不做 macOS） | 无所谓 |
| R7 | `src/platform/windows.rs` `fn remove_meta_toml_cmd` | Windows | MSI 安装 + 定制客户端时，`update_me` 会删除安装目录里的 `meta.toml`（便携版启动器的元数据） | 无所谓（Porta 前两期不出 MSI） | 无所谓 |
| R8 | `src/platform/windows.rs` `fn prepare_custom_client_update` | Windows | `--update` 时，暂存目录里如果有 `custom.txt`，会读取它，然后用"`is_custom_client()` 是否变真"判断它是否有效。Porta 本来就是真，这个有效性检查就失效了 | 无所谓：Porta 不产生暂存的 `custom.txt` | 无所谓 |
| R9 | `src/platform/windows.rs` `fn get_custom_icon` | Windows | 快捷方式、卸载项的 `DisplayIcon` 优先用 exe 同目录下的 `data\flutter_assets\assets\icon.ico`。上游的 `flutter/assets/` 里没有 `icon.ico`，这个文件不存在时回落到 exe 自带的图标 | 无所谓；换图标时只要改 exe 资源（`flutter/windows/runner/resources/app_icon.ico`）就够了 | 无所谓 |
| R10 | `src/platform/windows.rs` `fn get_reg_msi_key` | Windows | 只在 MSI 安装时去找 MSI 卸载项并同步版本号 | 无所谓（不出 MSI） | 无所谓 |
| R11 | `src/platform/windows/verified_update.rs`（手动更新入口） | Windows | 更新前把当前 exe 旁边的 `custom.txt` 复制到暂存目录（Porta 没有这个文件，只会清一下暂存目录） | 无所谓（界面上走不到） | 无所谓 |
| R12 | `src/updater.rs` `fn check_update`（`update_msi` 那一行） | Windows | MSI 安装的定制客户端用 exe 格式更新 | 见 R13 | 见 R13 |
| R13 | `src/updater.rs` `fn update_new_version` | Windows | 自动更新下载完以后，定制客户端会先处理 `custom.txt` 暂存目录，再以特权身份运行下载来的安装包（`--update`）。**真正的问题不在这一行，而在于 `check_update` 整条路径没有被 `is_custom_client()` 拦住**，见 §3 | **坏** | **挂钩**（§4 H2） |
| R14 | `src/updater.rs` `fn check_update_as_root` | macOS | 定制客户端跳过官方自动更新 | 无所谓（第一阶段不做 macOS） | 无所谓 |
| R15 | `src/ui.rs` `fn is_custom_client`（Sciter 包装） | — | 不编译进 Porta | 无所谓 | 无所谓 |

相关但不是 `is_custom_client` 的一处：
- 【读码】`src/lang.rs` `fn translate_locale` 用 `!is_rustdesk()` 决定是否把译文里的 "RustDesk" 换成应用名，但跳过 `powered_by_me` 和 `upgrade_rustdesk_server_pro*` 两类词条。所以 D3 那行字改名后仍然写着 "Powered by RustDesk"（英文）和"由 RustDesk 提供支持"（简体中文）。这是好事，方案 §3.10 依赖的就是这个替换。

### 2.2 Dart：直接调用 `bind.isCustomClient()`（10 处）

| # | 位置（`flutter/lib/`） | 平台 | 改名后的行为变化 | 评价 | 建议 |
|---|---|---|---|---|---|
| D1 | `common.dart` getter `isCustomClient` | 全部 | 缓存结果，供 7 个 `defaultOption*` 使用，见 §2.3 | — | — |
| D2 | `common.dart` `checkUpdate()` | 全部 | 不再注册"检查更新完成"的事件处理，也不再调用 `mainGetSoftwareUpdateUrl` | 好 | 保留 |
| D3 | `desktop/pages/desktop_home_page.dart` `buildLeftPane` | 桌面 | 左栏 logo 上方多出一行"Powered by RustDesk"（`loadPowered`），点击打开 rustdesk.com；内置选项 `hide-powered-by-me=Y` 时隐藏 | **坏**（品牌） | 不改 `flutter/`，预置内置选项（§4 H1） |
| D4 | `desktop/pages/desktop_home_page.dart` `buildHelpCards` | 桌面 | 不显示"有新版本"卡片（这里还有第二道判断：URI 前缀要包含 `rustdesk`） | 好 | 保留 |
| D5 | `desktop/pages/desktop_setting_page.dart` `other()` 里的 `showAutoUpdate` | macOS | 只在 macOS 分支隐藏"自动更新"；**Windows 安装版照样显示"Auto update"勾选框** | Windows 上是坏事（会引出 §3 的问题） | 靠 §4 H2 让勾选框不起作用；不改 `flutter/`（见 §5 问题 1） |
| D6 | `desktop/pages/desktop_setting_page.dart` `other()` | 桌面 | 隐藏"启动时检查更新"开关 | 好 | 保留 |
| D7 | `mobile/pages/connection_page.dart` | 移动端 | 隐藏更新提示 | 无所谓（不做移动端） | 无所谓 |
| D8 | `mobile/pages/server_page.dart` `ScamWarningDialogState` | Android | 防诈骗警告的 12 秒倒计时变成 0 秒 | 无所谓（不做 Android）。以后做 Android 被控端时这算坏事，到时候要改回 | 以后做 Android 时用挂钩改回 |
| D9 | `mobile/pages/settings_page.dart` `build` | 移动端 | 设置页显示"Powered by" | 无所谓（同样受 H1 控制） | 无所谓 |
| D10 | `mobile/pages/settings_page.dart` `enhancementsTiles` | 移动端 | 隐藏"启动时检查更新" | 无所谓 | 无所谓 |

### 2.3 Dart：通过 `defaultOption*` 间接影响（27 处）

改名后，这些地方在"恢复默认"时写入的是显式值，不再是 `''`。下面逐项核对 Rust 侧怎么读这些值：

| 默认值 | 使用处（`flutter/lib/`） | 次数 | Rust 侧怎么读 | 结论 |
|---|---|---|---|---|
| `defaultOptionYes`（`'Y'`） | `common.dart` `bool2option`；`models/server_model.dart`（音频、文件、剪贴板等 4 处） | 5 | `enable-*` 一类按 `value != "N"` 判断（`config.rs` `fn option2bool`），`'Y'` 和 `''` 都是真 | 无所谓 |
| `defaultOptionNo`（`'N'`） | `common.dart` `bool2option`；`address_book.dart` ×2；`peer_tab_page.dart`；`models/ab_model.dart`；`desktop_setting_page.dart`（`_OptionCheckBox` 附近）；`mobile/pages/settings_page.dart` ×2 | 8 | `allow-*`、`stop-service` 等按 `value == "Y"` 判断，`'N'` 和 `''` 都是假；地址簿相关的几个是界面本地选项，Dart 自己判断 `== 'Y'` | 无所谓 |
| `defaultOptionWhitelist`（`','`） | `common/widgets/dialog.dart` ×6 | 6 | `src/server/connection.rs` `fn check_whitelist`、`fn check_id_whitelist` 按 `,` 切分后过滤空串，`','` 等于空名单，放行所有人；Dart 的 `whitelistNotEmpty` 也认 `','` | 无所谓 |
| `defaultOptionAccessMode`（`'custom'`） | `desktop_setting_page.dart` `permissions` | 1 | `connection.rs` `fn is_permission_enabled_locally` 只认 `full`/`view`，其他值都按逐项权限处理。下拉框找不到初始值时回落到第 0 项（`common.dart` `ComboBox`），显示正常 | 无所谓 |
| `defaultOptionApproveMode`（`'password-click'`） | `desktop_setting_page.dart` ×2；`mobile/pages/server_page.dart` | 3 | `hbb_common/src/password_security.rs` `fn approve_mode` 只认 `password`/`click`，其他值都是 `Both` | 无所谓 |
| `defaultOptionLang`（`'default'`） | `desktop_setting_page.dart` `language` ×2；`mobile/pages/settings_page.dart` | 3 | `config.rs` `LocalConfig::set_option` 专门处理 `"default"`，存成 `""`，等于跟随系统 | 无所谓 |
| `defaultOptionTheme`（`'system'`） | `common.dart` `changeDarkMode` | 1 | Dart `themeModeFromString`：除 `light`/`dark` 外都是跟随系统 | 无所谓 |

合计 27 处。【读码】结论：在没有 `custom.txt` 的前提下，这 27 处语义都不变。

### 2.4 Sciter 旧界面（`src/ui/index.tis`，23 行）
- 【读码】包括 `is_custom_client` 常量、5 个 `default_option_*` 及其使用、"Powered by"行、更新提示里的另一套文案。
- 不编译进 Porta（§1.2），方案 §3.4 也已经决定不保留 Sciter。结论：**无所谓**。

---

## 3. 主要风险：Windows 自动更新会去拉原版 RustDesk

### 3.1 代码路径
- 【读码】`src/rendezvous_mediator.rs` `fn start_all`：Windows 上如果已安装，并且当前是服务进程，就调用 `updater::start_auto_update()`。这里没有判断 `is_custom_client()`。
- 【读码】`src/updater.rs` 的定时线程启动后先等一段时间检查一次，之后每天一次，调用 `fn check_update(false)`。`check_update` 只看 `allow-auto-update`（`allow-` 前缀，默认 `N`），然后**直接调用 `do_check_software_update()`**。这条路径不经过 R1 的 `check_software_update`，所以 R1 那个"跳过"对它不起作用。
- 【读码】`libs/hbb_common/src/lib.rs` `fn version_check_request`：把 `os`、`os_version`、`arch`、设备指纹（`device_id`）POST 到写死的 `https://api.rustdesk.com/version/latest`。
- 【读码】`src/common.rs` `fn release_id_from_update_url`、`src/updater/artifact.rs`：只接受 `github.com/rustdesk/rustdesk` 的 release，下载原版安装包并校验 SHA-256。然后 `fn update_new_version` 以特权身份运行 `"<下载的原版 exe>" --update`。
- 【一手来源】上游有意这样设计，让 Windows 定制客户端从官方 release 自动升级，`custom.txt` 通过暂存目录带过去：
  - rustdesk PR #13687，https://github.com/rustdesk/rustdesk/pull/13687 ；
  - 高级设置文档 `allow-auto-update` 条目（只在 Windows 上生效，默认 `N`，1.4.6 起），https://rustdesk.com/docs/en/self-host/client-configuration/advanced-settings/ （2026-10-22 查证）。

### 3.2 对 Porta 的后果
- 前提：`allow-auto-update=Y`。这个值可以由用户在设置页勾选（D5，Windows 安装版仍然显示），也可以由服务端心跳策略下发（`handle_config_options` 接受任意键）。
- 【读码】Porta 的设备指纹和系统版本每天发给 RustDesk 官方一次。
- 【推测】下载回来的原版 exe 没有 `custom.txt`，以 `APP_NAME=RustDesk` 运行 `--update`，进入 `fn update_me`，按 RustDesk 的安装路径查找：
  - 机器上没装原版：报 "RustDesk is not installed"，更新失败，可能每天弹一次"Update failed!"通知；
  - 机器上装了原版（第二期验收要求两者共存）：**由 Porta 的服务去升级原版 RustDesk**。
  - 两种情况下 Porta 自己都不会被替换。但每天会白白下载一个几十 MB 的安装包，还有一个特权进程在跑。
- 【推测】暂存目录写死在 `C:\ProgramData\RustDesk\RustDeskCustomClientStaging`（`windows.rs` `fn get_custom_client_staging_dir`），Porta 和原版共用这个路径；上游的删除函数是故意做成什么都不删的。Porta 不产生 `custom.txt`，眼下没有冲突。
- 结论：**必须关掉**。方案 §3.11 那句也要改：启动时检查更新会跳过，但 Windows 后台自动更新（需要用户开启）不会跳过。

---

## 4. 最少改动方案（按 §3.3 纪律）

原则：
- `flutter/` 一行不动；
- 上游代码不删，只加一行调用 `porta::…` 的挂钩；
- 品牌集中在一处配置。

| 编号 | 改哪里 | 改什么 | 解决 | 冲突面 |
|---|---|---|---|---|
| H0 | `porta-cardo`：`libs/hbb_common/src/config.rs` | `APP_NAME`、`ORG` 的初值改成 Porta 的值（§3.10 本来就要改） | 改名本身 | 两行。改初值而不是启动时写入，是因为客户端有好几个入口（`core_main.rs`、`service.rs`、`flutter_ffi.rs` 的 `initialize`），改初值能保证每个入口一开始就是 Porta |
| H1 | 和 H0 同一处（或 `libs/porta` 的品牌常量） | `BUILTIN_SETTINGS` 的初值预置 `hide-powered-by-me=Y`；如果不想动 lazy_static 的初值，就在 H0 同一处加一个 `porta_brand_defaults()`，由各入口在 `load_custom_client()` 之后调用 | D3、D9 | `porta-cardo` 里几行，或者在 3 个入口各加一行挂钩。推荐写进 `porta-cardo`，因为 `BUILTIN_SETTINGS` 本来就在那里 |
| H2 | `src/updater.rs` `fn check_update` 开头 | `if porta::update::official_auto_update_disabled() { return Ok(()); }`，Porta 里恒为真 | §3、R12、R13、D5（勾选框还在，但不再起作用） | 一行。`updater.rs` 不在 §3.3 的热点列表里，上游改它的频率【推测】中等 |
| H3（可选） | `src/common.rs` `fn load_custom_client` 开头 | `if porta::brand::ignore_custom_txt() { return; }` | §3.10 已经定了不用 `custom.txt`，但现在的代码仍然会读 exe 旁边的 `custom.txt`。只要是有效的 RustDesk 官方签名文件，就能覆盖 `APP_NAME`、默认设置和硬设置。安装目录要管理员权限才能写，便携版就是用户目录【推测：风险低】 | 热点文件里一行 |

不需要改的：R1、D2、D4、D6（好事，保留），以及 §2.3 那 27 处、R4 到 R11、R14、R15、移动端、Sciter（无所谓）。

**不推荐的做法**：
- 让 `is_custom_client()` 在 Porta 里返回假，或者绕开判断保持 `APP_NAME=RustDesk`。这样会把 R1、D2、D4、D6 这些好处一起丢掉，重新弹出指向 rustdesk.com 的更新提示；保持 `APP_NAME=RustDesk` 还会破坏 §3.10 依赖的"服务名、注册表、配置目录分开"。
- 逐处挂钩改写 `defaultOption*`：没有收益。

**验证项（写进第二期冒烟清单）**：
- 主界面没有"Powered by"；
- Windows 安装版勾选"Auto update"后看服务日志，没有访问 `api.rustdesk.com`（日志里不出现 "New version available"）；
- 和原版共存时，原版不会被 Porta 的服务改动；
- 对 §2.3 里的几个选项各点一次"恢复默认"，配置文件里出现显式的 `Y`、`,` 等值，连接行为不变。

---

## 5. 需要维护者拍板

1. **"Auto update"勾选框留不留**：
   - H2 之后它就不起作用了。真要隐藏它，得改 `flutter/lib/desktop/pages/desktop_setting_page.dart`，超出 §3.3 过渡期例外允许的范围（例外只放行 exe 名、图标、包 ID）。
   - 建议：过渡期留着这个不起作用的勾选框，新界面里不再做。另一个办法是让 H2 在 `allow-auto-update=Y` 时写一条日志说明。
2. **"Powered by RustDesk"去掉之后，要不要在别处注明来源**：
   - AGPL 没有要求界面上显示，但关于页或 README 写一句"基于 RustDesk"有助于和官方版区分。
   - 这和 AGENTS.md"构建中不出现 RustDesk 名字"的约定有张力，要定一下：关于页里允许出现一句文字说明，还是完全不出现。
3. **要不要允许"静默隐藏连接管理窗口"（R5）**：
   - 改名后，以及接上实现了 sysinfo 的 porta-server 后，服务端策略下发 `allow-hide-cm=Y` 就能让被控端在有人连入时不弹窗。
   - 对自己的无人值守设备有用；对朋友的设备是隐私风险。
   - 可选做法：现在保持上游行为；或者在 porta-server 里不允许下发这个键；或者在客户端加挂钩固定返回 `None`。
4. **H3 做不做**：成本是热点文件 `src/common.rs` 里多一行。建议做，和 §3.10"不用 `custom.txt`"的决定保持一致。

## 6. 本次没有覆盖的品牌残留

这些和 `is_custom_client` 无关，只列出来，留给"改名、换图标"那项任务：
- `src/auth_2fa.rs` 的 `ISSUER`：验证器 App 里会显示 RustDesk；
- `flutter/lib/desktop/widgets/tabbar_widget.dart` 写死的标题 "RustDesk"；
- `libs/portable/src/main.rs` 的 `APP_PREFIX = "rustdesk"` 和环境变量名 `RUSTDESK_APPNAME`；
- `src/platform/windows.rs` 暂存目录名里的 `RustDesk`；
- `loadPowered` 的跳转链接。
