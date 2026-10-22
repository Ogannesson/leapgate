# 03 · 第二期 Windows x64 客户端构建链方案

基线：客户端 `rustdesk@bd92623`（Cargo 版本 1.5.1，`porta-client` 的起点），hbb_common `5d52530`。下文 CI 行号、步骤名都按 `bd92623:.github/workflows/flutter-build.yml`。2026-10-22 用 GitHub API 对照上游 master（`828d110`），构建相关的版本钉值没有变化。

标记：【读码】读了代码，附位置；【一手来源】官方文档、官方仓库的 issue/PR/发布清单，附 URL，查证日期都是 2026-10-22；【推测】推理或未验证。

回答的问题：方案 §3.11 的两个候选，第二期编上游现有界面用哪个 Flutter。
- A：照搬上游 x64，Flutter 3.24.5 + 自编引擎 + SDK 补丁。
- B：用上游 arm64 那套新版 Flutter（3.44.9）+ 改源码脚本，来编 x64。

---

## 0. 结论速览

1. **推荐先走 B（Flutter 3.44.9），给它设三道验收关；过不了时先退到"自编 3.44.9 引擎、只打多窗口那一处补丁"（下文叫 C），最后才退回 A。** 理由：
   - B 不背 Win7 包袱，Rust 可以用当前稳定版。上游从 1.4.8（2026-06-21）起已经连续三个正式版发布 arm64 安装包，说明这套源码在 3.44 上能编、能用【一手来源】。
   - A 依赖的自编引擎来自 `rustdesk/engine` 一个叫 `main` 的浮动 release，2024-12-01 之后没再更新过，下载时没有校验和；它只对 3.24.5 有效【一手来源 + 读码】。
2. **B 的三个已知风险**，都要在第一次构建时实测：
   - **多窗口崩溃 flutter#155685 仍是 open（P2）**。触发它的那行引擎代码（`clear_current` 回调里调 `ClearCurrent()`）在 3.44.9 里原样还在【一手来源 + 读码】。上游 arm64 用的是官方引擎，没有这处补丁，也没搜到 arm64 用户报多窗口崩溃。但 arm64 用户很少，不能当作证据。
   - **x64 要开 `vram` 特性，arm64 不开**。D3D11 纹理零拷贝上屏（`flutter_gpu_texture_renderer` 插件）整条路径都在 `vram` 后面，所以"3.44 + D3D11 外部纹理"这个组合上游从没发布过【读码】。
   - `flutter pub get` 会在 3.44 下重新解析依赖、改写 `pubspec.lock`，每次构建的依赖版本可能不同【读码】。
3. **Impeller/D3D11 外部纹理崩溃（flutter#190774、#191468）和 B 无关**：3.44 在 Windows 上还是 Skia，Impeller 从 3.47 起才成为 Windows 默认渲染器。将来新界面升到 3.47 时：#190774 的修复经 cherry-pick 进了 **3.47.2**（3.47.0、3.47.1 都没有）；#191468 的报告者只在 main 上确认过修复，3.47.2 是否也修好了没有核实【一手来源】。现在的 stable 是 3.47.7。
4. **不支持 Win7 之后，Rust 1.75 可以换成当前稳定版**。钉 1.75 的理由只有两条：Rust 1.78 起官方 Windows 目标要求 Win10；1.77/1.78 的 i128 ABI 变化会弄坏 Sciter 版。两条都和 Porta 的 x64 Flutter 版无关【一手来源 + 读码】。但上游没有任何地方用新 Rust 编过 Windows + `flutter,hwcodec,vram`，首次构建可能要修几处小问题【推测】。依赖不要跟着升，见 §3。
5. **vcpkg 在 CI 里用 `files` 缓存最简单**：runner 是自己的 Windows 机器，缓存目录放在本机固定路径，不用上传下载。上游 CI 用的 `x-gha` 已经从 vcpkg 里删掉了【一手来源】。
6. **意外**：Forgejo Runner 官方只发 Linux 版二进制，Windows 版靠社区构建【一手来源】。"挂 Forgejo Actions、自己的 Windows 机器当 runner"这一步要先解决 runner 本身，见 §5.1。

---

## 1. 上游 Windows 构建的完整步骤

### 1.1 x64 和 arm64 对照

`build-for-windows-flutter` 这个 job 用一个 matrix 同时出 x64 和 arm64【读码：`flutter-build.yml` 第 152~545 行】。

| 项 | x64（`windows-2022` runner） | arm64（`windows-11-arm` runner） |
|---|---|---|
| Rust | `SCITER_RUST_VERSION` = 1.75 | 同左 |
| Flutter | `FLUTTER_VERSION` = 3.24.5 | `FLUTTER_WINDOWS_ARM_VERSION` = 3.44.9 |
| 安装 Flutter | `subosito/flutter-action`，architecture x64 | 同左装 x64 SDK，再执行 "Force arm64 Dart SDK + engine"，删掉 stamp 文件，重新拉 arm64 的 Dart 和引擎 |
| 引擎 | "Replace engine with rustdesk custom flutter engine"：下载 `rustdesk/engine` 的 `windows-x64-release.zip`，覆盖 SDK 缓存里的 `windows-x64-release` | 官方引擎 |
| SDK 补丁 | "Patch flutter"：`git apply .github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff`（只在 3.24.5 时） | 不打 |
| 源码补丁 | 无 | "Patch RustDesk sources for Flutter 3.44"：`bash .github/patches/apply_flutter_3.44_source_patches.sh` |
| 桥接代码 | artifact `bridge-artifact`（Linux 上用 Flutter **3.22.3** 生成） | artifact `bridge-artifact-flutter-3.44`（Linux 上用 Flutter **3.44.8** 生成） |
| vcpkg triplet | `x64-windows-static` | `arm64-windows-static` |
| libsodium | 用 `libsodium-sys` 自带的预编译库 | vcpkg 编 libsodium，设 `SODIUM_LIB_DIR` |
| Cargo 特性 | `flutter,hwcodec,vram` | `flutter,hwcodec`（注释：NVENC 要 CUDA，Intel MediaSDK 要 `__rdtsc`，ARM 上没有这些硬件） |
| MSBuild 架构 | x86 | arm64 |

