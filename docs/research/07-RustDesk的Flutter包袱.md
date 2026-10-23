# 07 RustDesk 在 Flutter 上的经历和包袱

> Porta 是当时的工作名，2026-10-24 改名为 Leapgate（跃门）。

查证日期 2026-10-22。上游客户端 `rustdesk@bd92623`。不重复 01（引擎与 UI 边界）、05（构建链）里已有的内容，需要时只引用。

标注口径：
- 「读码确认」：本地仓库或 GitHub API 直接读到的代码、CI、提交记录。
- 「一手来源」：RustDesk 维护者（账号 `rustdesk` / `open-trade` 是作者本人，`21pages`、`fufesou`、`Kingtous` 是核心开发者）本人写的博客、评论、PR 说明，或 Flutter 官方文档/博客。
- 「旁证」：用户、第三方的说法。
- 「推测」：我自己的判断。

检索过程中没有遇到要求执行命令或外发数据的网页内容。rustdesk/engine 的构建 workflow 里有从外部下载补丁的步骤，那是它自己的 CI 逻辑，只读了没执行。

---

## 1. 为什么从 Sciter 换到 Flutter（2022）

时间线：
- 2021-06：作者开 issue #103「Rewrite Desktop UI with Flutter」，目标是"移动端和桌面端统一同一套 UI 框架"；并说当初选 Sciter 是因为"去年 Flutter 桌面还不成熟"。https://github.com/rustdesk/rustdesk/issues/103 「一手来源」
- 2022-05-16：发起讨论 #533「Tauri or Flutter」。作者自己列出 Flutter 的缺点：Rust 调试不方便；Flutter 代码库太大，"Tauri 我们改得动，Flutter 很难改"。 https://github.com/rustdesk/rustdesk/discussions/533 「一手来源」
- 2022-05-23：作者在同一讨论里说 Tauri 的 IPC 太差，对 RustDesk 是致命的（远程画面要大量传帧）。中文社区同日公告：Tauri 放弃了共享内存支持、IPC 性能差，所以暂时放弃 Tauri，启动 Flutter 迁移。https://rustcc.cn/article?id=de670ed2-8da9-4d77-b48c-c45752d755a6 「一手来源」
- 2022-05-22：作者在 #103 里说"不再信任 Sciter，用了快两年很痛苦，该换开源方案了"。「一手来源」
- 2022-08-26：官方博客，flutter_desktop 分支合入 master。理由：Sciter 轻量但不开源，Sciter 作者的开源众筹失败；Flutter 不支持 32 位 Windows，所以 Sciter 继续服务 32 位版。https://dev.to/rustdesk/rustdesk-is-migrated-from-sciter-to-flutter-279m 「一手来源」
- 2022-09-20：官方博客《Flutter Desktop Development Practice》。https://dev.to/rustdesk/flutter-desktop-development-practice-4c7a 「一手来源」，要点：
  - 承认迁移比预期慢很多，"选 Flutter 好像是错的，但确实没有更好的选择"。
  - Tauri 性能达不到要求（受浏览器边界限制）；Qt 因为 Rust 绑定是 unsafe 的而放弃。
  - Flutter 写法接近原生 UI 开发，比 Web 复杂，代码"冗长臃肿"，对小团队意义不大。
  - "Flutter 桌面仍然很多 bug，比预期糟得多"；Flutter 团队重心在 Android/iOS，桌面的基础问题（多级菜单、本地光标、滚动条）被忽视。
  - 列了 8 个他们自己绕过去的问题：多窗口（自写 `desktop_multi_window`，当时只支持 Flutter ≤3.0.5，所以钉旧版）、窗口操作（给 window_manager 提 PR）、原生光标（给 engine 提 PR + 自写 `flutter_custom_cursor`）、多级菜单（尽量不用）、滚动条（滚轮慢、自写 improved_scrolling）、bridge、Wayland（给 screen_retriever 提 PR）、CJK 字体。
- 迁移 wiki 定下的架构："TeamViewer 式标签窗口，每个窗口一个独立 Flutter engine"。https://github.com/rustdesk/rustdesk/wiki/RustDesk-Desktop-Flutter-Migration 「一手来源」

