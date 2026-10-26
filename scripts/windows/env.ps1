#Requires -Version 7.0
# Leapgate Windows 客户端构建链的公共部分：钉住的版本、目录布局、进程内环境。
# 由 setup-toolchain.ps1、build-client.ps1、build-engine.ps1 点源（. "$PSScriptRoot\env.ps1"），不单独运行。
# 依据：docs/research/第二期客户端/03-Windows构建链方案.md（方案 B：官方 Flutter 3.44.9 + 上游源码补丁脚本；
# 2026-10-26 起走路线 C：同一个 Flutter，换成自编并打了补丁的 flutter_windows.dll，见 build-engine.ps1）。

$ErrorActionPreference = 'Stop'

$LeapgatePins = @{
    # 不用浮动的 stable；合并上游后再评估要不要升
    Rust          = '1.99.1'
    Flutter       = '3.44.9'
    # 来自官方发布清单 releases_windows.json
    FlutterSha256 = '8ef1107d226654736755bc51b969d6bd46787ff0241650f942e774fb0ca7d0ac'
    # 3.44.9 的 bin\internal\engine.version；build-engine.ps1 自编引擎时核对，并作为 dll 里记的引擎版本
    FlutterEngine = '5a2a6a42cce67f965cf540fcecf616faca624aa1'
    # 3.44.9 标签指向的提交；build-engine.ps1 核对引擎检出的 HEAD
    FlutterCommit = '6b182d2c7585eba26d4edce0f97630effd256c33'
    # build-engine.ps1 第一次克隆 depot_tools 后检出这个提交（2026-10-26 编引擎时用的那版），之后不自更新
    DepotTools    = 'faceefec3fab70643e950caad40fded806877988'
    # 和上游 CI 的 LLVM_VERSION 一致：hwcodec、magnum-opus 用的 bindgen 0.59 配 libclang 16+ 有已知问题
    Llvm          = '15.0.6'
    # 上游不发安装包的校验和，这是 2026-10-22 第一次从 GitHub release 下载时记下的
    LlvmSha256    = '22e2f2c38be4c44db7a1e9da5e67de2a453c5b4be9cf91e139592a63877ac0a2'
    # 必须等于客户端 vcpkg.json 的 builtin-baseline，build-client.ps1 会核对
    VcpkgCommit   = '9e593bb18ea69cc5095e012465dcd675a822ed0d'
    # 和上游 bridge.yml 一致
    FrbCodegen    = '1.80.1'
    CargoExpand   = '1.0.95'
}

function Get-LeapgateLayout {
    param([string]$BuildRoot)
    if (-not $BuildRoot) { $BuildRoot = $env:LEAPGATE_BUILD_ROOT }
    if (-not $BuildRoot) { $BuildRoot = 'C:\leapgate-build' }
    @{
        Root        = $BuildRoot
        Downloads   = Join-Path $BuildRoot 'downloads'
        Logs        = Join-Path $BuildRoot 'logs'
        Flutter     = Join-Path $BuildRoot "flutter-$($LeapgatePins.Flutter)"
        Llvm        = Join-Path $BuildRoot "llvm-$($LeapgatePins.Llvm)"
        Vcpkg       = Join-Path $BuildRoot 'vcpkg'
        VcpkgCache  = Join-Path $BuildRoot 'vcpkg-cache'
        CargoTools  = Join-Path $BuildRoot 'cargo-tools'
        PubCache    = Join-Path $BuildRoot 'pub-cache'
    }
}

function Get-GitRoot {
    # git --exec-path 形如 C:/Program Files/Git/mingw64/libexec/git-core
    $execPath = (& git --exec-path).Trim()
    Split-Path (Split-Path (Split-Path $execPath -Parent) -Parent) -Parent
}