### 1.2 逐步说明

1. **Rust**：`dtolnay/rust-toolchain` 装 1.75，组件 rustfmt；`Cargo.toml` 里写着 `rust-version = "1.75"`【读码】。环境变量上的注释给了两条理由：discussion #7503（Win7），以及 1.78 的 i128 ABI 变化会弄坏 Sciter 版。macOS 另用 1.81（`cidre` 要求）。上游 `ci.yml` 里唯一还在跑的 job（Linux x64、默认特性）用的是 stable【读码】。
2. **Flutter + 自编引擎**：x64 先 `flutter precache --windows`，再用 `Invoke-WebRequest` 下载 `https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip`，解压后 `mv -Force` 到 `C:/hostedtoolcache/windows/flutter/stable-3.24.5-x64/bin/cache/artifacts/engine/windows-x64-release/`。注释写的是对应 flutter#155685，而且这个 zip 只匹配 3.24 时代的 x64 引擎【读码】。
   - 这个 release 只有一个资产，发布于 2024-11-29，资产更新于 2024-12-01，仓库之后再没推送过【一手来源：GitHub API `repos/rustdesk/engine/releases`】。
   - 引擎是怎么编的（`rustdesk/engine:.github/workflows/flutter-engine-windows-x64-release-build.yml`，手动触发，`windows-2019` runner）【读码】：`fetch flutter` 后检出 3.24.5，然后改五处：
     | # | 改了什么 | 为了什么 |
     |---|---|---|
     | 1 | `shell/platform/windows/flutter_windows_engine.cc` 里把字符串 `ClearCurrent` 全部替换成 `MakeCurrent`，等于 `clear_current` 回调变成重新绑定 EGL 上下文 | 多窗口（多 engine）创建、关闭窗口时的崩溃，flutter#155685 |
     | 2 | `fml/hex_codec.h` 补 `#include <string>` | 编译修复 |
     | 3 | Dart VM `runtime/bin/platform_win.cc` 回退成 `gethostname`（从 dart-review 下载补丁） | **只为 Win7**（rustdesk#10085） |
     | 4 | 回退 Dart 的"移除 Windows 7 栈展开处理" | **只为 Win7** |
     | 5 | 回退 Dart `file_win.cc` 的一处改动 | **只为 Win7** |
     - 所以五处里只有第 1 处和 Win7 无关。去掉 Win7 后，自编引擎存在的唯一理由就是 #155685。
3. **dropdown 补丁**（`flutter_3.24.4_dropdown_menu_enableFilter.diff`，改 SDK 的 `packages/flutter/lib/src/material/dropdown_menu.dart`）【读码】：Material `DropdownMenu` 开了 `enableFilter` 后，选完一项不复位过滤状态，下次打开只剩过滤后的条目。补丁加了三处复位。和 Win7、多窗口都无关，是 3.24 的框架 bug。
   - 3.44.9 的 `dropdown_menu.dart` 在选中条目后已经有 `_enableFilter = false`，`didUpdateWidget` 里也有复位【读码：`flutter@3.44.9` 该文件第 780、1025 行附近】，上游 arm64 也不打这个补丁。补丁里"不过滤时把 `filteredEntries` 重置为全部条目"的那个 else 分支，3.44.9 里没有逐行对应的代码，两者是否完全等价没有验证【推测】。验收时点一下用到它的地方（`flutter/lib/common/widgets/dialog.dart` 的"添加到地址簿"下拉框）。
4. **3.44 源码补丁**（`apply_flutter_3.44_source_patches.sh`，arm64 构建和 3.44 的桥接 job 共用）【读码】：只改两个文件，用 sed 实现，脚本说明在 CRLF 检出下也安全。开始前先检查锚点，"已打过"就跳过，"打了一半或锚点漂移"就直接失败。
   - `flutter/lib/common.dart`：`DialogTheme(` → `DialogThemeData(`，`TabBarTheme(` → `TabBarThemeData(`（Flutter 3.27 起改了名），并给亮色和暗色两个 `DialogThemeData` 各补一行 `backgroundColor`。
   - `flutter/pubspec.yaml`：`extended_text 14.0.0 → 15.0.2`，`google_fonts ^6.2.1 → ^8.1.0`。
   - 脚本头注释写明：上游全平台统一升级 Flutter 后就删掉这个脚本，把改动提交进源码。
5. **flutter_rust_bridge 代码生成**（`bridge.yml`，在 `ubuntu-22.04` 上跑）【读码】：
   - 装 Rust 1.75、clang/llvm-dev/libclang-dev，`cargo install cargo-expand --version 1.0.95 --locked`，`cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked`。
   - 3.22.3 那一份先把 `extended_text` 降到 13.0.0；3.44 那一份先跑上面的源码补丁脚本。然后 `flutter pub get`。
   - `flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h`。
   - 产物是 `src/bridge_generated.rs`、`src/bridge_generated.io.rs`、`flutter/lib/generated_bridge.dart`、`flutter/lib/generated_bridge.freezed.dart`，加两个 `bridge_generated.h`。这几个文件都被 gitignore，不进仓库（`.gitignore`、`flutter/.gitignore`）。
   - 上游 `AGENTS.md` 明说"本地不要跑 codegen，环境难搭"。`flutter/build_fdroid.sh` 里有一份在非 CI 环境跑 codegen 的现成写法，带 `--llvm-path` 参数。
   - `generated_bridge.freezed.dart` 是 freezed 生成的，必须和构建时解析到的 freezed 版本一致（`bridge.yml` 注释），所以**桥接代码要用和构建同一个 Flutter 版本、同一份源码补丁来生成**。