结论：选 Flutter 的决定性理由是"开源 + 移动端已经在用 + 帧数据能高效进 UI（外部纹理），Tauri 的 IPC 做不到"。不是因为 Flutter 桌面好用，维护者一开始就知道它在桌面上弱。

## 2. CI 给 Flutter 打的补丁和自编引擎

### 2.1 自编 x64 Windows 引擎（`rustdesk/engine`）「读码确认」
- 位置：`rustdesk@bd92623:.github/workflows/flutter-build.yml` 第 251~261 行，"Replace engine with rustdesk custom flutter engine"，下载 `github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip` 覆盖官方 `windows-x64-release` 引擎。只 x64 用，arm64 用官方引擎。
- 引擎仓库 `rustdesk/engine`（fork 自 flutter engine），构建脚本 `.github/workflows/flutter-engine-windows-x64-release-build.yml`，基于 Flutter 3.24.5 改了四处：
  1. `shell/platform/windows/flutter_windows_engine.cc` 里把 `ClearCurrent` 换成 `MakeCurrent`：对应 CI 注释里的 flutter/flutter#155685「Windows 多窗口，创建和关闭窗口时崩溃」。这个 issue 是 fufesou 2024-09 提的，2026-10-22 查仍是 open（P2）。https://github.com/flutter/flutter/issues/155685
  2. Dart VM `runtime/bin/platform_win.cc`：回退成 `gethostname`，修 RustDesk #10085（Win7 上启动报错）。
  3. 回退 Dart 的"移除 Windows 7 栈展开处理"。
  4. 回退 Dart `file_win.cc` 的一处改动（同样是 Win7 兼容）。
  - 另外 `fml/hex_codec.h` 补一个 `#include <string>`（编译修复）。
  - 补丁提交者是外部贡献者 vitoway，2024-11-07~12-01 共几次提交；之后再没更新（最后 push 2024-12-01）。「读码确认」（GitHub API）
- 提交说明：`b91b4922`（2024-11-29）"enable our engine to fix dart supporting win7, …#10085"；前一个 `32a3bcdc`（2024-11-24）"no custom engine" 曾短暂去掉。「读码确认」
- 维护者原话（#10085）：Win7 问题"是 Flutter 3.22 引入的，我们不能一直停在旧 Flutter 上"。https://github.com/rustdesk/rustdesk/issues/10085 「一手来源」
- 说明的问题：Flutter/Dart 官方已放弃 Win7；Flutter Windows 引擎在"多 engine 多窗口"用法下有未修的崩溃。前者是 RustDesk 的产品要求，后者是 Flutter 本身的缺陷，但只在"一窗一 engine"架构下触发。

### 2.2 DropdownMenu 补丁「读码确认」
- `rustdesk@bd92623:.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff`，改 Flutter SDK 的 `packages/flutter/lib/src/material/dropdown_menu.dart`：Material `DropdownMenu` 的 `enableFilter` 选完一项后不复位，下次打开只显示过滤后的条目。
- 引入提交 `a79a9f69`（2024-11-11，21pages）"fix 'Add to addresssBook' dropdown menu (#9878)"；用的地方只有 `flutter/lib/common/widgets/dialog.dart:2549`。
- 说明的问题：Material 组件的小 bug，他们选择改 SDK 而不是换组件。Porta 重写 UI 可以完全不碰。

### 2.3 macOS：注释掉 `_setFramesEnabledState(false)`「读码确认」
- `flutter-build.yml` 第 954~960 行，用 sed 改 Flutter SDK 的 `packages/flutter/lib/src/scheduler/binding.dart`，对应 flutter/flutter#133533：macOS 上新建窗口后切到别的 app 再回来，副窗口不响应。该 issue 2025-11 已关闭（fixed），但 3.24.5 里没有修复，所以 RustDesk 还要自己改 SDK。
- 说明的问题：Flutter 多窗口（多 engine）在 macOS 上的生命周期缺陷 + 钉旧版拿不到修复。

