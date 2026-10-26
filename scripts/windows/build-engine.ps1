#Requires -Version 7.0
<#
.SYNOPSIS
  自编 Flutter 3.44.9 的 Windows x64 release 引擎（只编 flutter_windows.dll），打上 engine-patches\ 里的补丁，
  可选装进 SDK 缓存，供 build-client.ps1 使用（路线 C）。

.DESCRIPTION
  补丁只改引擎的 C++；Dart VM、gen_snapshot、框架都和官方 3.44.9 同源，所以只换 SDK 缓存
  bin\cache\artifacts\engine\windows-x64-release\ 里 flutter_windows.dll 那一组文件（.dll .exp .lib .pdb）。
  步骤（-Steps 可只跑其中几步；默认 checkout sync patch build，-Test、-Install 再各加一步）：
    checkout  准备 depot_tools（钉住的提交）和 flutter/flutter 对应标签（env.ps1 的 Flutter）的浅克隆
              （已有就跳过），核对检出的提交和 engine.version
    sync      gclient sync；成功后在检出的 .git 里记一个戳，同一引擎提交不再重跑（-ForceSync 强制）
    patch     按文件名顺序打 engine-patches\*.patch；已打过的跳过，打了一半的报错
    build     先核对检出正好是标签加这几份补丁；gn（参数同官方 CI 的 ci/host_release）+ ninja，
              只编 flutter_windows；再和官方原件比导出表、核对 Dart 快照哈希和缓存里的 gen_snapshot 一致，
              最后在产物目录写戳 leapgate-build.json（引擎提交、补丁、产物的 SHA256）
    test      编 host_debug_unopt 的 common_cpp_unittests、flutter_windows_unittests，两个都完整跑一遍
    install   核对产物戳和当前补丁、产物一致，装进 SDK 缓存（官方原件先备份到 -BuildRoot\engine-official\，
              只备份一次），写清单 leapgate-engine.json，再用 build-client.ps1 的核对逻辑复查一遍
  事先要有：VS 2022（Build Tools 即可，要含"C++ ATL"组件）、Windows SDK 带 Debugging Tools、Git、Python 3，
  以及 setup-toolchain.ps1 装好的 Flutter SDK 和 LLVM（比导出表用 llvm-readobj）。
  一次完整的 release 构建要一两个小时，-Jobs 按机器负载调。
  换回官方引擎：把备份目录里的四个文件拷回 SDK 缓存并删掉 leapgate-engine.json，或 flutter precache --force。

.EXAMPLE
  pwsh -File scripts\windows\build-engine.ps1 -BuildRoot C:\porta-build -EngineRoot D:\leapgate-engine -Test -Install
#>
param(
    [string]$BuildRoot,
    # 放 depot_tools 和 flutter 检出的目录，要几十 GB；默认 $env:LEAPGATE_ENGINE_ROOT，再默认 -BuildRoot\engine
    [string]$EngineRoot,
    [ValidateSet('checkout', 'sync', 'patch', 'build', 'test', 'install')]
    [string[]]$Steps = @('checkout', 'sync', 'patch', 'build'),
    [switch]$Test,
    [switch]$Install,
    [switch]$ForceSync,
    [int]$Jobs = 24
)

. "$PSScriptRoot\env.ps1"
$L = Get-LeapgateLayout $BuildRoot
if (-not $EngineRoot) { $EngineRoot = $env:LEAPGATE_ENGINE_ROOT }
if (-not $EngineRoot) { $EngineRoot = Join-Path $L.Root 'engine' }
if ($Test) { $Steps += 'test' }
if ($Install) { $Steps += 'install' }
New-Item -ItemType Directory -Force $EngineRoot, $L.Logs | Out-Null
$log = Join-Path $L.Logs "$(Get-Date -Format yyyyMMdd-HHmmss)-engine.log"