6. **LLVM**：`KyleMayes/install-llvm-action` 装 15.0.6，给 bindgen（`Cargo.lock` 里有 0.59/0.65/0.69/0.72 四个版本）和 ffigen 用【读码】。
7. **vcpkg**【读码】：
   - `lukka/run-vcpkg@v11` 检出 vcpkg 到 `C:\vcpkg`，提交钉在 `9e593bb1`（2026.07.29）。它也是 `vcpkg.json` 的 baseline；改提交时要同步改 baseline，再改 `ci.yml` 和 `playground.yml`。
   - 安装命令：`vcpkg install --triplet x64-windows-static --x-install-root="$VCPKG_ROOT/installed"`，同时设 `VCPKG_DEFAULT_HOST_TRIPLET` 为同一个 triplet。
   - 清单 `vcpkg.json`（Windows x64 会生效的部分）：aom、libjpeg-turbo、opus、libvpx、libyuv、mfx-dispatch、ffmpeg（特性 amf、nvcodec、qsv）；host 和 target 各装一份。另有两个 `overrides`：ffnvcodec 12.1.14.0、amd-amf 1.4.35。`res/vcpkg/` 下有 6 个 overlay port（aom、ffmpeg、libvpx、libyuv、mfx-dispatch、opus）。`res/vcpkg-triplets/` 里只有 Android 的 triplet，Windows 用 vcpkg 自带的 `x64-windows-static`。
   - **安装位置是写死的**：`hwcodec` 的 `build.rs`（锁定提交 `rustdesk-org/hwcodec@febec27`，`link_vcpkg`）只认 `$VCPKG_ROOT/installed/<triplet>`，不看 `VCPKG_INSTALLED_ROOT`；`libs/scrap/build.rs` 两个变量都认。所以本地也必须照 CI 那样加 `--x-install-root=%VCPKG_ROOT%\installed`。不加的话，清单模式默认装到项目下的 `vcpkg_installed`，hwcodec 会找不到 ffmpeg。
   - 缓存：`VCPKG_BINARY_SOURCES: "clear;x-gha,readwrite"`。但 vcpkg-tool 在 2025-04-29 删掉了 `x-gha`（PR #1662），钉住的 vcpkg 提交带的是 2026-07-27 版工具【一手来源】。所以上游这条缓存配置现在大概率不起作用，具体是报错还是被忽略没有核实【推测】。
8. **构建命令**：`python3 .\build.py --portable --flutter --skip-portable-pack --hwcodec --vram`【读码：`build.py` `main`、`build_flutter_windows`】，依次做：
   - 进 `libs/virtual_display/dylib` 跑 `cargo build --locked --release`，产出 `dylib_virtual_display.dll`。
   - `cargo build --locked --features flutter,hwcodec,vram --lib --release`，产出 `librustdesk.dll`。
   - `flutter build windows --release`。
   - 把 `dylib_virtual_display.dll` 复制进 `flutter/build/windows/x64/runner/Release/`。
   - Cargo release 配置是 `lto = true`、`codegen-units = 1`、`panic = 'abort'`、`strip = true`。
9. **外部组件**（都在 "Build rustdesk" 步骤里）【读码】：
   - `rustdesk-org/rdev` 的 release `usbmmidd_v2/usbmmidd_v2.zip`（Amyuni 虚拟显示驱动，约 195 KB）。删掉 `Win32` 目录、`deviceinstaller64.exe`、`deviceinstaller.exe`、`usbmmidd.bat` 后放进产物目录。**没有校验和**。
   - `rustdesk/hbb_common` 的 release `driver`：`rustdesk_printer_driver_v4-1.4.zip`、`printer_driver_adapter.zip`，**和 `sha256sums` 比对**，一致才放进 `drivers/RustDeskPrinterDriver` 和根目录；不一致或下载失败只打日志，不让构建失败。
   - `RustDeskTempTopMostWindow`（`third-party-RustDeskTempTopMostWindow.yml`）：克隆 `rustdesk-org/RustDeskTempTopMostWindow`，检出 `ecd8d6a`，用 MSBuild 编 `WindowInjection.vcxproj`（`/p:TargetVersion=Windows10`），产出 `WindowInjection.dll`。它的 vcxproj 写的是 **v142 工具集（VS 2019）**【读码：GitHub API 读该文件】。
   - RustDesk 自己的 IDD 虚拟显示驱动（`RustDeskIddDriver`）CI 不打包，只打包它的控制库 `dylib_virtual_display.dll`【读码：`libs/virtual_display/dylib/src/win10/mod.rs` 的 `DRIVER_INSTALL_PATH`，CI 里没有对应的下载步骤】。
10. **打包**【读码】：
    - 便携版/自解压：先 `sed -i '/dpiAware/d' res/manifest.xml`，再 `pip3 install -r libs/portable/requirements.txt`（只有 `brotli`），`python3 libs/portable/generate.py -f <产物目录> -o . -e <产物目录>/rustdesk.exe`，产出 `target/release/rustdesk-portable-packer.exe`。
    - MSI：`python res/msi/preprocess.py --arp -d <产物目录>`（会**就地改写** `res/msi`），`nuget restore msi.sln`，`msbuild msi.sln -p:Configuration=Release -p:Platform=x64 /p:TargetVersion=Windows10`。WiX 走 NuGet 拉的 `WixToolset.Sdk/4.0.5`，自定义动作 `res/msi/CustomActions` 是 C++ 项目，工具集 v143（VS 2022），依赖 NuGet 包 `WixToolset.DUtil`、`WixToolset.WcaUtil` 4.0.5。
    - "pre-built MSI template" 是给上游定制客户端服务用的（带 `custom.txt` 占位），Porta 不需要。