### 2.4 其他相关的 CI/运行时绕路「读码确认」
- Linux arm64 不用官方 Flutter，用 `flutter-elinux` 3.16.9（`FLUTTER_ELINUX_VERSION`），CJK 字体还要单独修（`c9391fb8`、PR #15324）。
- macOS 的注释：用户大量反馈闪屏，纹理渲染默认关（`flutter-build.yml` 第 868 行注释，#6296）。
- Win7 默认软件渲染：`773b9d66`（2024-12-02）"win7 vm 用纹理渲染时远程窗口黑屏"。
- Windows runner 自己补"白窗"：`9aeb54cf`（2026-07-30，PR #15717）在 `flutter/windows/runner/flutter_window.cpp` 加 109 行定时器，在首帧前窗口被 resize（PowerToys FancyZones）时踢引擎重绘。提交说明原话的意思："Sciter 不受影响，它在 WM_PAINT 里同步重绘；上游没修（flutter/flutter#159630，P3 open）"。#159630 2026-10-22 查仍 open。
- `rustdesk-org/rustdesk_desktop_multi_window` 2026-09 还在连续修 Windows 问题：FancyZones 白窗、子窗口可见性、启动刷新超时、resize 卡住（GitHub API 提交列表）。

## 3. 为什么一直钉在 Flutter 3.24.5

- 直接原因是 **Win7 支持**。「一手来源 + 读码确认」
  - CI 注释（`flutter-build.yml` 第 33~37 行）：除 Windows arm64 外，所有平台停在 3.24.5，"直到上游统一升级 Flutter 后恢复 Windows 7 支持"。
  - 21pages 在 PR #15139（2026-06-17）说：升到 3.44.1 后 Win7 兼容还没做，所以这一阶段只给 Windows ARM 升 Flutter。https://github.com/rustdesk/rustdesk/pull/15139
  - 自编引擎只针对 3.24 系列 x64（CI 注释原意："rustdesk/engine 的 zip 是按 3.24 时代 x64 引擎编的"），Dart VM 的 Win7 补丁要对新版重新做，而且新版 Dart 去掉的 Win7 代码更多。「推测」：这是升级的主要成本。
  - 同一套 Win7 约束也把 Rust 钉在 1.75（`28b376d2`，discussion #7503）。
- 外部贡献者提 PR #15141（2026-05，3.24.5→3.27.4），作者回复"没你想的那么简单""在计划内，我们自己做"，没合。https://github.com/rustdesk/rustdesk/pull/15141 「一手来源」
- 现在的状态是**两套 Flutter 并存**：x64/Android/Linux 用 3.24.5，Windows arm64 用 3.44.9（`2c84c8fb`），macOS 也有人提 PR 想单独升 3.44.8 修语义树崩溃（PR #15668，未合；对应 #16552：macOS 辅助功能检查一下就崩，Flutter 3.24.5 引擎里的断言，上游早已在 engine#54364 删掉）。为了让同一份源码在两个版本下都能编，CI 用 `.github/patches/apply_flutter_3.44_source_patches.sh` 临时改 `DialogTheme→DialogThemeData`、`TabBarTheme→TabBarThemeData`、`extended_text 14→15.0.2`、`google_fonts ^6→^8`。「读码确认」
- 历史上的钉版：2022 年因为多窗口插件只支持 ≤3.0.5 而钉（官方博客）；2023 年 Android 退回 3.13，因为"在我手机上视频超慢"（`ff2e055a5`）；2024-11 升 3.24.4 时 PR #9870 被回滚又重提（`912f5265`、`72a1f116`）。「读码确认」
- 维护者 2024-09 说过 Flutter 3.24 修了一些白窗问题（flutter/flutter#150546），所以才升到 3.24。https://github.com/rustdesk/rustdesk/issues/5108 「一手来源」

结论：钉版本是 **RustDesk 的产品决定（要 Win7）** 加 **每次升级都要重新验证多窗口/渲染路径** 共同造成的。Porta 不要 Win7，钉版本的主要理由不存在。

## 4. 用户集中抱怨的 Flutter 桌面问题

搜索方式：GitHub REST `search/issues`（含 issue 和 PR）和 GraphQL discussion 搜索，范围 `repo:rustdesk/rustdesk`，2026-10-22。仓库总量参照：issue 4470、PR 5724。注意 RustDesk 大量 issue 会被锁定或转成 discussion，计数只代表数量级。

