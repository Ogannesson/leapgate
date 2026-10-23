#Requires -Version 7.0
<#
.SYNOPSIS
  装 Leapgate Windows 客户端的构建工具链（用户级、可重复跑，已装好的会跳过）。

.DESCRIPTION
  装到 -BuildRoot（默认 $env:LEAPGATE_BUILD_ROOT，再默认 C:\leapgate-build）：
    Rust 工具链（rustup，钉版本）、LLVM（解压安装包，不用管理员）、Flutter SDK、vcpkg（钉提交）、
    flutter_rust_bridge_codegen 和 cargo-expand（cargo install 到构建目录）。
  需要管理员权限的系统准备（VS 2022 Build Tools、开发者模式、长路径）只检查，不做；缺了就报出来退出。
  事先要有：rustup、Git for Windows、Python 3.10+；解压 LLVM 安装包要 7-Zip 或 Bandizip。

.EXAMPLE
  pwsh -File scripts\windows\setup-toolchain.ps1
#>
param(
    [string]$BuildRoot
)

. "$PSScriptRoot\env.ps1"
$L = Get-LeapgateLayout $BuildRoot
New-Item -ItemType Directory -Force $L.Root, $L.Downloads, $L.Logs | Out-Null
$log = Join-Path $L.Logs "setup-$(Get-Date -Format yyyyMMdd-HHmmss).log"

# ---- 1. 只检查的系统准备 ----
$missing = @()
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = if (Test-Path $vswhere) {
    & $vswhere -latest -products * -version '[17.0,18.0)' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.CMake.Project `
        -property installationPath
}
if (-not $vsPath) {
    $missing += 'VS 2022（Build Tools 即可）的组件：MSVC v143 x64/x86 生成工具、Windows 11 SDK、用于 Windows 的 C++ CMake 工具'
}
$appModel = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue
if ($appModel.AllowDevelopmentWithoutDevLicense -ne 1) { $missing += '开发者模式（Flutter 插件要建符号链接）' }
$fs = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction SilentlyContinue
if ($fs.LongPathsEnabled -ne 1) { $missing += '长路径支持（LongPathsEnabled=1）' }
if ($missing) {
    Write-Host '以下系统准备需要管理员权限，请先手工完成再重跑本脚本：' -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    exit 1
}
Write-Host "VS: $vsPath"

$tools = Set-LeapgateBuildEnv $L

function Get-VerifiedDownload {
    param([string]$Url, [string]$Sha256, [string]$Dir)
    New-Item -ItemType Directory -Force $Dir | Out-Null
    $file = Join-Path $Dir (Split-Path $Url -Leaf)
    if (-not (Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash -ne $Sha256) {
        Invoke-Logged $log curl.exe @('-fL', '--retry', '3', '-o', $file, $Url)
        $actual = (Get-FileHash $file -Algorithm SHA256).Hash
        if ($actual -ne $Sha256) { throw "sha256 不符：$file`n  期望 $Sha256`n  实际 $actual" }
    }
    $file
}

# ---- 2. Rust ----
if (-not ((& rustup toolchain list) -match "^$([regex]::Escape($LeapgatePins.Rust))-")) {
    Invoke-Logged $log rustup @('toolchain', 'install', $LeapgatePins.Rust, '--profile', 'minimal',
        '--component', 'rustfmt', '--no-self-update')
}
Invoke-Logged $log rustc @('--version')

# ---- 3. LLVM（给 bindgen 用的 libclang，ffigen 也用）----
if (-not (Test-Path (Join-Path $L.Llvm 'bin\libclang.dll'))) {
    $ver = $LeapgatePins.Llvm
    $exe = Get-VerifiedDownload "https://github.com/llvm/llvm-project/releases/download/llvmorg-$ver/LLVM-$ver-win64.exe" `
        $LeapgatePins.LlvmSha256 (Join-Path $L.Downloads "llvm-$ver")
    # 官方只发 NSIS 安装包，安装要管理员权限；用能解 NSIS 的解压工具直接解开
    $7z = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
    if (-not $7z -and (Test-Path "$env:ProgramFiles\7-Zip\7z.exe")) { $7z = "$env:ProgramFiles\7-Zip\7z.exe" }
    if ($7z) {
        Invoke-Logged $log $7z @('x', '-y', "-o$($L.Llvm)", $exe)
    } elseif (Test-Path "$env:ProgramFiles\Bandizip\bz.exe") {
        Invoke-Logged $log "$env:ProgramFiles\Bandizip\bz.exe" @('x', '-y', "-o:$($L.Llvm)", $exe)
    } else {
        throw '解压 LLVM 安装包需要 7-Zip 或 Bandizip'
    }
    Remove-Item -Recurse -Force (Join-Path $L.Llvm '$PLUGINSDIR'), (Join-Path $L.Llvm 'Uninstall.exe') -ErrorAction SilentlyContinue
    if (-not (Test-Path (Join-Path $L.Llvm 'bin\libclang.dll'))) { throw "LLVM 解压后找不到 libclang.dll：$($L.Llvm)" }
}