11. **签名**【读码】："Sign rustdesk files" 和 "Sign rustdesk self-extracted file" 两步都是 `python3 res/job.py sign_files <目录>`，参数是 secrets `SIGN_BASE_URL`、`SIGN_SECRET_KEY`，调上游的私有签名服务。没有 secret 时跳过（条件 `SIGN_BASE_URL != '-2'`）。Porta 前两期不签名，这两步整段不要。另有 "Verify Windows Flutter version"、更新元数据签名几步，也只服务上游的发布流程。

---

## 2. 方案 B 的具体做法和风险

### 2.1 搬到 x64 要改什么

拿 arm64 那条路径，换成 x64：

| arm64 的步骤 | x64 怎么处理 |
|---|---|
| Flutter 3.44.9 | 照用。官方 Windows 发布清单里 3.44.9 的包是 `flutter_windows_3.44.9-stable.zip`，2026-08-06 发布，sha256 `8ef1107d226654736755bc51b969d6bd46787ff0241650f942e774fb0ca7d0ac`【一手来源：`releases_windows.json`】 |
| Force arm64 Dart | 不要（x64 SDK 自带的就是 x64 Dart） |
| 替换引擎 | 不要（这就是 B 和 A 的区别） |
| dropdown 补丁 | 不要（见 §1.2 第 3 条） |
| 源码补丁脚本 | 照跑（Git Bash） |
| 3.44 的桥接代码 | 照用：用 3.44.x 加同一份源码补丁生成 |
| `SODIUM_LIB_DIR` | 不设（x64 用 crate 自带的库） |
| 特性 | 加 `--vram`（x64 要硬件编码；这一项上游没在 3.44 上验证过，见下） |

总结：B 在 x64 上就是"官方 3.44.9 SDK，不碰引擎，跑一遍源码补丁脚本，用对应版本的桥接代码"。上游现成的东西都能直接用，Porta 自己不需要写补丁。

### 2.2 风险

1. **flutter#155685（多窗口创建、关闭时崩溃）**：open，P2，标签 `c: fatal crash`、`a: multi window`【一手来源：https://github.com/flutter/flutter/issues/155685】。
   - 3.24.5 和 3.44.9 的 `flutter_windows_engine.cc` 里，`config.open_gl.clear_current` 回调一字未改，都是 `return host->egl_manager()->render_context()->ClearCurrent();`【读码：3.24.5 对应 `flutter/engine` 提交，3.44.9 对应 `flutter/flutter@3.44.9:engine/src/flutter/shell/platform/windows/flutter_windows_engine.cc` 第 68~74 行】。也就是说，rustdesk/engine 绕开的那个条件在 3.44.9 里还在。
   - issue 里的讨论把根因指向 `clear_current`/`make_current` 回调在多 engine 下的行为，还提到回退后每创建关闭 100 个窗口约有 60 MB 泄漏。rustdesk/engine 的"全换成 MakeCurrent"是绕开，不是官方修复【一手来源：该 issue 2024-11 的评论】。
   - 上游 arm64 从 1.4.8 起发布、用的是官方引擎，用 GitHub 搜 `repo:rustdesk/rustdesk arm64 windows crash`（2026-06 以后）没有多窗口崩溃的报告，只有一个安装器的问题（#16018）【一手来源】。arm64 用户量小，这只能算弱证据。
2. **`vram` + 3.44 没人验证过**：`src/flutter.rs` 里加载 `flutter_gpu_texture_renderer_plugin.dll`、注册 D3D11 纹理的代码全部在 `#[cfg(feature = "vram")]` 下，`io_loop.rs` 第 2714 行也是 `all(feature = "vram", feature = "flutter")`【读码】。arm64 不开 vram，所以"3.44 官方引擎（Skia + ANGLE）+ DXGI 共享句柄外部纹理"从没在上游发过版。硬解零拷贝上屏能不能用、会不会闪、会不会崩，要实测。不行的话，可以先关掉 vram 走软件上屏路径（性能差，但能用）【推测】。
3. **Impeller 不是 B 的风险**：Flutter 3.47 才让 Impeller 成为 Windows 默认渲染器（PR #188140；官方文档写"enabled by default as of Flutter 3.47"；3.44 SDK 里还没有 `ImpellerSwitch`）【一手来源：https://docs.flutter.dev/perf/impeller 、https://flutter.dev/blog/whats-new-in-flutter-3-47 】。3.44.9 在 Windows 上还是 Skia。将来升到 3.47+ 时：
   - #190774（快照 GPU 外部纹理时崩溃，P1）2026-08-17 在 main 上关闭，修复是 PR #191017，cherry-pick PR #191222 合进 `flutter-3.47-candidate.0`。用 GitHub compare 对比，这个提交**不在 3.47.0、3.47.1 里，在 3.47.2 及之后**【一手来源】。
   - #191468（DXGI 共享句柄外部纹理在 `flutter_windows.dll` 崩溃，P2）2026-09-03 关闭。维护者说 #191017 修了 Windows 外部纹理的问题，报告者在 main 上确认不再崩溃【一手来源】。它是否只靠 #191017 就修好，因而 3.47.2+ 也修好了，没有核实【推测】。Porta 的 D3D11 路径（DXGI 共享句柄、`B8G8R8A8_UNORM`）正好就是这个 issue 的复现场景。
   - 3.47 的 release 模式下 `--no-enable-impeller` 不生效，要退回 Skia 只能在 `windows/runner/main.cpp` 里调 `project.set_impeller_switch(flutter::ImpellerSwitch::Disabled)`（#190910，维护者说这是设计如此）；官方说这个退路以后会删【一手来源】。