### 4.1 白窗 / 空白窗 / 黑窗（最突出，Flutter 本身）
- 计数：`"white window" OR "blank window" OR "white screen"` 73 条；标题含 `black screen` 43 条；discussion 标题含 white 13 条。
- 代表：
  - #5108（119 条评论）Flutter 版启动即冻结/白屏，Intel HD 5000；作者回复"我们这边无能为力，只能等 Flutter 更新"，建议用 Sciter 版。https://github.com/rustdesk/rustdesk/issues/5108
  - #6756（49 条，open）PowerToys FancyZones 下全白，"flutter 不行，sciter 正常"。https://github.com/rustdesk/rustdesk/issues/6756
  - #80（56 条）、#418（54 条）早期 Windows 白屏（GPU 加速）。
  - discussion #11908：合盖时 GUI 全白；open-trade 回复"可能得去报给 Google Flutter，Notepad++ 能行因为它自己渲染，RustDesk 用的是 Flutter"。https://github.com/rustdesk/rustdesk/discussions/11908
- 作者 2023-07 在 HN 发帖《Flutter Desktop compatibility is getting worse?》：越来越多 `glGetString(GL_VERSION) failed`，新 Flutter 在 mac 虚拟机上完全不能跑；"迁移花了快一年，现在因为 Flutter 兼容性差不得不同时维护旧 SDK 和 Flutter"。https://news.ycombinator.com/item?id=36872677 「一手来源」
- 归属：**Flutter 本身**（引擎依赖 GPU/GL/ANGLE，老显卡、虚拟机、窗口管理工具会触发；resize 同步握手的缺陷）。部分由一窗一 engine 放大（每个窗口都走一次首帧握手）。

### 4.2 闪烁 / 撕裂
- 计数：标题含 flicker 13 条，全文 flickering 16 条，tearing 17 条（后者多是无关 PR）。
- 代表：#6296（28 条）mac 客户端闪屏，因此 mac 纹理渲染默认关；#8505 调整窗口大小时子画面闪；#3147 Linux 上 tooltip 引起设置项闪烁，作者回复"我认为不在我们控制内，是 Flutter 引擎问题，等 Flutter 更新"。https://github.com/rustdesk/rustdesk/issues/3147
- 归属：**混合**。远程画面闪烁多数出在 RustDesk 的视频上屏路径（外部纹理 vs 软解 `decodeImageFromPixels` 两条路径），属于 RustDesk 写法 + Flutter 外部纹理机制；UI 控件闪烁是 Flutter 本身。

### 4.3 内存
- 计数：标题含 memory 30 条，`"memory leak"` 40 条；discussion 标题含 memory 8 条。
- 代表：
  - #3141 M1 内存泄漏，标题里写着"改进 decodeImageFromPixels 性能，或用原生纹理渲染"。
  - #8883 Mac 播视频/游戏时内存涨满，打开纹理渲染就好；作者当天修了（`764fbe2`）。https://github.com/rustdesk/rustdesk/issues/8883
  - #5838 被控端约 1GB，作者解释是 4K 分辨率编码的正常占用（被控端进程，与 Flutter 无关）。
  - #14603 macOS 4 天泄漏 2.9GB；2026-09 还有 #16286、#16304"限制 Flutter 客户端光标缓存"。
- 多窗口多 engine 的内存：没有找到集中的用户抱怨，搜 `"flutter engine" memory`、`each window memory` 都只有零星无关结果。「读码确认 + 推测」：每个 engine 有自己的 Dart isolate 和 GPU 上下文，会多占几十 MB 级内存，但用户可感知的大头是视频帧缓冲。
- 归属：**主要是 RustDesk 写法**（软渲染路径每帧经过 Dart 解码、光标缓存不设上限、帧缓冲泄漏）。

### 4.4 输入法（IME）
- 计数：标题含 IME 10 条，`"input method"` 88 条，discussion 中 51 条。
- 代表：#7308（17 条）win→mac 微信输入法；#10116 翻译模式下中文输入法切换；#14667（open）越南语 EVKey 1.4.6 回退；2026 年连续多个 mobile IME 修复（#14981、#16336、#16528、#16632）。
- 归属：**绝大多数是 RustDesk 的键盘映射/转发逻辑**（远控软件要把本地按键翻成远端按键，这是引擎层的事），和 Flutter 关系不大。Flutter 相关的只有本地文本框里的 IME（中文输入框候选位置等），抱怨很少。