# ---- 4. Flutter ----
if (-not (Test-Path (Join-Path $L.Flutter 'bin\flutter.bat'))) {
    $ver = $LeapgatePins.Flutter
    $zip = Get-VerifiedDownload "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_$ver-stable.zip" `
        $LeapgatePins.FlutterSha256 (Join-Path $L.Downloads "flutter-$ver")
    $tmp = "$($L.Flutter).tmp"
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $tmp | Out-Null
    Invoke-Logged $log "$env:SystemRoot\System32\tar.exe" @('-xf', $zip, '-C', $tmp)
    Move-Item (Join-Path $tmp 'flutter') $L.Flutter
    Remove-Item -Recurse -Force $tmp
}
Invoke-Logged $log flutter.bat @('config', '--no-analytics', '--no-cli-animations')
Invoke-Logged $log dart.bat @('--disable-analytics')
Invoke-Logged $log flutter.bat @('precache', '--windows')

# ---- 5. vcpkg ----
if (-not (Test-Path (Join-Path $L.Vcpkg '.git'))) {
    Invoke-Logged $log git @('clone', 'https://github.com/microsoft/vcpkg', $L.Vcpkg)
}
$head = (& git -C $L.Vcpkg rev-parse HEAD).Trim()
if ($head -ne $LeapgatePins.VcpkgCommit) {
    & git -C $L.Vcpkg cat-file -e "$($LeapgatePins.VcpkgCommit)^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { Invoke-Logged $log git @('-C', $L.Vcpkg, 'fetch', 'origin') }
    Invoke-Logged $log git @('-C', $L.Vcpkg, 'checkout', '--quiet', $LeapgatePins.VcpkgCommit)
}
if ($head -ne $LeapgatePins.VcpkgCommit -or -not (Test-Path (Join-Path $L.Vcpkg 'vcpkg.exe'))) {
    Invoke-Logged $log (Join-Path $L.Vcpkg 'bootstrap-vcpkg.bat') @('-disableMetrics')
}
New-Item -ItemType Directory -Force $L.VcpkgCache | Out-Null

# ---- 6. 桥接代码生成工具 ----
function Install-CargoTool {
    param([string]$Crate, [string]$Exe, [string]$Version, [string[]]$Extra = @())
    $path = Join-Path $L.CargoTools "bin\$Exe"
    $have = if (Test-Path $path) { & $path --version 2>$null }
    if ("$have" -notmatch [regex]::Escape($Version)) {
        Invoke-Logged $log cargo (@('install', $Crate, '--version', $Version, '--locked', '--root', $L.CargoTools) + $Extra)
    }
}
Install-CargoTool cargo-expand cargo-expand.exe $LeapgatePins.CargoExpand
Install-CargoTool flutter_rust_bridge_codegen flutter_rust_bridge_codegen.exe $LeapgatePins.FrbCodegen @('--features', 'uuid')

Invoke-Logged $log flutter.bat @('doctor', '-v')
Write-Host "工具链就绪：$($L.Root)（日志 $log）" -ForegroundColor Green