# 进程内环境，不写系统或用户环境变量。
# PATH 用白名单重建：机器上常有 MinGW 的 cmake/ninja/gcc、Git 的 usr\bin（自带一个 link.exe）、
# 其他版本的 ffmpeg 等，会被 vcpkg 的端口脚本或 cargo 误用。VS 由各工具自己用 vswhere 找，不需要开发者环境。
function Set-LeapgateBuildEnv {
    param([hashtable]$Layout)

    $python = Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1
    if (-not $python) { throw '找不到 python.exe（需要 Python 3.10+，WindowsApps 里的占位程序不算）' }
    $pythonDir = Split-Path $python.Source -Parent
    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $HOME '.cargo' }
    $gitRoot = Get-GitRoot
    $sys = $env:SystemRoot

    $env:PATH = @(
        (Join-Path $Layout.Flutter 'bin'),
        (Join-Path $Layout.CargoTools 'bin'),
        (Join-Path $cargoHome 'bin'),
        $pythonDir,
        (Join-Path $pythonDir 'Scripts'),
        (Join-Path $gitRoot 'cmd'),
        $PSHOME,
        "$sys\System32",
        $sys,
        "$sys\System32\Wbem",
        "$sys\System32\WindowsPowerShell\v1.0",
        "$sys\System32\OpenSSH"
    ) -join ';'

    $env:RUSTUP_TOOLCHAIN = $LeapgatePins.Rust
    $env:LIBCLANG_PATH = Join-Path $Layout.Llvm 'bin'
    $env:PUB_CACHE = $Layout.PubCache
    $env:VCPKG_ROOT = $Layout.Vcpkg
    $env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
    $env:VCPKG_BINARY_SOURCES = "clear;files,$($Layout.VcpkgCache),readwrite"
    $env:VCPKG_DISABLE_METRICS = '1'

    # vcpkg 用 WinHTTP 下载；代理绕过列表里有 IPv6 字面量（如 ::1）时 WinHttpOpen 报 0x57 参数错误
    if ($env:NO_PROXY) {
        $env:NO_PROXY = ($env:NO_PROXY -split ',' | Where-Object { $_ -notmatch ':' }) -join ','
    }

    @{ GitBash = Join-Path $gitRoot 'bin\bash.exe' }
}

# engine-patches\ 下的补丁，按文件名排序，带 SHA256。build-engine.ps1 写进产物戳和清单，
# Assert-LeapgateEngine 拿它和清单比。.gitattributes 让 *.patch 不做换行转换，SHA256 在各处检出里一致
function Get-LeapgateEnginePatches {
    @(Get-ChildItem (Join-Path $PSScriptRoot 'engine-patches\*.patch') | Sort-Object Name | ForEach-Object {
        [ordered]@{ name = $_.Name; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
}

# SDK 缓存里的引擎是不是 build-engine.ps1 -Install 用当前补丁、钉住的引擎提交装的自编版：
# 清单的引擎提交、补丁列表要和现在的一致，缓存里每个文件的 SHA256 要和清单一致。
# 是就返回 flutter_windows.dll 的 SHA256，不是就抛错说明原因
function Assert-LeapgateEngine {
    param([hashtable]$Layout)
    $dir = Join-Path $Layout.Flutter 'bin\cache\artifacts\engine\windows-x64-release'
    $manifestPath = Join-Path $dir 'leapgate-engine.json'
    if (-not (Test-Path $manifestPath)) { throw "没有清单 $manifestPath" }
    $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($m.engine_commit -ne $LeapgatePins.FlutterEngine) {
        throw "清单里的引擎提交 $($m.engine_commit) 不是 env.ps1 钉住的 $($LeapgatePins.FlutterEngine)"
    }
    $format = { param($List) ($List | ForEach-Object { "$($_.name) $($_.sha256)" }) -join "`n" }
    if ((& $format $m.patches) -ne (& $format @(Get-LeapgateEnginePatches))) {
        throw "清单里的补丁和 engine-patches\ 不一致（补丁改过之后没有重跑 build-engine.ps1 -Install）"
    }
    foreach ($f in $m.files) {
        $hash = (Get-FileHash (Join-Path $dir $f.name) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $f.sha256) { throw "$($f.name) 的哈希 $hash 和清单 $manifestPath 不符" }
    }
    ($m.files | Where-Object name -eq 'flutter_windows.dll').sha256
}

# 跑一个外部命令，输出同时写日志；退出码非 0 就抛错。
function Invoke-Logged {
    param(
        [Parameter(Mandatory)][string]$Log,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    "`n>>> $FilePath $($ArgumentList -join ' ')" | Tee-Object -FilePath $Log -Append | Out-Host
    & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $Log -Append | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "命令失败（退出码 $LASTEXITCODE）：$FilePath $($ArgumentList -join ' ')；日志 $Log" }
}
