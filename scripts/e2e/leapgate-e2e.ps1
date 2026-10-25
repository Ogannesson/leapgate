<#
.SYNOPSIS
  Drives one Leapgate portable endpoint for unattended end-to-end runs (contract 05 §6.4).

.DESCRIPTION
  One action per call. Everything that differs between machines (paths, server, key, peer ID,
  password) is a parameter; nothing here names a real host.

    Deploy         unpack -Zip into -Dir (stops this deployment's processes first)
    Configure      stop, back up %APPDATA%\Leapgate\config once to -BackupDir\original, then write
                   -Server/-Key/-ApiServer, -Option (Leapgate2.toml [options]), -LocalOption
                   (Leapgate_local.toml [options]), -Proxy ([socks]) and -Password (permanent
                   password, Leapgate.toml). An empty value removes the entry.
    Start          start the portable main program (resident; it also runs the controlled side)
    GetId          print this endpoint's ID
    Connect        leapgate.exe --connect -PeerId [--password -Password]
    CloseSessions  post WM_CLOSE to this deployment's windows except the main window
    Stop           kill every process whose image is -Dir\leapgate.exe (nothing else)
    Logs           log lines from -Since (and before -Until) that match -Pattern
    Stats          handles, threads and private bytes of this deployment's processes
    Restore        stop, then put -BackupDir\original back as the config directory

  -InTask runs the same call through a one-off scheduled task in the interactive session and
  prints its output. Use it where the caller must not start Leapgate itself (for example a
  packaged app whose child processes get a redirected %APPDATA%).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Deploy', 'Configure', 'Start', 'GetId', 'Connect', 'CloseSessions', 'Stop', 'Logs', 'Stats', 'Restore')]
    [string]$Action,
    [string]$Dir,
    [string]$Zip,
    [string]$Server,
    [string]$Key,
    [string]$ApiServer,
    [hashtable]$Option = @{},
    [hashtable]$LocalOption = @{},
    [string]$Proxy,
    [string]$Password,
    [string]$BackupDir,
    [string]$PeerId,
    [string]$Since,
    [string]$Until,
    [string[]]$Pattern,
    [switch]$InTask,
    [string]$TaskWorkDir,
    [int]$TaskTimeoutSec = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

$DefaultPatterns = @(
    'leapgate ice:'
    'Session \S+ start'
    'used to establish'
    'LAN candidate'
    'Hole Punched'
    'punch hole'
    'secure_connection ok'
    'request relay'
    'create_relay'
    'Connection opened from'
    'Connection closed'
    'Exit io_loop'
    'handle_peer_info'
)

function Need([string]$Name) {
    if (-not (Get-Variable $Name -ValueOnly)) { throw "-$Name is required for -Action $Action" }
}

function Get-Exe { Join-Path $Dir 'leapgate.exe' }

function Get-OwnProcess {
    $exe = [IO.Path]::GetFullPath((Get-Exe))
    Get-Process -Name leapgate -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and [string]::Equals($_.Path, $exe, [StringComparison]::OrdinalIgnoreCase) }
}

function Stop-Own {
    $p = @(Get-OwnProcess)
    if ($p.Count) {
        $p | Stop-Process -Force
        $p | ForEach-Object { $_.WaitForExit(10000) | Out-Null }
    }
    "stopped $($p.Count) process(es)"
}

function Get-ConfigDir { Join-Path $env:APPDATA 'Leapgate\config' }

function Format-TomlValue([string]$Value) {
    if ($Value -match "['\r\n]") { throw "value must not contain a single quote or a line break" }
    "'$Value'"
}