### 4.5 高 DPI / 缩放
- 计数：标题含 DPI 8 条、scaling 16 条；discussion DPI 15 条。
- 代表：#15592 / #15620（"跨 DPI 调整窗口大小"修了又回滚，2026-07）、#16357（KDE Wayland 分数缩放补偿窗口尺寸）、#9605（Win7 x64 DPI）、#6487 Wayland 分数缩放失真。
- 归属：**混合**。窗口尺寸跨 DPI 的问题来自 window_manager/multi_window 插件和 Flutter 嵌入层；画面缩放是 RustDesk 画布逻辑。

### 4.6 Linux Wayland
- 计数：标题含 wayland 227 条（第二多），discussion 193 条。
- 归属：**绝大多数不是 Flutter 的问题**，是被控端抓屏（portal/PipeWire、DRM/KMS）和输入注入（#15420、#14384、#9019）。和 Flutter 有关的少数：#16297 KDE Wayland 下 `--cm` 窗口在初始化 RGBA 纹理时崩溃（GL 上下文）；#3343 Linux 开纹理渲染崩溃，fufesou 认为是"Flutter 纹理和多窗口管理器的问题"；runner 里自写 `wayland_shortcuts_inhibit.cc`（244 行）拦系统快捷键。

### 4.7 启动速度、包体积
- 启动慢：标题搜 `slow startup` 只有 1 条（#4352，KDE Wayland）。不是集中抱怨。
- 包体积：1.5.0（2026-09-30）发布件：x86_64 exe 24MB、msi 25MB、deb 23MB、AppImage 83MB、x86_64 dmg 35MB；对照 32 位 Sciter 版 exe 12MB。「读码确认」（GitHub Release API）。2022 年有用户担心 Flutter 包 50MB，实际没有成为主要抱怨。
- 归属：Flutter 本身（引擎 + ICU + AOT 快照），但量级可以接受。

### 4.8 小结：Flutter 本身 vs RustDesk 写法
- Flutter 本身：白窗/黑窗（GPU/GL 兼容、resize 首帧握手）、UI 控件闪烁、多 engine 多窗口崩溃（#155685）、macOS 多窗口副窗口失灵（#133533）、语义树断言崩溃（旧版）、放弃 Win7、Linux arm64 官方支持晚。
- RustDesk 写法：视频软渲染路径和缓存导致的内存问题、键盘/IME 映射、Wayland 抓屏和输入、画布缩放、钉旧版拿不到上游修复。
- 架构选择放大的：一窗一 engine 让每个窗口都独立暴露首帧/GL 上下文问题，也让每个插件都要处理"多 engine"场景（window_manager、multi_window 一直在修）。

## 5. Flutter 插件依赖

来源 `rustdesk@bd92623:flutter/pubspec.yaml`。直接依赖约 60 个（不含 sdk 依赖）。「读码确认」

### 5.1 git 依赖（自己 fork 或自写）共 9 个
行数是用 GitHub API 按 pubspec 钉住的 commit 拉源码逐文件 `wc -l`，排除 example/、test/、生成文件。2026-10-22。

- `desktop_multi_window` → `rustdesk-org/rustdesk_desktop_multi_window`（fork 自 Kingtous，Kingtous 是 RustDesk 开发者，本质是 RustDesk 自写）：C/C++ 3730 行、Swift/ObjC 783 行、Dart 792 行。2026-09 仍在密集修 Windows 问题。
- `window_manager` → `rustdesk-org/window_manager`（fork 自 leanflutter）：C/C++ 2922、Swift/ObjC 883、Dart 1671。相对上游领先 19 个提交、落后 61 个（已经分叉，没法直接回到上游）。
- `texture_rgba_renderer` → `rustdesk-org/flutter_texture_rgba_renderer`（fork 自 Kingtous，自写）：C/C++ 649、Swift/ObjC 183、Dart 164。Rust 侧直接 `libloading` 打开它的动态库写帧（见 01 第 39 行）。
- `flutter_gpu_texture_renderer` → `rustdesk-org/flutter_gpu_texture_renderer`（自写，非 fork）：C/C++ 438、Dart 94。Windows D3D11 零拷贝上屏。
- `flutter_custom_cursor` → `rustdesk-org/flutter_custom_cursor`（fork 自 Kingtous，自写）：C/C++ 493、Swift/ObjC 150、Dart 147。
- `window_size` → `21pages/flutter-desktop-embedding` 的 `plugins/window_size`（fork 自 google，领先 2 个提交）：C/C++ 811、Swift/ObjC 236、Dart 417。
- `uni_links` → `rustdesk-org/uni_links`（领先 2 个提交）：Kotlin/Java 146、Swift/ObjC 99、C/C++ 12、Dart 58。
- `dash_chat_2` → `rustdesk-org/Dash-Chat-2`（领先 1、落后 45，2023 年后没动）：纯 Dart 2637 行。
- `dynamic_layouts` → `rustdesk-org/dynamic_layouts`（自存一份，2023 年后没动）：纯 Dart 1408 行。