4. **`pubspec.lock` 漂移**：仓库里提交的 `flutter/pubspec.lock` 是 3.24.5 解析出来的。源码补丁改了 `pubspec.yaml`，`flutter build` 会重新 `pub get`，按 caret 范围拉当时最新的兼容版本【读码：补丁脚本注释】。两次构建可能用到不同的依赖版本。建议第一次构建成功后，把解析出的 lock 存进总仓库的构建脚本目录，以后构建前覆盖进去【推测：做法建议】。
5. **工作区会变脏**：源码补丁、`pub get`、`res/manifest.xml` 的 sed、`preprocess.py` 都会改 `client/` 里被跟踪的文件。脚本要么在单独的 worktree 或副本里构建，要么构建完 `git checkout --` 还原，否则会误提交【读码】。
6. **flutter#186730**（ARM 主机编 x64 失败）只影响在 ARM 机器上编 x64，和本方案无关【一手来源】。

### 2.3 B 的三道验收关

第一次构建出 exe 后逐条测，任何一条不过就按顺序退：先退 C（自编引擎），再退 A。

1. **多窗口压力**：同一个控制端反复打开、关闭远程会话窗口（标签拖出成独立窗口、文件传输窗口、端口转发窗口），至少 50 次；被控端的连接管理窗口（`--cm`）反复弹出、关闭。看是否崩溃，看进程内存是否持续上涨。
2. **硬解零拷贝上屏**：被控端分别用 H.264/H.265 硬编，控制端开 GPU 纹理渲染，1080p60 连续跑 10 分钟以上，拖动和缩放窗口。
3. **界面回归**：地址簿"添加到"下拉框（dropdown 补丁覆盖的位置）；明暗主题下对话框背景（源码补丁改的就是这里）；中文输入；高 DPI 跨屏拖动。

### 2.4 退路 C：自编 3.44.9 引擎，只打多窗口那一处补丁

- rustdesk/engine 的第 1 处改动就是一次字符串替换，3.44.9 里同一段代码还在，可以照搬；3~5 的 Win7 补丁一概不要。
- 代价：要搭 Flutter 引擎的构建环境（depot_tools、gclient），源码几十 GB，在一台普通机器上编一次要以小时计；而且 3.27 以后引擎已经并进 `flutter/flutter` 单一仓库，rustdesk/engine 那份按旧结构写的脚本不能直接用【推测】。只有 B 的第 1 关不过时才值得做。

### 2.5 A 怎么做（备查）

照 §1.2 第 2、3 条，外加用 Flutter 3.22.3 生成桥接代码（`extended_text` 降到 13.0.0）。本地落地时：
- 引擎 zip 第一次下载后记下 sha256，写进脚本，以后每次比对（上游不校验）。
- Rust 照样可以用新稳定版。Rust 版本和 Flutter 版本是独立的；用 1.75 只是因为 Win7。

---

## 3. 不支持 Win7 后能去掉什么

| 东西 | 为什么存在 | Porta 能不能去掉 |
|---|---|---|
| 自编引擎的 Win7 补丁（Dart VM 三处） | Win7 | 能（B 和 C 都不要） |
| 自编引擎的 `MakeCurrent` 补丁 | #155685 | 不一定，看 §2.3 第 1 关 |
| Flutter 钉 3.24.5 | Win7（官方 CI 注释、PR #15139） | 第二期能（B）；新界面直接用新版 |
| dropdown SDK 补丁 | 3.24 的框架 bug | 升到 3.44 后不需要（§1.2 第 3 条） |
| Rust 钉 1.75 | ①Rust 1.78 起官方 `*-pc-windows-*` 目标要求 Win10（新编出的程序在 Win7 上找不到 `ProcessPrng`）；②1.77/1.78 的 i128 布局变化弄坏 Sciter 版 | 能，见下 |
| `build-for-windows-sciter`（32 位 Sciter 版） | Win7/32 位 | 不构建 |
| MSI 的 `/p:TargetVersion=Windows10` | 已经是 Win10 | 保持 |

**Rust 1.75 换成当前稳定版**：
- 理由①：Rust 官方博客，1.78（2024-05-02）起 Windows Tier 1 目标的最低版本是 Win10，Win7 移到 Tier 3 的 `*-win7-windows-msvc`【一手来源：https://blog.rust-lang.org/2024/02/26/Windows-7/ 、Rust 1.78.0 发布说明】。discussion #7503 里上游说"1.77.2 在 Win7 上能用，1.78 不行"【一手来源：https://github.com/rustdesk/rustdesk/discussions/7503 】。Porta 不支持 Win7，这条不成立。
- 理由②：i128 ABI 只影响和 Sciter 动态库之间的调用。`src/lib.rs` 里 `pub mod ui`（Sciter 界面）在 `feature = "flutter"` 时不编译，`build.py` 的 `get_features` 也只在非 Flutter 时加 `inline`【读码】。`sciter-rs` 这个 crate 仍会被编译（`Cargo.toml` 里对非移动端无条件依赖），但 Flutter 版运行时不加载 Sciter。macOS 已经在用 1.81 编同一份依赖，说明 `sciter-rs` 在 1.78+ 上能编【读码】。这条也不成立。
- 没找到别的钉 1.75 的理由。`playground.yml`、`bridge.yml` 里的 1.75 都引用同一个 discussion。
- 现在的稳定版是 1.99.1（2026-10-16）【一手来源：GitHub API `rust-lang/rust` releases】。建议在构建脚本里钉一个具体版本，每次合并上游后再评估要不要升。不要用浮动的 `stable`。
- **没有直接证据证明新 Rust 能编 Windows 的 `flutter,hwcodec,vram` 组合**：上游 stable 只在 Linux 默认特性上跑，macOS 是 1.81，Windows 一直是 1.75【读码】。依赖里的新 lint 会被 cap-lints 压成警告；工作区自己的 crate 如果碰到新版本里默认 deny 的 lint，要修几行【推测】。`time` crate 在 Rust 1.80 的已知编译问题不会出现（`Cargo.lock` 里是 0.3.36，修复在 0.3.35）【读码】。

