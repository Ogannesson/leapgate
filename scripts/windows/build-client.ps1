#Requires -Version 7.0
<#
.SYNOPSIS
  编译 Leapgate Windows 客户端（Flutter 版，x64）。-Ui leapgate（默认，M8 起发布的界面）编新界面
  leapgate_ui\app\，产物在 leapgate_ui\app\build\windows\x64\runner\Release\，旁边（runner\）另有便携
  单文件 leapgate-<版本>-x86_64.exe 和发布目录的 zip leapgate-<版本>-x86_64.zip；-Ui upstream 编上游
  界面 flutter\（旧界面便携版），产物（leapgate.exe、libleapgate.dll 等）留在 flutter\build\windows\x64\runner\Release\。

.DESCRIPTION
  先跑 setup-toolchain.ps1。步骤（-Steps 可只跑其中几步，默认全跑）：
    vcpkg   按客户端 vcpkg.json 编 C 依赖（x64-windows-static，二进制缓存在构建目录）
    patch   跑上游的 Flutter 3.44 源码补丁脚本（已打过会跳过），再用本目录钉住的 pubspec.lock 覆盖。
            -Ui leapgate 时跳过（新界面的源码不打补丁）
    bridge  生成 flutter_rust_bridge 桥接代码，两块：flutter_ffi.rs 和 leapgate_ffi.rs
            （缺文件或两个 ffi 文件更新过才生成，-ForceBridge 强制）
    build   之前核对 SDK 缓存里的引擎是 build-engine.ps1 -Install 用当前补丁装的自编版，不是就停下。
            先刷新 build.rs 的修改时间，让根 crate 的 build.rs 重跑、构建时间（BUILD_DATE）是这一次的：
            主页"升级"卡比的就是它（docs/新界面/11-M8拆法.md §4.4），build.rs 自己只在文件改过时重跑。
            -Ui upstream：python build.py --portable --flutter --skip-portable-pack --hwcodec [--vram]
            -Ui leapgate（docs/新界面/03-实施方案.md §1.7）：先在 core、app 各 pub get，两个 pubspec.lock
            和提交里的不一样就中止（入库的锁文件要和 pubspec.yaml 一致）；cargo 特性向
            build.py --print-features 要，和上游界面同一组；cargo 编 librustdesk.dll 和虚拟显示的 dylib；
            在 leapgate_ui\app 里 flutter build windows，--build-name 是 libs\leapgate 的版本；产物核对过后
            用 libs\portable\generate.py 打便携单文件（要 Python 的 brotli，setup-toolchain.ps1 装），再把
            发布目录打成 zip。便携包名不带 install：名字以 install.exe 结尾会被当成安装页（M8-2）。
            -PrinterDriver 时在打包前从上游发布页下载打印机驱动和适配器、按 sha256 核对后放进产物（M9-4）
  开头打印默认服务器有没有注入（LEAPGATE_RENDEZVOUS_SERVER、LEAPGATE_RS_PUB_KEY、LEAPGATE_API_SERVER，
  编译时读的环境变量）。
  patch、bridge、build 会改动 -Source 里被跟踪的文件（common.dart、pubspec.yaml、pubspec.lock），
  所以 -Source 应该是专门用来构建的 worktree，改动不要提交。

  -FlutterRoot 换一套 Flutter SDK（PATH 和引擎核对都按它），给新界面每个里程碑的最新 stable 检查用
  （03 §8.8），只配新界面用（脚本不拦，配 -Ui upstream 的结果没有意义）：那套是官方引擎，要配 -AllowOfficialEngine；它钉的基础包和 3.44.9 不同，pub get 会改
  两个 pubspec.lock，所以这时不查锁文件改动，检查完在构建 worktree 里还原它们。

.EXAMPLE
  pwsh -File scripts\windows\build-client.ps1 -Source D:\src\leapgate-client
.EXAMPLE
  # 在 pwsh 里调用（pwsh -File 会把 bridge,build 当成一个字符串传给 -Steps）
  scripts\windows\build-client.ps1 -Source D:\src\leapgate-client -Ui leapgate -Steps bridge,build
