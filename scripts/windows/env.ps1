#Requires -Version 7.0
# Porta Windows 客户端构建链的公共部分：钉住的版本、目录布局、进程内环境。
# 由 setup-toolchain.ps1 和 build-client.ps1 点源（. "$PSScriptRoot\env.ps1"），不单独运行。
# 依据：docs/research/第二期客户端/03-Windows构建链方案.md（方案 B：官方 Flutter 3.44.9 + 上游源码补丁脚本）。

$ErrorActionPreference = 'Stop'

$PortaPins = @{
    # 不用浮动的 stable；合并上游后再评估要不要升
    Rust          = '1.99.1'
    Flutter       = '3.44.9'
    # 来自官方发布清单 releases_windows.json
    FlutterSha256 = '8ef1107d226654736755bc51b969d6bd46787ff0241650f942e774fb0ca7d0ac'
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

function Get-PortaLayout {
    param([string]$BuildRoot)
    if (-not $BuildRoot) { $BuildRoot = $env:PORTA_BUILD_ROOT }
    if (-not $BuildRoot) { $BuildRoot = 'C:\porta-build' }
    @{
        Root        = $BuildRoot
        Downloads   = Join-Path $BuildRoot 'downloads'
        Logs        = Join-Path $BuildRoot 'logs'
        Flutter     = Join-Path $BuildRoot "flutter-$($PortaPins.Flutter)"
        Llvm        = Join-Path $BuildRoot "llvm-$($PortaPins.Llvm)"
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
function Set-PortaBuildEnv {
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

    $env:RUSTUP_TOOLCHAIN = $PortaPins.Rust
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