**哪些依赖因此能升**：技术上所有被 MSRV 1.75 卡住的 crate 都能升。但**不建议在 `porta-client` 里升上游的依赖**：每次合并上游都会在 `Cargo.lock` 上冲突，这正是 §3.2 要压的冲突面。正确做法：
- `Cargo.toml` 的 `rust-version = "1.75"` 不动。它只是下限，留着不影响新版本编译，改了反而会冲突。
- 继续用 `--locked`，`Cargo.lock` 跟上游走。
- `libs/porta` 是新 crate，可以用新依赖。但它加入工作区后，新依赖照样会写进共用的 `Cargo.lock`。这类冲突能机械处理，方案里已经算进去了。

**桥接代码生成和 Rust 版本的关系**（要注意）：frb 1.80.1 的 codegen 调 `cargo expand` 展开 `flutter_ffi.rs`，展开需要能编译到这个 crate【推测：frb v1 的实现方式】。
- 上游一直用 1.75 跑 codegen。换成新 Rust 后，展开结果里如果出现新语法，frb 1.80.1 自带的解析器可能解析不了【推测】。
- 第一次构建时先用新 Rust 跑 codegen。不行就只在 codegen 这一步用 1.75（`rustup toolchain install 1.75`，跑 codegen 时设 `RUSTUP_TOOLCHAIN=1.75`），正式编译仍用新版本。
- 但退回 1.75 有一个隐患：一旦 `libs/porta` 引入 MSRV 高于 1.75 的依赖，1.75 就编不过这个 crate，codegen 退路也就断了。所以要在第二期就确认新 Rust 能跑 codegen【推测】。

---

## 4. 维护者本机第一次手工构建（按 B）

约定：
- 构建根目录用 `D:\porta-build`（举例，任何非系统盘目录都行）。
- 环境变量**只在构建脚本的进程里设**，不写进系统或用户环境变量。这样构建链不污染机器，以后固化成 PowerShell 脚本时直接搬。
- "权限 / 系统影响"一栏：写"管理员"的要管理员权限；写"改系统"的会改系统环境（注册表、系统级 PATH、系统设置）。

耗时和磁盘都是估算【推测】，按 8 核以上、SSD、网络通畅估。

| # | 做什么 | 版本 / 来源 | 命令或要点 | 权限 / 系统影响 | 耗时 | 磁盘 |
|---|---|---|---|---|---|---|
| 1 | 系统开关 | — | 开"开发者模式"（Flutter 插件需要建符号链接）；开长路径（`LongPathsEnabled=1`）。可选：给 `D:\porta-build` 加 Defender 排除项，编译能快不少 | 管理员、改系统 | 2 分钟 | — |
| 2 | VS 2022 Build Tools | 17.x；工作负载"使用 C++ 的桌面开发"：MSVC v143 x64/x86、Windows 11 SDK（10.0.26100）、C++ CMake 工具。要编 `WindowInjection.dll` 再加"MSVC v142 生成工具"（`Microsoft.VisualStudio.Component.VC.v142.x86.x64`），或者构建时传 `/p:PlatformToolset=v143` 覆盖（没验证过）| `winget install Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"` | 管理员、改系统 | 20~40 分钟 | 8~12 GB |
| 3 | Git for Windows | 当前版 | 源码补丁脚本要用它带的 bash | 管理员、改系统（默认装法） | 5 分钟 | 0.5 GB |
| 4 | Python 3 | 3.10+ | `pip install brotli`（便携版打包要） | 用户级 | 5 分钟 | 0.2 GB |
| 5 | Rust | 钉一个具体的稳定版（例如 1.99.x） | rustup-init，`rustup toolchain install <版本> --profile minimal -c rustfmt`；构建时用 `cargo +<版本>`，或者设 `RUSTUP_TOOLCHAIN` | 用户级；rustup 会改**用户** PATH | 10 分钟 | 1.5 GB |
| 6 | LLVM | 15.0.6（与 CI 一致），`https://github.com/llvm/llvm-project/releases/download/llvmorg-15.0.6/LLVM-15.0.6-win64.exe`（约 290 MB） | 装到默认位置；构建进程里设 `LIBCLANG_PATH=C:\Program Files\LLVM\bin`。不想要管理员权限的话，可以用 7-Zip 把安装包解到构建目录 | 管理员（安装版） | 5 分钟 | 2.5 GB |
| 7 | vcpkg | 提交 `9e593bb18ea69cc5095e012465dcd675a822ed0d` | `git clone https://github.com/microsoft/vcpkg D:\porta-build\vcpkg`；`git -C D:\porta-build\vcpkg checkout 9e593bb1`；`D:\porta-build\vcpkg\bootstrap-vcpkg.bat -disableMetrics` | 用户级 | 5 分钟 | 1 GB |
| 8 | 编 C 依赖 | 按 `client\vcpkg.json` | 进程里设 `VCPKG_ROOT=D:\porta-build\vcpkg`、`VCPKG_DEFAULT_HOST_TRIPLET=x64-windows-static`、`VCPKG_BINARY_SOURCES=clear;files,D:\porta-build\vcpkg-cache,readwrite`；在 `client\` 下跑 `& $env:VCPKG_ROOT\vcpkg install --triplet x64-windows-static --x-install-root="$env:VCPKG_ROOT\installed" --clean-after-build`。**`--x-install-root` 不能省**（§1.2 第 7 条）。vcpkg 会自己下载 CMake、NASM、MSYS2 这些工具 | 用户级 | 首次 40~90 分钟（ffmpeg 最慢）；命中缓存后几分钟 | 安装目录 2~4 GB；缓存约 1 GB；不加 `--clean-after-build` 时 buildtrees 另占 10 GB 以上 |
| 9 | Flutter | 3.44.9，`https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.44.9-stable.zip`，核对 sha256（§2.1 表里那个值） | 解压到 `D:\porta-build\flutter`；进程 PATH 前面加 `D:\porta-build\flutter\bin`；`flutter config --no-analytics`；`flutter precache --windows`；`flutter doctor -v` | 用户级 | 10 分钟 | 3 GB |
| 10 | 准备干净的源码副本 | `client\` 当前提交 | 建议 `git -C client worktree add D:\porta-build\src HEAD`，再在 `D:\porta-build\src` 里 `git submodule update --init`，后面几步都在副本里做，不弄脏 `client\` | 用户级 | 2 分钟 | 1 GB |
| 11 | 打 3.44 源码补丁 | 上游脚本 | 在副本里用 Git Bash 跑 `bash .github/patches/apply_flutter_3.44_source_patches.sh` | — | 秒级 | — |
| 12 | 生成桥接代码 | frb_codegen 1.80.1、cargo-expand 1.0.95 | **推荐照 CI 在 Linux 机器或 WSL 里生成**：装 Rust、Flutter 3.44.x、clang/libclang；把第 11 步打过补丁的源码拿过去；`cargo install cargo-expand --version 1.0.95 --locked`；`cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked`；`cd flutter; flutter pub get; cd ..`；`flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h`。把 §1.2 第 5 条列的文件拷回副本。Windows 本地也可以试，加 `--llvm-path "C:\Program Files\LLVM"`，没验证过 | 用户级 | 首次 15~25 分钟（主要是 cargo install） | 1 GB |
| 13 | 编译 | — | 在副本根目录：`python build.py --portable --flutter --skip-portable-pack --hwcodec --vram`。产物在 `flutter\build\windows\x64\runner\Release\` | — | 首次 25~50 分钟（LTO 链接慢） | `target\` 10~20 GB |
| 14 | 外部组件 | §1.2 第 9 条那几个 URL | 下载 `usbmmidd_v2.zip`，按 CI 删掉多余文件后放进产物目录（第一次下载后记下 sha256，写进脚本）；打印机驱动和 adapter 按 `sha256sums` 校验后放进去；`WindowInjection.dll` 第一次构建可以先跳过（只影响隐私模式里的置顶窗口那条实现）【推测】 | — | 5 分钟 | — |
| 15 | 冒烟运行 | — | 直接运行产物目录里的 `rustdesk.exe`（第二期改名后是 Porta 的 exe），按 §2.3 三道关测 | — | 半天 | — |
| 16 | 打包（可选） | WiX 4.0.5（NuGet）、nuget.exe | 便携版：在副本里先删掉 `res\manifest.xml` 的 `dpiAware` 行，再 `python libs\portable\generate.py -f <产物目录> -o . -e <产物目录>\rustdesk.exe`。MSI：从 `https://dist.nuget.org/win-x86-commandline/latest/nuget.exe` 拿 nuget.exe（建议钉版本）；`cd res\msi`；`python preprocess.py --arp -d <产物目录>`；`nuget restore msi.sln`；在"VS 开发者 PowerShell"里跑 `msbuild msi.sln -p:Configuration=Release -p:Platform=x64 /p:TargetVersion=Windows10` | 用户级（装 MSI 时才要管理员权限） | 10~20 分钟 | 1 GB |
| 17 | 存 lock | — | 把副本里 `flutter\pubspec.lock` 存进总仓库的构建脚本目录（§2.2 第 4 条） | — | — | — |

