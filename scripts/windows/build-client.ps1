#Requires -Version 7.0
<#
.SYNOPSIS
  编译 Porta Windows 客户端（Flutter 版，x64），产物留在源码目录的 flutter\build\windows\x64\runner\Release\。

.DESCRIPTION
  先跑 setup-toolchain.ps1。步骤（-Steps 可只跑其中几步，默认全跑）：
    vcpkg   按客户端 vcpkg.json 编 C 依赖（x64-windows-static，二进制缓存在构建目录）
    patch   跑上游的 Flutter 3.44 源码补丁脚本（已打过会跳过）
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
    if ('patch' -in $Steps) {
        $log = Join-Path $L.Logs "$stamp-patch.log"
        Invoke-Logged $log $tools.GitBash @('.github/patches/apply_flutter_3.44_source_patches.sh')
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
        Invoke-Logged $log python.exe $buildArgs
        $out = Join-Path $Source 'flutter\build\windows\x64\runner\Release'
        foreach ($f in 'rustdesk.exe', 'librustdesk.dll', 'flutter_windows.dll', 'data\app.so') {
            if (-not (Test-Path (Join-Path $out $f))) { throw "产物缺少 $f：$out" }
        }
        Write-Host "产物：$out" -ForegroundColor Green
    }
} finally {
    Pop-Location
}