# Sets or removes keys in one table of a small TOML file. $Table '' is the top level.
# A $null or '' value removes the key; -DropTable removes the whole table.
function Set-TomlEntries([string]$Path, [string]$Table, [System.Collections.IDictionary]$Values, [switch]$DropTable) {
    $lines = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Path) {
        foreach ($l in [IO.File]::ReadAllLines($Path)) { $lines.Add($l) }
    }
    $isHeader = { param($l) $l -match '^\s*\[' }
    if ($Table) {
        $start = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s*\[$([regex]::Escape($Table))\]\s*$") { $start = $i; break }
        }
        if ($start -lt 0) {
            if ($DropTable) { return }
            if ($lines.Count -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
            $lines.Add("[$Table]")
            $start = $lines.Count - 1
        }
        $bodyStart = $start + 1
    } else {
        $start = -1
        $bodyStart = 0
    }
    $end = $bodyStart
    while ($end -lt $lines.Count -and -not (& $isHeader $lines[$end])) {
        # skip over a multi-line literal so its content is never taken for a header
        if ($lines[$end] -match "=\s*'''" -and ($lines[$end] -split "'''").Count -lt 3) {
            $end++
            while ($end -lt $lines.Count -and $lines[$end] -notmatch "'''") { $end++ }
        }
        $end++
    }
    if ($DropTable) {
        $from = if ($start -ge 0) { $start } else { $bodyStart }
        $lines.RemoveRange($from, $end - $from)
    } else {
        $keep = [Collections.Generic.List[string]]::new()
        $i = $bodyStart
        while ($i -lt $end) {
            $l = $lines[$i]
            $hit = $false
            foreach ($k in $Values.Keys) {
                if ($l -match "^\s*`"?$([regex]::Escape($k))`"?\s*=") { $hit = $true; break }
            }
            if ($hit -and $l -match "=\s*'''" -and ($l -split "'''").Count -lt 3) {
                $i++
                while ($i -lt $end -and $lines[$i] -notmatch "'''") { $i++ }
            } elseif (-not $hit) {
                $keep.Add($l)
            }
            $i++
        }
        foreach ($k in ($Values.Keys | Sort-Object)) {
            $v = $Values[$k]
            if ($null -ne $v -and "$v" -ne '') { $keep.Insert(0, "$k = $(Format-TomlValue "$v")") }
        }
        $lines.RemoveRange($bodyStart, $end - $bodyStart)
        $lines.InsertRange($bodyStart, $keep)
    }
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}

function Backup-Config {
    if (-not $BackupDir) { return }
    $orig = Join-Path $BackupDir 'original'
    if ((Test-Path -LiteralPath $orig) -or (Test-Path -LiteralPath "$orig.absent")) { return }
    New-Item -ItemType Directory -Force $BackupDir | Out-Null
    $cfg = Get-ConfigDir
    if (Test-Path -LiteralPath $cfg) {
        Copy-Item -LiteralPath $cfg -Destination $orig -Recurse
        "backed up $cfg to $orig"
    } else {
        Set-Content -LiteralPath "$orig.absent" -Value (Get-Date -Format o)
        "no config yet; recorded $orig.absent"
    }
}

function Invoke-Configure {
    Stop-Own
    Backup-Config
    $cfg = Get-ConfigDir
    $opts = [ordered]@{}
    if ($Bound.ContainsKey('Server')) { $opts['custom-rendezvous-server'] = $Server }
    if ($Bound.ContainsKey('Key')) { $opts['key'] = $Key }
    if ($Bound.ContainsKey('ApiServer')) { $opts['api-server'] = $ApiServer }
    foreach ($k in $Option.Keys) { $opts[$k] = $Option[$k] }
    if ($opts.Count) { Set-TomlEntries (Join-Path $cfg 'Leapgate2.toml') 'options' $opts }
    if ($Proxy) {
        Set-TomlEntries (Join-Path $cfg 'Leapgate2.toml') 'socks' ([ordered]@{ proxy = $Proxy; username = $null; password = $null })
    } elseif ($Bound.ContainsKey('Proxy')) {
        Set-TomlEntries (Join-Path $cfg 'Leapgate2.toml') 'socks' @{} -DropTable
    }
    if ($LocalOption.Count) { Set-TomlEntries (Join-Path $cfg 'Leapgate_local.toml') 'options' $LocalOption }
    if ($Bound.ContainsKey('Password')) {
        # A plain value is read as a legacy permanent password; the program keeps it as is.
        Set-TomlEntries (Join-Path $cfg 'Leapgate.toml') '' @{ password = $Password }
    }
    $shown = @($opts.Keys) + @($LocalOption.Keys | ForEach-Object { "local:$_" })
    if ($Bound.ContainsKey('Proxy')) { $shown += 'socks' }
    if ($Bound.ContainsKey('Password')) { $shown += 'password' }
    "configured: $($shown -join ', ')"
}

function Invoke-Restore {
    Need 'BackupDir'
    Stop-Own
    $cfg = Get-ConfigDir
    $orig = Join-Path $BackupDir 'original'
    $aside = "$cfg.e2e-$(Get-Date -Format yyyyMMdd-HHmmss)"
    if (Test-Path -LiteralPath $orig) {
        if (Test-Path -LiteralPath $cfg) { Move-Item -LiteralPath $cfg -Destination $aside }
        Copy-Item -LiteralPath $orig -Destination $cfg -Recurse
        "restored $cfg from $orig (test config kept at $aside)"
    } elseif (Test-Path -LiteralPath "$orig.absent") {
        if (Test-Path -LiteralPath $cfg) { Move-Item -LiteralPath $cfg -Destination $aside }
        "there was no config before; test config moved to $aside"
    } else {
        throw "no backup in $BackupDir"
    }
}

function Invoke-Logs {
    Need 'Since'
    $from = [DateTimeOffset]::Parse($Since)
    $to = if ($Until) { [DateTimeOffset]::Parse($Until) } else { [DateTimeOffset]::MaxValue }
    $re = [regex](($(if ($Pattern) { $Pattern } else { $DefaultPatterns }) | ForEach-Object { "(?:$_)" }) -join '|')
    $root = Join-Path $env:APPDATA 'Leapgate\log'
    if (-not (Test-Path -LiteralPath $root)) { return }
    # No LastWriteTime filter: Windows does not move it while the logger keeps the file open.
    $files = Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.log
    $out = foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length + 1)
        $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            $sr = [IO.StreamReader]::new($fs)
            while ($null -ne ($l = $sr.ReadLine())) {
                if ($l.Length -lt 36 -or $l[0] -ne '[') { continue }
                $ts = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParseExact($l.Substring(1, 33), 'yyyy-MM-dd HH:mm:ss.ffffff zzz',
                        [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$ts)) { continue }
                if ($ts -lt $from -or $ts -ge $to -or -not $re.IsMatch($l)) { continue }
                [pscustomobject]@{ At = $ts; Line = "$rel $l" }
            }
        } finally { $fs.Dispose() }
    }
    $out | Sort-Object At | ForEach-Object Line
}

function Invoke-Stats {
    foreach ($p in @(Get-OwnProcess)) {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)").CommandLine
        $exeArgs = if ($cmd -match '^\s*("[^"]*"|\S+)\s*(.*)$') { $Matches[2] } else { '' }
        [pscustomobject]@{
            Pid          = $p.Id
            Args         = $exeArgs
            Handles      = $p.HandleCount
            Threads      = $p.Threads.Count
            PrivateBytes = $p.PrivateMemorySize64
        }
    }
}

function Invoke-CloseSessions {
    if (-not ('LeapgateE2e.Win' -as [type])) {
        Add-Type -Namespace LeapgateE2e -Name Win -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
'@
    }
    $pids = @(Get-OwnProcess | ForEach-Object Id)
    $wins = [Collections.Generic.List[object]]::new()
    $cb = [LeapgateE2e.Win+EnumProc] {
        param($h, $l)
        $wpid = [uint32]0
        [LeapgateE2e.Win]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null
        if ($pids -contains [int]$wpid -and [LeapgateE2e.Win]::IsWindowVisible($h)) {
            $t = [Text.StringBuilder]::new(256); $c = [Text.StringBuilder]::new(256)
            [LeapgateE2e.Win]::GetWindowText($h, $t, 256) | Out-Null
            [LeapgateE2e.Win]::GetClassName($h, $c, 256) | Out-Null
            $wins.Add([pscustomobject]@{ Handle = $h; Title = $t.ToString(); Class = $c.ToString() })
        }
        $true
    }
    [LeapgateE2e.Win]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    # Session windows are the multi-window plugin's; the main window is the Flutter runner's.
    # A closed session window stays visible for a moment, so wait a few seconds before checking again.
    foreach ($w in $wins) {
        if ($w.Class -ne 'RustdeskMultiWindow') { "kept '$($w.Title)' ($($w.Class))"; continue }
        [LeapgateE2e.Win]::PostMessage($w.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        "closed '$($w.Title)' ($($w.Class))"
    }
}

function Invoke-InTask {
    Need 'Dir'
    $work = if ($TaskWorkDir) { $TaskWorkDir } else { Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($Dir))) 'task' }
    New-Item -ItemType Directory -Force $work | Out-Null
    $tag = 'leapgate-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $argsFile = Join-Path $work "$tag.args.xml"
    $launcher = Join-Path $work "$tag.ps1"
    $outFile = Join-Path $work "$tag.out"
    $doneFile = Join-Path $work "$tag.done"
    $p = @{}
    foreach ($k in $Bound.Keys) {
        if ($k -notin 'InTask', 'TaskWorkDir', 'TaskTimeoutSec') { $p[$k] = $Bound[$k] }
    }
    $p | Export-Clixml -LiteralPath $argsFile
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    Set-Content -LiteralPath $launcher -Encoding utf8 -Value @"
`$code = 0
try {
    `$p = Import-Clixml -LiteralPath $(& $q $argsFile)
    & $(& $q $PSCommandPath) @p *> $(& $q $outFile)
} catch {
    `$_ | Out-String | Add-Content -LiteralPath $(& $q $outFile)
    `$code = 1
}
Set-Content -LiteralPath $(& $q $doneFile) -Value `$code
"@
    $pwsh = (Get-Process -Id $PID).Path
    $tr = "`"$pwsh`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`""
    if ($tr.Length -gt 261) { throw "task command is $($tr.Length) characters, over the 261 limit; use a shorter -TaskWorkDir" }
    try {
        $o = schtasks /create /tn $tag /tr $tr /sc once /st 23:59 /it /f 2>&1
        if ($LASTEXITCODE) { throw "schtasks /create failed: $o" }
        $o = schtasks /run /tn $tag 2>&1
        if ($LASTEXITCODE) { throw "schtasks /run failed: $o" }
        $deadline = (Get-Date).AddSeconds($TaskTimeoutSec)
        while (-not (Test-Path -LiteralPath $doneFile)) {
            if ((Get-Date) -gt $deadline) { throw "task $tag did not finish within $TaskTimeoutSec s" }
            Start-Sleep -Milliseconds 300
        }
    } finally {
        schtasks /delete /tn $tag /f 2>&1 | Out-Null
    }
    $code = (Get-Content -LiteralPath $doneFile -Raw).Trim()
    if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile }
    Remove-Item -LiteralPath $argsFile, $launcher, $outFile, $doneFile -ErrorAction SilentlyContinue
    if ($code -ne '0') { throw "task $tag failed" }
}

$Bound = $PSBoundParameters

if ($InTask) { Invoke-InTask; return }

switch ($Action) {
    'Deploy' {
        Need 'Dir'; Need 'Zip'
        if (Test-Path -LiteralPath $Dir) { Stop-Own }
        Expand-Archive -LiteralPath $Zip -DestinationPath $Dir -Force
        "deployed $Zip to $Dir"
    }
    'Configure' { Need 'Dir'; Invoke-Configure }
    'Start' {
        Need 'Dir'
        $p = Start-Process -FilePath (Get-Exe) -WorkingDirectory $Dir -PassThru
        "started pid $($p.Id)"
    }
    'GetId' {
        Need 'Dir'
        $tmp = [IO.Path]::GetTempFileName()
        try {
            Start-Process -FilePath (Get-Exe) -ArgumentList '--get-id' -WorkingDirectory $Dir -Wait -NoNewWindow -RedirectStandardOutput $tmp
            (Get-Content -LiteralPath $tmp -Raw).Trim()
        } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    }
    'Connect' {
        Need 'Dir'; Need 'PeerId'
        $a = @('--connect', $PeerId)
        if ($Password) { $a += @('--password', $Password) }
        Start-Process -FilePath (Get-Exe) -ArgumentList $a -WorkingDirectory $Dir | Out-Null
        "connect $PeerId requested at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')"
    }
    'CloseSessions' { Need 'Dir'; Invoke-CloseSessions }
    'Stop' { Need 'Dir'; Stop-Own }
    'Logs' { Invoke-Logs }
    'Stats' { Need 'Dir'; Invoke-Stats | Format-Table -AutoSize | Out-String -Width 200 }
    'Restore' { Need 'Dir'; Invoke-Restore }
}
