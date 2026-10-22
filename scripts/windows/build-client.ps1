#Requires -Version 7.0
<#
.SYNOPSIS
  编译 Porta Windows 客户端（Flutter 版，x64），产物（porta.exe、libporta.dll 等）留在源码目录的
  flutter\build\windows\x64\runner\Release\。

.DESCRIPTION
  先跑 setup-toolchain.ps1。步骤（-Steps 可只跑其中几步，默认全跑）：
    vcpkg   按客户端 vcpkg.json 编 C 依赖（x64-windows-static，二进制缓存在构建目录）
    patch   跑上游的 Flutter 3.44 源码补丁脚本（已打过会跳过），再用本目录钉住的 pubspec.lock 覆盖
    bridge  生成 flutter_rust_bridge 桥接代码（缺文件或 flutter_ffi.rs 更新过才生成，-ForceBridge 强制）
    build   python build.py --portable --flutter --skip-portable-pack --hwcodec [--vram]
  patch、bridge、build 会改动 -Source 里被跟踪的文件（common.dart、pubspec.yaml、pubspec.lock），
  所以 -Source 应该是专门用来构建的 worktree，改动不要提交。

.EXAMPLE
  pwsh -File scripts\windows\build-client.ps1 -Source D:\src\porta-client
#>
param(
    [Parameter(Mandatory)][string]$Source,
    [string]$BuildRoot,
    [ValidateSet('vcpkg', 'patch', 'bridge', 'build')][string[]]$Steps = @('vcpkg', 'patch', 'bridge', 'build'),
    [switch]$ForceBridge,
    # 关掉 D3D11 纹理零拷贝上屏（vram 特性），退回软件上屏
    [switch]$NoVram
)

. "$PSScriptRoot\env.ps1"
$L = Get-PortaLayout $BuildRoot
$Source = (Resolve-Path $Source).Path
New-Item -ItemType Directory -Force $L.Logs | Out-Null
$stamp = Get-Date -Format yyyyMMdd-HHmmss
$tools = Set-PortaBuildEnv $L
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
    $pinnedLock = Join-Path $PSScriptRoot "pubspec.lock.flutter-$($PortaPins.Flutter)"
    if ('patch' -in $Steps) {
        $log = Join-Path $L.Logs "$stamp-patch.log"
        Invoke-Logged $log $tools.GitBash @('.github/patches/apply_flutter_3.44_source_patches.sh')
        # 补丁改了 pubspec.yaml，仓库里的 pubspec.lock 是上游按 3.24.5 解析的；换成钉住的这份，
        # 免得每次 pub get 按 caret 范围拉到不同版本
        Copy-Item $pinnedLock flutter\pubspec.lock -Force
    }

    # ---- bridge ----
    if ('bridge' -in $Steps) {
        $log = Join-Path $L.Logs "$stamp-bridge.log"
        $outputs = 'src\bridge_generated.rs', 'src\bridge_generated.io.rs', 'flutter\lib\generated_bridge.dart',
            'flutter\lib\generated_bridge.freezed.dart', 'flutter\macos\Runner\bridge_generated.h'
        $ffi = Get-Item src\flutter_ffi.rs
        $stale = $ForceBridge -or ($outputs | Where-Object { -not (Test-Path $_) -or (Get-Item $_).LastWriteTime -lt $ffi.LastWriteTime })
        if ($stale) {
            Push-Location flutter
            try { Invoke-Logged $log flutter.bat @('pub', 'get') } finally { Pop-Location }
            Invoke-Logged $log flutter_rust_bridge_codegen.exe @('--rust-input', './src/flutter_ffi.rs',
                '--dart-output', './flutter/lib/generated_bridge.dart',
                '--c-output', './flutter/macos/Runner/bridge_generated.h',
                '--llvm-path', $L.Llvm)
            Copy-Item flutter\macos\Runner\bridge_generated.h flutter\ios\Runner\bridge_generated.h
        } else {
            Write-Host '桥接代码是新的，跳过生成（-ForceBridge 可强制）'
        }
    }

    # ---- build ----
    if ('build' -in $Steps) {
        $log = Join-Path $L.Logs "$stamp-build.log"
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
        Invoke-Logged $log python.exe $buildArgs
        $out = Join-Path $Source 'flutter\build\windows\x64\runner\Release'
        # crate 仍叫 librustdesk，Flutter 的 CMake 拷贝时改名为 libporta.dll
        foreach ($f in 'porta.exe', 'libporta.dll', 'flutter_windows.dll', 'data\app.so') {
            if (-not (Test-Path (Join-Path $out $f))) { throw "产物缺少 $f：$out" }
        }
        # pubspec.yaml 随上游合并会变；pub get 改写了锁文件就说明钉住的那份要更新
        if ((Get-FileHash flutter\pubspec.lock).Hash -ne (Get-FileHash $pinnedLock).Hash) {
            Write-Warning "flutter\pubspec.lock 和 $pinnedLock 不一致：确认构建无误后用前者覆盖后者并提交"
        }
        Write-Host "产物：$out" -ForegroundColor Green
    }
} finally {
    Pop-Location
}