合计：一次全新构建，下载加编译大约 3~4 小时，其中多半在等 vcpkg 和 Rust；磁盘预留 50 GB。第二次起有 vcpkg 缓存，Cargo 增量也在，大约 15~30 分钟。

几点说明：
- **签名、更新元数据、MSI 模板这几步整段不要**（§1.2 第 10、11 条）。
- 只有第 1~3 步和第 6 步（安装版）要管理员权限，都是一次性的系统准备。固化成脚本时，把它们放在单独的"准备机器"脚本里，日常构建脚本不需要管理员权限。
- 品牌改动（exe 名、图标、包 ID）是第二期的另一项任务，不在这份清单里；它会改 `flutter/windows/` 下的文件，可能和第 11 步的补丁脚本的锚点相邻，补丁脚本发现锚点漂移会直接报错【读码】。

---

## 5. vcpkg 二进制缓存在 Forgejo Actions 下怎么做

### 5.1 先说 runner

- Forgejo Runner 的 README 写着"在基于 Linux 内核的系统上支持并测试"，Windows 列在"可能有人在做"那一栏；最新的 v13.2.0（2026-09-18）只发了 linux-amd64 和 linux-arm64 两种二进制【一手来源：https://code.forgejo.org/forgejo/runner 、该 release 的资产列表】。
- Windows 版有社区维护的构建（`Crown0815/Forgejo-runner-windows-builder`，在 GitHub Actions 上编），维护者 2026-03 在 Forgejo Runner 仓库提过 issue #1441，讨论怎么跟上主线的改动【一手来源】。
- 标签用 `host` 类型（例如 `windows:host`），作业直接在宿主机上跑，没有隔离。官方安全文档提醒：host 模式下作业能读到 runner 的状态文件【一手来源：https://forgejo.org/docs/latest/admin/actions/configuration/ 、…/admin/actions/security/】。仓库公开时，要限制谁能触发这台 runner 上的作业（比如只允许维护者自己推送的分支和 tag 触发，不让 fork 的 PR 触发）【推测：做法建议】。
- 也可以考虑 Gitea 的 act_runner，它发 Windows 二进制。它和 Forgejo 的协议兼容性要另查【推测】。

### 5.2 files 缓存

自己的 Windows 机器当 runner、host 模式，缓存目录直接放在本机固定路径，**不需要 `actions/cache` 上传下载**：