合计：fork/自写插件里原生代码约 **C/C++ 9,050 行、Swift/ObjC 2,330 行、Kotlin/Java 150 行**，Dart 约 7,400 行。其中真正和远控核心相关的是 multi_window、两个 texture renderer、custom_cursor、window_manager。

### 5.2 RustDesk 仓库里的原生外壳「读码确认」
- `flutter/windows/runner`、`flutter/linux`、`flutter/macos` 的 C++/Swift 共 2,278 行（`win32_window.cpp` 338、`my_application.cc` 341、`MainFlutterWindow.swift` 316、`wayland_shortcuts_inhibit.cc` 244、`flutter_window.cpp` 239、`main.cpp` 192 等）。
- `flutter/android` 的 Kotlin/Java 4,191 行（屏幕采集服务、输入注入、悬浮窗），这是 Android 被控端的引擎代码，放在 Flutter 工程里。

### 5.3 换框架要找替代的
- 必须重做：多窗口/标签（multi_window）、视频外部纹理上屏（两个 renderer，含 Rust 侧 `src/flutter.rs` 里加载插件 DLL 的约定）、自定义光标、窗口控制（window_manager/window_size）、深链接（uni_links）、Wayland 快捷键拦截、Windows 白窗补丁这类 runner 逻辑。
- 普通 pub 包（url_launcher、file_picker、desktop_drop、qr、sqflite、xterm 等）在其他框架基本都有现成替代。
- `flutter_rust_bridge` 1.80 和 `src/flutter_ffi.rs`（317 个 `pub fn`）的 codegen 约定（见 05）。

## 6. 维护者是否表达过要换掉 Flutter

- 没有找到维护者说"要换掉 Flutter"或"在评估别的框架替换 Flutter"的表态。「一手来源检索，未命中」
- 有不满的表达：
  - 2022-09 博客"选 Flutter 好像是错的，但没有更好的选择"；"Flutter 桌面 bug 多，比预期糟得多"。
  - 2023-07 HN 帖子抱怨兼容性越来越差，同时说"Tauri 我也用过，兼容性并没有更好"，"Sciter 虽然轻但非常 buggy，迫不及待想扔掉"。https://news.ycombinator.com/item?id=36872677
  - 多处 issue 回复"Flutter 引擎问题，等 Flutter 更新"（#3147、#5108、#11908）。
- 和"换框架"有关的唯一线索：2023-05 的 GSoC Ideas wiki 有一条"把 UI 从 Sciter 迁到 Tauri"，说"Tauri 变稳定了，是时候换一个更优雅的 UI SDK"。这条针对的是 Sciter 那部分（32 位版），不是替换 Flutter，也没有后续。https://github.com/rustdesk/rustdesk/wiki/Ideas 「一手来源，但不是替换 Flutter」
- 用户侧的"别用 Flutter"讨论 #1056（2022-07）：用户嫌占资源、不像桌面应用，建议 MAUI/Avalonia；维护者没回应。https://github.com/rustdesk/rustdesk/discussions/1056 「旁证」
- 实际行动是"继续深耕 Flutter"：2026 年还在给 multi_window、runner 打补丁，计划把全平台升到 3.44。「读码确认」

## 7. Flutter 官方桌面现状（和 Porta 能不能甩包袱直接相关）