.EXAMPLE
  scripts\windows\build-client.ps1 -Source D:\src\leapgate-client -Ui leapgate -Steps bridge,build `
    -FlutterRoot C:\leapgate-build\flutter-3.47.9 -AllowOfficialEngine
#>
param(
    [Parameter(Mandatory)][string]$Source,
    [string]$BuildRoot,
    [ValidateSet('vcpkg', 'patch', 'bridge', 'build')][string[]]$Steps = @('vcpkg', 'patch', 'bridge', 'build'),
    # 编哪个界面：leapgate 是新界面 leapgate_ui\（docs/新界面/03-实施方案.md §1.7），upstream 是上游的 flutter\
    [ValidateSet('upstream', 'leapgate')][string]$Ui = 'leapgate',
    [switch]$ForceBridge,
    # 关掉 D3D11 纹理零拷贝上屏（vram 特性），退回软件上屏
    [switch]$NoVram,
    # 允许用 SDK 缓存里的官方 flutter_windows.dll 编（只报警告）；默认要求 build-engine.ps1 -Install 装的自编引擎
    [switch]$AllowOfficialEngine,
    # 换用这套 Flutter SDK（默认是 env.ps1 钉住的 3.44.9），见上面 -FlutterRoot 的说明
    [string]$FlutterRoot,
    # 从上游发布页下载打印机驱动和适配器放进产物（M9-4），见下面 build 一步里的说明；默认不下载
    [switch]$PrinterDriver
)

. "$PSScriptRoot\env.ps1"
$L = Get-LeapgateLayout $BuildRoot
if ($FlutterRoot) { $L.Flutter = (Resolve-Path $FlutterRoot).Path }
$Source = (Resolve-Path $Source).Path
New-Item -ItemType Directory -Force $L.Logs | Out-Null
$stamp = Get-Date -Format yyyyMMdd-HHmmss
$tools = Set-LeapgateBuildEnv $L
# 默认服务器在编译时注入（M8-4：这一版不注入），只说有没有、不打印值
$injected = 'LEAPGATE_RENDEZVOUS_SERVER', 'LEAPGATE_RS_PUB_KEY', 'LEAPGATE_API_SERVER' |
    Where-Object { [Environment]::GetEnvironmentVariable($_) }
Write-Host $(if ($injected) { "注入了默认服务器：$($injected -join '、')" } else { '未注入默认服务器' })
if ('build' -in $Steps -and $Ui -eq 'leapgate') {
    & python.exe -c 'import brotli'
    if ($LASTEXITCODE -ne 0) { throw '便携打包要 Python 的 brotli：先跑 setup-toolchain.ps1' }
}
Push-Location $Source
try {
    # ---- vcpkg ----
    if ('vcpkg' -in $Steps) {
        $log = Join-Path $L.Logs "$stamp-vcpkg.log"
        $baseline = (Get-Content vcpkg.json -Raw | ConvertFrom-Json).'vcpkg-configuration'.'default-registry'.baseline
        $head = (& git -C $L.Vcpkg rev-parse HEAD).Trim()
        if ($baseline -ne $head) {
            throw "vcpkg 提交 $head 和 vcpkg.json 的 baseline $baseline 不一致：改 env.ps1 的 VcpkgCommit 后重跑 setup-toolchain.ps1"
        }
        # --x-install-root 不能省：hwcodec 的 build.rs 只认 $VCPKG_ROOT\installed\<triplet>
        Invoke-Logged $log (Join-Path $L.Vcpkg 'vcpkg.exe') @('install', '--triplet', 'x64-windows-static',
            "--x-install-root=$($L.Vcpkg)\installed", '--clean-after-build')
    }

    # ---- patch ----
    $pinnedLock = Join-Path $PSScriptRoot "pubspec.lock.flutter-$($LeapgatePins.Flutter)"
    if ('patch' -in $Steps -and $Ui -ne 'leapgate') {
        $log = Join-Path $L.Logs "$stamp-patch.log"
        Invoke-Logged $log $tools.GitBash @('.github/patches/apply_flutter_3.44_source_patches.sh')
        # 补丁改了 pubspec.yaml，仓库里的 pubspec.lock 是上游按 3.24.5 解析的；换成钉住的这份，
        # 免得每次 pub get 按 caret 范围拉到不同版本
        Copy-Item $pinnedLock flutter\pubspec.lock -Force
    }

    # ---- bridge ----
    # 两块（docs/新界面/03-实施方案.md §1.4）：块 1 是上游的 flutter_ffi.rs，块 2 是 Leapgate 的 leapgate_ffi.rs。
    # Rust 侧两个界面共用一份，所以不管编哪个界面都生成两块，只是 Dart 和 C 头落的地方不同；
    # 编旧界面时块 2 的 Dart 留在 flutter\lib 里不用，也不提交
    if ('bridge' -in $Steps) {
        $log = Join-Path $L.Logs "$stamp-bridge.log"
        $dartRoot, $cDir = if ($Ui -eq 'leapgate') { 'leapgate_ui\core', 'leapgate_ui\core' } else { 'flutter', 'flutter\macos\Runner' }
        $cOutputs = "$cDir\bridge_generated.h", "$cDir\bridge_generated_leapgate.h"
        $dartOutputs = "$dartRoot\lib\generated_bridge.dart", "$dartRoot\lib\generated_bridge_leapgate.dart"
        $outputs = @('src\bridge_generated.rs', 'src\bridge_generated.io.rs', 'src\leapgate_bridge\bridge_generated.rs',
            'src\leapgate_bridge\bridge_generated.io.rs', "$dartRoot\lib\generated_bridge.freezed.dart") + $dartOutputs + $cOutputs
        $ffiTime = (Get-Item src\flutter_ffi.rs, src\leapgate_ffi.rs | Measure-Object LastWriteTime -Maximum).Maximum
        $stale = $ForceBridge -or ($outputs | Where-Object { -not (Test-Path $_) -or (Get-Item $_).LastWriteTime -lt $ffiTime })
        if ($stale) {
            Push-Location $dartRoot
            try { Invoke-Logged $log flutter.bat @('pub', 'get') } finally { Pop-Location }
            # codegen 要求 C 头已经存在（按绝对路径解析）；生成块 1 时 cbindgen 会顺着 leapgate_ffi.rs 的
            # #[path] 去读块 2 的 Rust 输出，所以它也要先有（空文件即可）。块 2 的输出目录自带 .gitignore
            foreach ($f in $cOutputs + 'src\leapgate_bridge\bridge_generated.rs') {
                if (-not (Test-Path $f)) { New-Item -ItemType File -Force $f | Out-Null }
            }
            # --c-output 每块写一次（不收多值）；--class-name 必须给，否则多块时块 1 的类名保不住
            $rel = { param($p) "./$($p -replace '\\', '/')" }
            $codegenArgs = @('--rust-input', './src/flutter_ffi.rs', './src/leapgate_ffi.rs', '--dart-output') +
                @($dartOutputs | ForEach-Object { & $rel $_ }) +
                @('--rust-output', './src/bridge_generated.rs', './src/leapgate_bridge/bridge_generated.rs',
                    '--class-name', 'Rustdesk', 'Leapgate',
                    '--c-output', (& $rel $cOutputs[0]), '--c-output', (& $rel $cOutputs[1]),
                    '--skip-add-mod-to-lib', '--llvm-path', $L.Llvm)
            Invoke-Logged $log flutter_rust_bridge_codegen.exe $codegenArgs
            if ($Ui -ne 'leapgate') { Copy-Item $cOutputs flutter\ios\Runner\ }
        } else {
            Write-Host '桥接代码是新的，跳过生成（-ForceBridge 可强制）'
        }
    }

    # ---- build ----
    if ('build' -in $Steps) {
        $log = Join-Path $L.Logs "$stamp-build.log"
        # 路线 C：SDK 缓存里应是 build-engine.ps1 用当前 engine-patches\ 编、装进去的自编 flutter_windows.dll
        # （带无障碍桥和多窗口的补丁）。flutter precache 或重装 SDK 会悄悄换回官方版，补丁改了也要重编，
        # 所以每次按它写的清单核对
        try {
            $engineHash = Assert-LeapgateEngine $L
        } catch {
            if (-not $AllowOfficialEngine) {
                throw "SDK 缓存里的引擎不是用当前补丁编的自编版（$_）：先跑 build-engine.ps1 -Install；确实要用官方引擎就加 -AllowOfficialEngine"
            }
            Write-Warning "用的不是当前补丁编的自编引擎（$_）：产物里的 flutter_windows.dll 可能没有无障碍桥（flutter#193588）和多窗口（flutter#155685）的补丁"
            $engineHash = $null
        }
        $buildArgs = @('build.py', '--portable', '--flutter', '--skip-portable-pack', '--hwcodec')
        if (-not $NoVram) { $buildArgs += '--vram' }
        # panic、日志里的 file!() 路径会编进二进制，把本机目录（含用户名）换成中性前缀。
        # 不能用 RUSTFLAGS / CARGO_ENCODED_RUSTFLAGS：它们会整个顶掉客户端 .cargo/config.toml 里的
        # +crt-static，链接时 CRT 不匹配；按目标三元组设的这个变量会和配置文件里的合并。
        # 它按空格分隔，所以路径不能带空格。改了它 cargo 会全量重编一次
        $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $HOME '.cargo' }
        $sysroot = (& rustc --print sysroot).Trim()
        $remap = @{ $cargoHome = '/cargo'; $sysroot = '/rustc'; $Source = '/src' }
        if ($remap.Keys -match ' ') { throw "路径带空格，--remap-path-prefix 没法传：$($remap.Keys -match ' ')" }
        $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS = ($remap.GetEnumerator() |
            ForEach-Object { "--remap-path-prefix=$($_.Key)=$($_.Value)" }) -join ' '
        # cc crate 编的 C/C++（如 hwcodec）里 __FILE__ 同理；MSVC 的 /d1trimfile 去掉前缀。
        # 用带目标三元组的变量名，只有 cc crate 读，Flutter 的 CMake 不受影响
        $trim = "/d1trimfile:$cargoHome\ /d1trimfile:$Source\"
        $env:CFLAGS_x86_64_pc_windows_msvc = $trim
        $env:CXXFLAGS_x86_64_pc_windows_msvc = $trim
        # 构建时间（src\version.rs 的 BUILD_DATE）由根 crate 的 build.rs 写，它只在 build.rs、Cargo.toml、
        # windows.cc 改过时重跑；只改修改时间，内容不动
        (Get-Item build.rs).LastWriteTime = Get-Date
        # crate 仍叫 librustdesk，Flutter 的 CMake 拷贝时改名为 libleapgate.dll
        $expected = 'leapgate.exe', 'libleapgate.dll', 'flutter_windows.dll', 'data\app.so'
        if ($Ui -eq 'leapgate') {
            # 先做锁文件检查，不通过就不用等 cargo 编完才知道
            foreach ($dir in 'leapgate_ui\core', 'leapgate_ui\app') {
                Push-Location $dir
                try { Invoke-Logged $log flutter.bat @('pub', 'get') } finally { Pop-Location }
            }
            # 两个锁文件入库，和提交里的比（暂存了也查得出）；不一样说明 pubspec.yaml 改过而锁文件没跟着提交
            if (-not $FlutterRoot) {
                & git diff HEAD --exit-code --stat -- leapgate_ui/core/pubspec.lock leapgate_ui/app/pubspec.lock
                if ($LASTEXITCODE -ne 0) {
                    throw 'pub get 解析出的 pubspec.lock 和提交里的不一样，构建中止：确认依赖改动无误后提交新的锁文件再编'
                }
            }
            # build.py 把 flutter\ 写死了，新界面照它的 Windows 路径（build_flutter_windows）自己编；
            # 特性列表向它要，保证和上游界面是同一组。stdout 上只有这一行
            $features = & python.exe @($buildArgs + '--print-features')
            if ($LASTEXITCODE -ne 0) { throw "build.py --print-features 失败（退出码 $LASTEXITCODE）" }
            Invoke-Logged $log cargo.exe @('build', '--locked', '--features', "$features".Trim(), '--lib', '--release')
            # 虚拟显示的 dylib，产物在客户端根目录的 target\release\deps\
            Push-Location libs\virtual_display\dylib
            try { Invoke-Logged $log cargo.exe @('build', '--locked', '--release') } finally { Pop-Location }
            # 产品版本是 libs\leapgate 的版本（R2-Q32），由 --build-name 写进 Windows 版本资源
            $version = (Select-String -Path libs\leapgate\Cargo.toml -Pattern '^version = "(.+)"' |
                Select-Object -First 1).Matches[0].Groups[1].Value
            Push-Location leapgate_ui\app
            try { Invoke-Logged $log flutter.bat @('build', 'windows', '--release', '--build-name', $version) } finally { Pop-Location }
            $out = Join-Path $Source 'leapgate_ui\app\build\windows\x64\runner\Release'
            Copy-Item target\release\deps\dylib_virtual_display.dll $out
            # Rust 按文件名加载这两个纹理插件，缺了只写日志、退回软件上屏
            $expected += 'texture_rgba_renderer_plugin.dll', 'flutter_gpu_texture_renderer_plugin.dll'
        } else {
            Invoke-Logged $log python.exe $buildArgs
            $out = Join-Path $Source 'flutter\build\windows\x64\runner\Release'
        }
        foreach ($f in $expected) {
            if (-not (Test-Path (Join-Path $out $f))) { throw "产物缺少 $f：$out" }
        }
        if ($engineHash -and
            (Get-FileHash (Join-Path $out 'flutter_windows.dll') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $engineHash) {
            throw "产物里的 flutter_windows.dll 不是缓存里的自编引擎：$out"
        }
        # 打印机驱动（M9-4、R3-Q23）：照上游 CI（.github/workflows/flutter-build.yml 的 Build rustdesk 一步）
        # 从 rustdesk/hbb_common 的 driver 发布下载驱动、适配器和同一发布里的 sha256sums，两个 zip 按它核对；
        # 驱动解到 drivers\RustDeskPrinterDriver（libs/remote_printer 按这个路径找 inf），适配器 dll 放程序旁。
        # 上游核对不符时跳过、照常出包，这里直接停下。在打便携包之前放进去，便携单文件里也有。
        # 默认不下载：没有它时设置"远程打印"的"安装"报 inf 不存在
        if ($PrinterDriver) {
            $release = 'https://github.com/rustdesk/hbb_common/releases/download/driver'
            $driverZip, $adapterZip = 'rustdesk_printer_driver_v4-1.4.zip', 'printer_driver_adapter.zip'
            $dl = Join-Path $L.Downloads 'printer-driver'
            Remove-Item -Recurse -Force $dl -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force $dl | Out-Null
            foreach ($f in $driverZip, $adapterZip, 'sha256sums') {
                Invoke-Logged $log curl.exe @('-fL', '--retry', '3', '-o', (Join-Path $dl $f), "$release/$f")
            }
            $sums = Get-Content (Join-Path $dl 'sha256sums')
            foreach ($f in $driverZip, $adapterZip) {
                $line = $sums | Where-Object { $_ -match "^([a-fA-F0-9]{64}) \*$([regex]::Escape($f))$" } | Select-Object -First 1
                if (-not $line) { throw "sha256sums 里没有 $f" }
                $expectedSum = ($line -split ' ')[0]
                $actual = (Get-FileHash (Join-Path $dl $f) -Algorithm SHA256).Hash
                if ($actual -ne $expectedSum) { throw "sha256 不符：$f`n  期望 $expectedSum`n  实际 $actual" }
            }
            Expand-Archive (Join-Path $dl $driverZip) -DestinationPath $dl -Force
            Expand-Archive (Join-Path $dl $adapterZip) -DestinationPath $dl -Force
            $drivers = Join-Path $out 'drivers'
            New-Item -ItemType Directory -Force $drivers | Out-Null
            Remove-Item -Recurse -Force (Join-Path $drivers 'RustDeskPrinterDriver') -ErrorAction SilentlyContinue
            Move-Item (Join-Path $dl 'rustdesk_printer_driver_v4-1.4') (Join-Path $drivers 'RustDeskPrinterDriver')
            Copy-Item -Force (Join-Path $dl 'printer_driver_adapter.dll') $out
            foreach ($f in 'drivers\RustDeskPrinterDriver\RustDeskPrinterDriver.inf', 'printer_driver_adapter.dll') {
                if (-not (Test-Path (Join-Path $out $f))) { throw "产物缺少 $f：$out" }
            }
        }
        if ($Ui -eq 'leapgate') {
            # 便携单文件（M8-2）：照 build.py 的 build_flutter_windows 调 generate.py，它把发布目录压进
            # data.bin，再在工作区里编 rustdesk-portable-packer。包名不带 install（以 install.exe
            # 结尾会被当成安装页）；再把发布目录打一个 zip（M8-3）。两个都放在发布目录旁边
            Push-Location libs\portable
            try {
                Invoke-Logged $log python.exe @('generate.py', '-f', $out, '-o', '.', '-e', (Join-Path $out 'leapgate.exe'))
            } finally { Pop-Location }
            $packages = Split-Path $out
            $portable = Join-Path $packages "leapgate-$version-x86_64.exe"
            Move-Item -Force target\release\rustdesk-portable-packer.exe $portable
            $zip = Join-Path $packages "leapgate-$version-x86_64.zip"
            Compress-Archive -Path "$out\*" -DestinationPath $zip -Force
            foreach ($f in $portable, $zip) {
                if (-not (Test-Path $f)) { throw "产物缺少 $f" }
            }
            Write-Host "便携单文件：$portable`n发布目录的 zip：$zip" -ForegroundColor Green
        }
        # pubspec.yaml 随上游合并会变；pub get 改写了锁文件就说明钉住的那份要更新
        if ($Ui -ne 'leapgate' -and (Get-FileHash flutter\pubspec.lock).Hash -ne (Get-FileHash $pinnedLock).Hash) {
            Write-Warning "flutter\pubspec.lock 和 $pinnedLock 不一致：确认构建无误后用前者覆盖后者并提交"
        }
        Write-Host "产物：$out" -ForegroundColor Green
    }
} finally {
    Pop-Location
}