```yaml
# 节选：.forgejo/workflows/windows.yml
jobs:
  build:
    runs-on: windows          # 对应 runner 注册时的 windows:host 标签
    env:
      VCPKG_ROOT: D:\ci\vcpkg                 # 固定位置，作业之间保留
      VCPKG_DEFAULT_HOST_TRIPLET: x64-windows-static
      VCPKG_BINARY_SOURCES: clear;files,D:\ci\vcpkg-cache,readwrite
    steps:
      - run: >
          & $env:VCPKG_ROOT\vcpkg install --triplet x64-windows-static
          --x-install-root="$env:VCPKG_ROOT\installed" --clean-after-build
```

- 语法 `files,<绝对路径>[,read|write|readwrite]`；`clear` 关掉默认缓存。不写 `VCPKG_BINARY_SOURCES` 时，vcpkg 默认也会用 files 缓存，位置是 `%VCPKG_DEFAULT_BINARY_CACHE%` 或 `%LOCALAPPDATA%\vcpkg\archives`【一手来源：https://learn.microsoft.com/en-us/vcpkg/reference/binarycaching 、https://learn.microsoft.com/en-us/vcpkg/users/binarycaching 】。显式写出来，是为了缓存位置不跟着 runner 的服务账号变。
- 维护者本机手工构建和 runner 如果是同一台机器，两边指向同一个缓存目录就能互相复用。微软的建议是 CI 读写、开发者只读【一手来源：同上】。
- 也可以把这些变量写进 runner 配置的 `runner.envs`，工作流里就不用写【推测：按 runner 配置项】。
- **缓存会失效的情况**：vcpkg 的缓存键是每个包的 ABI 哈希，算进去的有编译器、triplet、端口文件、依赖等。VS Build Tools 自动升级换了编译器、改了 vcpkg 提交或 overlay port，都会导致全部重编（又是将近 1 小时）【推测：按 vcpkg ABI 机制，没逐项核对清单】。建议关掉这台机器 VS 的自动更新，升级时有计划地做一次全量重编。
- 可选：用 vcpkg 的资产缓存（`X_VCPKG_ASSET_SOURCES`）把源码包和工具也缓存到本地目录，这样上游下载地址失效时不至于编不了【一手来源：binarycaching 文档提到 Asset Caching；具体语法未核】。
- 要多台机器共享时，不用 `files`，可以用 vcpkg 的 `nuget` 源，指向 Forgejo 软件包仓库的 NuGet 源；或者用 `http` 源（`http,<url模板>,readwrite[,<header>]`）【一手来源：binarycaching 参考文档列出这两种源；Forgejo NuGet 源和 vcpkg 的兼容性未核】。第二期只有一台机器，用不上。
- Cargo 也同理：host 模式下把 `CARGO_HOME`、`CARGO_TARGET_DIR` 指到固定目录，增量编译就能跨作业保留，不必引入 sccache 之类的新组件【推测】。

---

## 6. 需要维护者拍板的问题

1. 第二期按"B → C → A"的顺序试，同不同意？C（自编 3.44.9 引擎）要不要列为正式退路，还是 B 不过就直接退 A？
2. Rust 钉哪个具体版本（建议当前稳定版 1.99.x），以及升级节奏（建议跟上游合并一起评估）。
3. 桥接代码在哪里生成：照 CI 在 Linux（或 WSL）上生成再拷回，还是坚持在 Windows 本机生成（没验证过）。
4. Forgejo Actions 的 Windows runner 用社区构建的 Forgejo Runner，还是 Gitea act_runner，还是第二期先只用本机脚本、不上 CI。
5. 第二期要不要出 MSI：只出便携版可以省掉 WiX、nuget、CustomActions 这一整套；MSI 又牵涉 `is_custom_client()` 下的更新路径（另见本目录 01 号笔记）。

---

## 参考（查证日期都是 2026-10-22）

- flutter#155685：https://github.com/flutter/flutter/issues/155685
- flutter#190774、#191468、PR #191017、cherry-pick PR #191222：https://github.com/flutter/flutter/issues/190774 、https://github.com/flutter/flutter/issues/191468 、https://github.com/flutter/flutter/pull/191222
- Flutter stable 更新记录（3.47.x 热修）：https://github.com/flutter/flutter/blob/stable/CHANGELOG.md
- Flutter Windows 发布清单：https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json
- Impeller 文档：https://docs.flutter.dev/perf/impeller ；3.47 发布博客：https://flutter.dev/blog/whats-new-in-flutter-3-47 ；默认开启 PR：https://github.com/flutter/flutter/pull/188140 ；release 模式开关问题：https://github.com/flutter/flutter/issues/190910
- Rust Windows 最低版本：https://blog.rust-lang.org/2024/02/26/Windows-7/ ；Rust 1.78.0 发布说明：https://github.com/rust-lang/rust/releases/tag/1.78.0
- RustDesk discussion #7503：https://github.com/rustdesk/rustdesk/discussions/7503 ；PR #15139（arm64 用 3.44）：https://github.com/rustdesk/rustdesk/pull/15139
- rustdesk/engine 构建脚本：https://github.com/rustdesk/engine/blob/main/.github/workflows/flutter-engine-windows-x64-release-build.yml
- vcpkg 二进制缓存：https://learn.microsoft.com/en-us/vcpkg/reference/binarycaching 、https://learn.microsoft.com/en-us/vcpkg/consume/binary-caching-default ；删掉 x-gha：https://github.com/microsoft/vcpkg-tool/pull/1662
- Forgejo Runner：https://code.forgejo.org/forgejo/runner ；配置文档：https://forgejo.org/docs/latest/admin/actions/configuration/ ；Windows 构建讨论：https://code.forgejo.org/forgejo/runner/issues/1441

检索过程中没有遇到要求执行命令、读取或外发本机文件的网页内容。rustdesk/engine 的构建脚本里有从外部下载补丁的步骤，那是它自己的 CI 逻辑，只读了，没有执行。