$dt = Join-Path $EngineRoot 'depot_tools'
$src = Join-Path $EngineRoot 'flutter'
$srcRoot = Join-Path $src 'engine\src'
$releaseOut = Join-Path $srcRoot 'out\host_release'
$buildStamp = Join-Path $releaseOut 'leapgate-build.json'
$patchDir = Join-Path $PSScriptRoot 'engine-patches'
$cache = Join-Path $L.Flutter 'bin\cache\artifacts\engine\windows-x64-release'
$backup = Join-Path $L.Root "engine-official\flutter-$($LeapgatePins.Flutter)-windows-x64-release"
$manifestPath = Join-Path $cache 'leapgate-engine.json'
# flutter_tools 从缓存拷进应用的就是这几个（packages/flutter_tools/lib/src/build_system/targets/windows.dart）
$engineFiles = 'flutter_windows.dll', 'flutter_windows.dll.exp', 'flutter_windows.dll.lib', 'flutter_windows.dll.pdb'

# depot_tools 和引擎脚本要的进程内环境；depot_tools 不在运行时悄悄自更新（它钉在 env.ps1 的提交上）
$env:PATH = "$dt;$env:PATH"
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:DEPOT_TOOLS_UPDATE = '0'

function Get-Sha256([string]$Path) { (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

# 序号和名字都要一致；RVA 每次编译都会变
function Get-DllExports([string]$Dll) {
    $readobj = Join-Path $L.Llvm 'bin\llvm-readobj.exe'
    $lines = & $readobj --coff-exports $Dll
    if ($LASTEXITCODE -ne 0) { throw "llvm-readobj 读不了 $Dll" }
    $exports = @()
    $ordinal = $null
    foreach ($line in $lines) {
        if ($line -match '^\s*Ordinal: (\d+)') { $ordinal = $Matches[1] }
        elseif ($line -match '^\s*Name: (.+)$') { $exports += "$ordinal $($Matches[1])" }
    }
    if (-not $exports) { throw "$Dll 没有导出表" }
    $exports
}

# 官方原件：装过就在备份目录，没装过就在 SDK 缓存里
function Get-OfficialEngineDir {
    if (Test-Path (Join-Path $backup 'flutter_windows.dll')) { return $backup }
    if (Test-Path $manifestPath) { throw "SDK 缓存里装的是自编引擎，但备份目录没有官方原件：$backup" }
    $cache
}

# 引擎的 VS 探测只认 Community/Professional/Enterprise 的默认目录，要显式告诉它。
# ATL 是 AXPlatformNodeWin 要的；Installer 里装的 ATL 可能是带版本号的组件（VC.14.xx.ATL），
# vswhere 按组件 ID 查不准，直接看 vcvarsall 默认用的那版 MSVC 里有没有 atlbase.h
function Set-VisualStudioEnv {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vsPath = & $vswhere -latest -products * -version '[17.0,18.0)' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsPath) { throw 'VS 2022 缺"MSVC v143 x64/x86 生成工具"，用 Visual Studio Installer 加上（要管理员权限）' }
    $msvc = (Get-Content (Join-Path $vsPath 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
    $atl = Join-Path $vsPath "VC\Tools\MSVC\$msvc\atlmfc\include\atlbase.h"
    if (-not (Test-Path $atl)) {
        throw "VS 2022 的 MSVC $msvc 缺 C++ ATL（没有 $atl）：在 Visual Studio Installer 里给这版生成工具加上 ATL（要管理员权限）"
    }
    $dbghelp = "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\dbghelp.dll"
    if (-not (Test-Path $dbghelp)) { throw "缺 Windows SDK 的 Debugging Tools for Windows：$dbghelp" }
    $env:vs2022_install = $vsPath
}

# tools/gn 每次都重写 args.gn；engine_version 它取检出的 HEAD（3.44.9 标签那个提交），
# 官方产物里记的是 engine.version，改成后者，dll 里的引擎版本号和官方一致
function Invoke-EngineGn([string[]]$GnArgs, [string]$OutDir) {
    Invoke-Logged $log python3 (@((Join-Path $srcRoot 'flutter\tools\gn')) + $GnArgs + @('--no-goma', '--no-rbe'))
    $argsFile = Join-Path $OutDir 'args.gn'
    $content = Get-Content $argsFile -Raw
    $pattern = '(?m)^engine_version = "[0-9a-f]*"(?=\r?$)'
    if ($content -notmatch $pattern) { throw "$argsFile 里找不到 engine_version 这一行，tools/gn 的输出格式变了" }
    Set-Content $argsFile ($content -replace $pattern, "engine_version = `"$($LeapgatePins.FlutterEngine)`"") -NoNewline
    Invoke-Logged $log (Join-Path $srcRoot 'flutter\third_party\gn\gn.exe') @('gen', $OutDir)
}

function Format-PatchList($List) { ($List | ForEach-Object { "$($_.name) $($_.sha256)" }) -join "`n" }

# 编出来的必须正好是标签加这几份补丁：改动的文件集合和补丁涉及的一致、没有未跟踪的文件，
# 这些文件的内容也和"HEAD 打上全部补丁"一致（在临时索引里打补丁再和工作区比）。
# 之前的去 ATL 临时桩就是检出里多出来的改动，清单却只列了补丁
function Assert-CheckoutIsPatchedTag {
    $expected = @($patches | ForEach-Object { & git -C $src apply --numstat (Join-Path $patchDir $_.name) } |
        ForEach-Object { ($_ -split "`t")[2] } | Sort-Object -Unique)
    $status = @(& git -C $src status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw "git status 失败：$src" }
    $actual = @($status | ForEach-Object { $_.Substring(3) } | Sort-Object -Unique)
    $diff = Compare-Object $expected $actual
    if ($diff) {
        throw "检出 $src 的改动和补丁涉及的文件不一致（<= 补丁有、检出没改；=> 检出多出来的）：`n$($diff | Out-String)"
    }
    $env:GIT_INDEX_FILE = Join-Path ([System.IO.Path]::GetTempPath()) "leapgate-engine-index-$PID"
    try {
        & git -C $src read-tree HEAD
        if ($LASTEXITCODE -ne 0) { throw "git read-tree 失败：$src" }
        foreach ($p in $patches) {
            & git -C $src apply --cached (Join-Path $patchDir $p.name)
            if ($LASTEXITCODE -ne 0) { throw "补丁在标签上打不上：$($p.name)" }
        }
        & git -C $src diff --quiet -- @expected
        if ($LASTEXITCODE -ne 0) { throw "检出 $src 里补丁涉及的文件和标签加补丁的结果不一致" }
    } finally {
        Remove-Item $env:GIT_INDEX_FILE -ErrorAction Ignore
        Remove-Item Env:GIT_INDEX_FILE
    }
}

# 自编 dll 只认和自己同一 Dart 源码编出的 AOT 快照；客户端用的是 SDK 缓存里的官方 gen_snapshot，
# 两者的快照哈希不一致时 app.so 会被拒绝加载，比导出表看不出来
function Assert-SnapshotHashMatches {
    $versionCc = Join-Path $releaseOut 'gen\flutter\third_party\dart\runtime\version.cc'
    if ((Get-Content $versionCc -Raw) -notmatch 'snapshot_hash_ = "([0-9a-f]{32})"') { throw "$versionCc 里找不到快照哈希" }
    $hash = $Matches[1]
    foreach ($bin in (Join-Path $releaseOut 'flutter_windows.dll'), (Join-Path $cache 'gen_snapshot.exe')) {
        $text = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($bin))
        if (-not $text.Contains($hash)) { throw "$bin 里没有 Dart 快照哈希 $hash：自编引擎和缓存里的 gen_snapshot 不兼容" }
    }
    Write-Host "Dart 快照哈希 $hash 和缓存里的 gen_snapshot 一致" -ForegroundColor Green
}

# ---- checkout ----
if ('checkout' -in $Steps) {
    if (-not (Test-Path $dt)) {
        Invoke-Logged $log git @('clone', 'https://chromium.googlesource.com/chromium/tools/depot_tools.git', $dt)
        Invoke-Logged $log git @('-C', $dt, 'checkout', '--quiet', $LeapgatePins.DepotTools)
    }
    if (-not (Test-Path $src)) {
        Invoke-Logged $log git @('clone', '--depth', '1', '--branch', $LeapgatePins.Flutter,
            'https://github.com/flutter/flutter.git', $src)
    }
    Invoke-Logged $log git @('-C', $src, 'config', 'core.longpaths', 'true')
    $gclient = Join-Path $src '.gclient'
    if (-not (Test-Path $gclient)) {
        # 只编 Windows 引擎，不要 DEPS 默认下载的 JDK（Android 才用）
        $content = (Get-Content (Join-Path $src 'engine\scripts\standard.gclient') -Raw) -replace
            '("custom_deps": \{\},)', "`$1`n    `"custom_vars`": {`"download_jdk`": False},"
        Set-Content $gclient $content -NoNewline
    }
}
$head = (& git -C $src rev-parse HEAD).Trim()
if ($head -ne $LeapgatePins.FlutterCommit) {
    throw "$src 检出的是 $head，不是 $($LeapgatePins.Flutter) 标签的 $($LeapgatePins.FlutterCommit)"
}
$engineVersion = (Get-Content (Join-Path $src 'bin\internal\engine.version') -Raw).Trim()
if ($engineVersion -ne $LeapgatePins.FlutterEngine) {
    throw "$src 的 engine.version 是 $engineVersion，不是 env.ps1 钉住的 $($LeapgatePins.FlutterEngine)"
}

# ---- sync ----
if ('sync' -in $Steps) {
    # 戳放在检出的 .git 里：删掉检出重新克隆时戳跟着没了，也不会出现在 git status 里
    $stamp = Join-Path $src '.git\leapgate-gclient-sync.stamp'
    if ($ForceSync -or -not (Test-Path $stamp) -or (Get-Content $stamp -Raw).Trim() -ne $engineVersion) {
        Push-Location $src
        try { Invoke-Logged $log (Join-Path $dt 'gclient.bat') @('sync', '-D', '--no-history') } finally { Pop-Location }
        Set-Content $stamp $engineVersion
    } else {
        Write-Host "gclient sync 已对 $engineVersion 跑过，跳过（-ForceSync 可强制）"
    }
}

# ---- patch ----
$patches = @(Get-LeapgateEnginePatches)
if (-not $patches) { throw "没有补丁：$patchDir" }
if ('patch' -in $Steps) {
    foreach ($p in $patches) {
        $file = Join-Path $patchDir $p.name
        & git -C $src apply --reverse --check $file 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "已打过：$($p.name)"
            continue
        }
        # 既不能反向应用也不能正向应用，就是检出里有别的改动或补丁只打了一半
        Invoke-Logged $log git @('-C', $src, 'apply', '--check', $file)
        Invoke-Logged $log git @('-C', $src, 'apply', $file)
    }
}

# ---- build ----
if ('build' -in $Steps) {
    Assert-CheckoutIsPatchedTag
    Set-VisualStudioEnv
    # 构建失败时不留下旧戳
    Remove-Item $buildStamp -ErrorAction Ignore
    Push-Location $srcRoot
    try {
        Invoke-EngineGn @('--runtime-mode', 'release', '--no-lto') $releaseOut
        Invoke-Logged $log ninja @('-C', $releaseOut, '-j', $Jobs, 'flutter/shell/platform/windows:flutter_windows')
    } finally { Pop-Location }
    foreach ($f in $engineFiles) {
        if (-not (Test-Path (Join-Path $releaseOut $f))) { throw "产物缺少 $f：$releaseOut" }
    }
    # 补丁不该动公开 API；导出表不一致说明补丁或构建参数有问题，不能拿去替换
    $official = Join-Path (Get-OfficialEngineDir) 'flutter_windows.dll'
    $diff = Compare-Object (Get-DllExports $official) (Get-DllExports (Join-Path $releaseOut 'flutter_windows.dll'))
    if ($diff) { throw "导出表和官方 $official 不一致：`n$($diff | Out-String)" }
    Write-Host "flutter_windows.dll 导出表和官方一致" -ForegroundColor Green
    Assert-SnapshotHashMatches
    [ordered]@{
        engine_commit = $engineVersion
        built_at      = (Get-Date).ToString('o')
        patches       = $patches
        files         = @($engineFiles | ForEach-Object { [ordered]@{ name = $_; sha256 = Get-Sha256 (Join-Path $releaseOut $_) } })
    } | ConvertTo-Json -Depth 4 | Set-Content $buildStamp
}

# ---- test ----
if ('test' -in $Steps) {
    Set-VisualStudioEnv
    $debugOut = Join-Path $srcRoot 'out\host_debug_unopt'
    Push-Location $srcRoot
    try {
        Invoke-EngineGn @('--runtime-mode', 'debug', '--unoptimized') $debugOut
        Invoke-Logged $log ninja @('-C', $debugOut, '-j', $Jobs,
            'flutter/shell/platform/common:common_cpp_unittests', 'flutter/shell/platform/windows:flutter_windows_unittests')
    } finally { Pop-Location }
    # 补丁 2 改了 clear_current，补丁 1 在引擎上投递任务切换语义开关，所以 Windows 的单测也全跑。
    # 只排除两个按"低功耗 GPU"选显卡的用例：机器上有多块显卡（含虚拟显示适配器）时，ANGLE 选的和
    # GetLowPowerGpuLuid 给的不是同一块，不打补丁也一样失败（2026-10-26 在维护者台式机上对比过）
    Invoke-Logged $log (Join-Path $debugOut 'common_cpp_unittests.exe')
    Invoke-Logged $log (Join-Path $debugOut 'flutter_windows_unittests.exe') @('--gtest_filter=-WindowsTest.*GraphicsAdapterWithLowPowerPreference')
}

# ---- install ----
if ('install' -in $Steps) {
    # 只装 build 步骤核对过、且就是用当前补丁编的产物
    if (-not (Test-Path $buildStamp)) { throw "没有产物戳 $buildStamp：先跑 build" }
    $built = Get-Content $buildStamp -Raw | ConvertFrom-Json
    if ($built.engine_commit -ne $engineVersion) { throw "产物是按引擎提交 $($built.engine_commit) 编的，不是 $engineVersion：重跑 build" }
    if ((Format-PatchList $built.patches) -ne (Format-PatchList $patches)) {
        throw "产物是用别的补丁编的（engine-patches\ 在 build 之后改过）：重跑 build"
    }
    foreach ($f in $built.files) {
        if ((Get-Sha256 (Join-Path $releaseOut $f.name)) -ne $f.sha256) { throw "$($f.name) 在 build 之后变过：重跑 build" }
    }
    if (-not (Test-Path (Join-Path $backup 'flutter_windows.dll'))) {
        $officialDir = Get-OfficialEngineDir
        New-Item -ItemType Directory -Force $backup | Out-Null
        foreach ($f in $engineFiles) { Copy-Item (Join-Path $officialDir $f) $backup }
        Write-Host "官方原件已备份到 $backup"
    }
    foreach ($f in $engineFiles) { Copy-Item (Join-Path $releaseOut $f) $cache -Force }
    [ordered]@{
        flutter         = $LeapgatePins.Flutter
        engine_commit   = $engineVersion
        installed_at    = (Get-Date).ToString('o')
        official_backup = $backup
        patches         = $built.patches
        files           = $built.files
    } | ConvertTo-Json -Depth 4 | Set-Content $manifestPath
    $dllHash = Assert-LeapgateEngine $L
    Write-Host "自编引擎已装进 $cache（flutter_windows.dll $dllHash），清单 $manifestPath" -ForegroundColor Green
}