- Flutter 官方多窗口 API（一个 engine 多个窗口）：2026-05 的 3.44 发布说明写明仍是实验性、只在 main 渠道、不适合生产；2026-08-24 官方博客仍说"在 main 渠道、实验 flag 后面"。https://flutter.dev/blog/whats-new-in-flutter-3-44 、https://flutter.dev/blog/desktop-windowing-apis 「一手来源」。3.47（2026-08）是否转正没核实。
- 3.44 起 Canonical 成为 Flutter 桌面的牵头维护方（Linux/Windows/macOS embedder）。同上 3.44 博客。「一手来源」「推测」：桌面投入会比 2022~2024 年多，但"Google 重心在移动端"的老问题由第三方接手，节奏未知。

## 8. 结论：哪些包袱继续用 Flutter 也能甩掉，哪些只有换框架才能解决

### 8.1 Porta 继续用 Flutter、重写界面时可以甩掉的
- **钉 3.24.5 + 自编引擎 + Dart VM Win7 补丁**：Porta 不支持 Win7，直接用当前稳定版（3.44.x）和官方引擎即可。同时 Rust 1.75 的 MSRV 约束也随之可以放开（Win7 是同一个原因）。「读码确认 + 推测」
- **两套 Flutter 版本并存和 `apply_flutter_3.44_source_patches.sh`**：一个版本走全平台。
- **DropdownMenu SDK 补丁**：新 UI 不用这个组件或用新版。
- **macOS `_setFramesEnabledState` 补丁、语义树崩溃**：新版 Flutter 已修。
- **软渲染路径导致的内存问题**：只保留外部纹理路径（RGBA/GPU），不保留每帧经 Dart 解码的软渲染兜底，或者只在极少数环境保留。
- **models 和界面耦合、dash_chat_2/dynamic_layouts 这类陈旧 fork**：重写时自然淘汰。
- **IME/键盘映射问题**：本来就在 Rust 引擎层，换不换框架都要处理，不算 Flutter 包袱。

### 8.2 继续用 Flutter 只能部分缓解的
- **一窗一 engine 的多窗口架构**：可以改成"单窗口 + 应用内标签"（只有主窗口一个 engine，远程会话做成标签页，需要时再弹独立窗口），就绕开了 #155685 崩溃、macOS 副窗口问题和大部分多 engine 内存/首帧问题。代价是不能把一个会话拖成独立窗口，或者要等官方 windowing API 转正。「推测」
- **window_manager / multi_window / texture renderer / custom_cursor 这批 fork 插件**：视频外部纹理和光标是远控刚需，Porta 也得维护自己的版本（约 1,500 行 C++/Swift），只是可以精简到 Porta 需要的平台。

### 8.3 Flutter 本身带来的、只有换框架才能解决的
- **白窗/黑窗类兼容性**：Flutter 自带渲染管线（Skia/Impeller + ANGLE/GL/Metal），在老显卡、虚拟机、无 GPU 环境、窗口管理工具下出问题，RustDesk 维护者多次说"无能为力，等 Flutter"。#159630 至今 P3 open，RustDesk 只能在 runner 里打补丁。「一手来源」
- **UI 控件级的渲染怪问题**（tooltip 闪烁等）。
- **包体积和基础内存**：引擎 + AOT 运行时的固定开销（exe 24MB 对 Sciter 12MB），量级可接受。
- **桌面原生能力要自己写插件**：多级菜单、原生光标、窗口行为、系统快捷键拦截，Flutter 都没有现成的，换成原生或别的框架有些能直接用系统能力。
- 但注意：换框架不会消除最大的几类问题——Wayland 抓屏和输入、键盘映射、视频解码上屏，这些在 Rust 引擎层，任何 UI 框架都绕不开；而且换框架要重做视频帧上屏（RustDesk 当年放弃 Tauri 就是因为这一点）。「推测」

### 8.4 对"换不换"的一句话判断「推测」
RustDesk 的包袱里，最重、最显眼的那部分（钉版本、自编引擎、SDK 补丁、两套版本）几乎全部来自"要支持 Win7"和"一窗一 engine"这两个 RustDesk 自己的决定，Porta 继续用 Flutter 时都能甩掉。剩下真正属于 Flutter 的是白窗类 GPU 兼容问题和"桌面能力要自己补插件"，这是换框架的主要理由，但换框架的代价是重做视频上屏和全部 UI，而且 Wayland/输入/编解码这些更大的问题不会因此减少。
