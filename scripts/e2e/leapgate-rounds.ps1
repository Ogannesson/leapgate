<#
.SYNOPSIS
  Connection rounds for contract 05 §6.4, run on the controlling endpoint, and the report that
  classifies them against the server's ice_result rows and the controlled side's log.

.DESCRIPTION
  Run (the default) does rounds -From..-To against -PeerId through leapgate-e2e.ps1 and appends
  one JSON line per round to -Evidence\rounds.jsonl. Run it again with the next -From to continue
  the same evidence (step 8 stops at rounds 10 and 50 so the controlled side's Stats can be taken).

    normal round  connect; wait until the session logs in (with -PasswordFile) or the connection
                  reports a result; keep it -HoldMin..-HoldMax seconds; close the session window
    cancel round  every -CancelEvery-th round: stop this endpoint -CancelAfterMs after the session
                  starts, while ICE is still running, then start it again and wait -RestartWaitSec
                  (the heartbeat has to bring ice back into the capability cache). Closing the
                  window would not cancel: the connection being set up runs to its end first.

  Each round prints a provisional class from this endpoint's log alone.

  -Report classifies every round in rounds.jsonl and writes -Evidence\report.txt. It reads, when
  present in -Evidence:
    ice_result.txt   the server's rows as id|at_ms|b_id|outcome|elapsed_ms|local_kind|remote_kind|
                     family|local_net, from at least the first round's start
    peer-log.txt     the controlled side's Logs output (pattern 'leapgate ice:' at least) over the
                     run; a cancel round counts as confirmed only when it shows "agent timed out",
                     which needs the controlled side started with Start -TraceIce
    peer-stats-*.txt the controlled side's Stats output, copied into the report as is

  Classes: ice-selected (log line and a matching connected row), upstream-direct-won,
  ice-lost-relay-window ("lost the relay window" line and an abandoned row; "(no log line)" when
  only the row and the upstream relay show it), ice-failed, no-ice
  (no ICE line and no row: ICE did not start), mismatch, unclassified; for cancel rounds
  cancel-confirmed, cancel-too-late (ICE was selected), cancel-too-early (no row: the OFFER never
  reached the server), cancel-dropped (the controlled side dropped the FORWARD), cancel-unconfirmed.
#>
[CmdletBinding()]
param(
    [string]$Evidence,
    [string]$Dir,
    [string]$PeerId,
    [int]$From = 1,
    [int]$To = 5,
    [string]$PasswordFile,
    [int]$CancelEvery = 0,
    [int]$CancelAfterMs = 1300,
    [int]$HoldMin = 10,
    [int]$HoldMax = 20,
    [int]$ResultTimeoutSec = 30,
    [int]$RestartWaitSec = 12,
    [switch]$InTask,
    [switch]$Report,
    [string]$Script = (Join-Path $PSScriptRoot 'leapgate-e2e.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

if (-not $Evidence) { throw '-Evidence is required' }
$roundsFile = Join-Path $Evidence 'rounds.jsonl'
$TsRe = [regex]'\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{6} [+-]\d\d:\d\d)\]'

# ConvertFrom-Json turns ISO strings into DateTime on PowerShell 7.
function Get-Ms($Value) {
    if ($Value -is [datetime]) { ([DateTimeOffset]$Value).ToUnixTimeMilliseconds() }
    else { [DateTimeOffset]::Parse($Value).ToUnixTimeMilliseconds() }
}

function Get-LineMs([string]$Line) {
    $m = $TsRe.Match($Line)
    if (-not $m.Success) { return $null }
    [DateTimeOffset]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss.ffffff zzz',
        [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds()
}

# $Rows $null means the server was not checked; $Peer $null means the controlled side was not.
function Get-Class($Rec, $Rows, $Peer) {
    $txt = @($Rec.lines) -join "`n"
    $sel = [regex]::Match($txt, 'leapgate ice: selected (\w+)/v(\d)/(\w+) <-> (\w+)/v\d in (\d+) ms')
    $fail = [regex]::Match($txt, 'leapgate ice: (no direct path \(\w+\)|rejected \(\w+\)|signaling failed)')
    $lost = $txt -match 'leapgate ice: lost the relay window after \d+ ms'
    $direct = $txt -match 'used to establish IPv6 connection|LAN candidate .* won'
    $relay = $txt -match 'used to establish Relay connection'
    $outcomes = @(if ($null -ne $Rows) { $Rows | ForEach-Object { $_.outcome } })
    if ($Rec.cancel) {
        if ($sel.Success) { return 'cancel-too-late' }
        if ($null -eq $Rows) { return 'cancel (server not checked)' }
        if (-not $outcomes.Count) { return 'cancel-too-early' }
        if ($outcomes -notcontains 'abandoned') { return 'unclassified' }
        if ($null -eq $Peer) { return 'cancel (peer not checked)' }
        if ($Peer -match 'agent timed out') { return 'cancel-confirmed' }
        if ($Peer -match 'dropped a forwarded offer') { return 'cancel-dropped' }
        return 'cancel-unconfirmed'
    }
    if ($sel.Success) {
        if ($null -eq $Rows) { return 'ice-selected (server not checked)' }
        $c = @($Rows | Where-Object { $_.outcome -eq 'connected' })
        $g = $sel.Groups
        if ($c.Count -eq 1 -and $c[0].elapsed -eq $g[5].Value -and $c[0].local_kind -eq $g[1].Value -and
            $c[0].family -eq $g[2].Value -and $c[0].local_net -eq $g[3].Value -and $c[0].remote_kind -eq $g[4].Value) {
            return 'ice-selected'
        }
        return 'mismatch'
    }
    if ($fail.Success) { return "ice-failed: $($fail.Groups[1].Value)" }
    if ($null -eq $Rows) {
        if ($lost) { return 'ice-lost-relay-window (server not checked)' }
        return $(if ($direct) { 'upstream-direct-won (server not checked)' } else { 'no ICE line (server not checked)' })
    }
    if (-not $outcomes.Count) { return $(if ($lost) { 'mismatch' } else { 'no-ice' }) }
    if (($outcomes -join ',') -eq 'abandoned') {
        if ($lost) { return 'ice-lost-relay-window' }
        if ($direct) { return 'upstream-direct-won' }
        # Builds before the log line (client e321ccf9e) said nothing when ICE lost the window.
        if ($relay) { return 'ice-lost-relay-window (no log line)' }
    }
    if ($lost) { return 'mismatch' }
    'unclassified'
}

function Invoke-Report {
    $recs = @(Get-Content -LiteralPath $roundsFile | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    $recs = @($recs | Sort-Object { Get-Ms $_.start })
    $starts = @($recs | ForEach-Object { Get-Ms $_.start })
    # An event belongs to the last round that started before it (1 s of slack for clock offsets).
    $owner = {
        param([long]$Ms)
        $k = -1
        for ($j = 0; $j -lt $starts.Count; $j++) { if ($starts[$j] -le $Ms + 1000) { $k = $j } }
        $k
    }
    $rowsBy = $null
    $iceFile = Join-Path $Evidence 'ice_result.txt'
    if (Test-Path -LiteralPath $iceFile) {
        $rowsBy = @{}
        foreach ($l in Get-Content -LiteralPath $iceFile) {
            $f = $l.Split('|')
            if ($f.Count -lt 9) { continue }
            $k = & $owner ([long]$f[1])
            if ($k -lt 0 -or $f[2] -ne $recs[$k].peer) { continue }
            if (-not $rowsBy.ContainsKey($k)) { $rowsBy[$k] = [Collections.Generic.List[object]]::new() }
            $rowsBy[$k].Add([pscustomobject]@{
                id = $f[0]; outcome = $f[3]; elapsed = $f[4]; local_kind = $f[5]; remote_kind = $f[6]
                family = $f[7]; local_net = $f[8]
            })
        }
    }
    $peerBy = $null
    $peerFile = Join-Path $Evidence 'peer-log.txt'
    if (Test-Path -LiteralPath $peerFile) {
        $peerBy = @{}
        foreach ($l in Get-Content -LiteralPath $peerFile) {
            $ms = Get-LineMs $l
            if ($null -eq $ms -or $l -notmatch 'leapgate ice:') { continue }
            $k = & $owner $ms
            if ($k -lt 0) { continue }
            if (-not $peerBy.ContainsKey($k)) { $peerBy[$k] = [Collections.Generic.List[string]]::new() }
            $peerBy[$k].Add(($l -replace '^\S+ ', ''))
        }
    }
    $out = [Collections.Generic.List[string]]::new()
    $out.Add("report of $roundsFile at $([DateTimeOffset]::Now.ToString('o'))")
    $out.Add("server rows: $(if ($null -ne $rowsBy) { 'ice_result.txt' } else { 'not checked' }); peer log: $(if ($null -ne $peerBy) { 'peer-log.txt' } else { 'not checked' })")
    $counts = [ordered]@{}
    for ($k = 0; $k -lt $recs.Count; $k++) {
        $r = $recs[$k]
        # The comma keeps an empty array from unrolling to $null, which would read as "not checked".
        $rows = if ($null -eq $rowsBy) { $null } elseif ($rowsBy.ContainsKey($k)) { @($rowsBy[$k]) } else { , @() }
        $peer = if ($null -eq $peerBy) { $null } elseif ($peerBy.ContainsKey($k)) { @($peerBy[$k]) -join "`n" } else { '' }
        $cls = Get-Class $r $rows $peer
        $counts[$cls] = 1 + $(if ($counts.Contains($cls)) { $counts[$cls] } else { 0 })
        $ice = (@($r.lines) | Where-Object { $_ -match 'leapgate ice:' } | ForEach-Object { $_ -replace '^.*leapgate ice: ', '' }) -join ' / '
        $rowText = if ($null -eq $rows) { '-' } else { (@($rows) | ForEach-Object { "#$($_.id) $($_.outcome) $($_.elapsed) $($_.local_kind)/$($_.remote_kind)/$($_.family)/$($_.local_net)" }) -join '; ' }
        $at = [DateTimeOffset]::FromUnixTimeMilliseconds($starts[$k]).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss.fff')
        $re = if ($r.PSObject.Properties['restarted'] -and $r.restarted) { '(main program restarted first) ' } else { '' }
        $out.Add("R$($r.round) $at $re$(if ($r.cancel) { 'cancel' } else { 'normal' }) $cls login=$($r.login) | A: $ice | server: $rowText")
        if ($r.cancel) { $out.Add("    A: $(@($r.connect) -join ' / ')") }
        if ($peer) { foreach ($p in $peer -split "`n") { $out.Add("    B: $p") } }
    }
    $out.Add('')
    $out.Add('counts: ' + (($counts.Keys | ForEach-Object { "$_ $($counts[$_])" }) -join ', '))
    foreach ($f in Get-ChildItem -LiteralPath $Evidence -Filter 'peer-stats-*.txt' | Sort-Object Name) {
        $out.Add('')
        $out.Add("$($f.Name):")
        foreach ($l in Get-Content -LiteralPath $f.FullName) { if ($l.Trim()) { $out.Add("    $l") } }
    }
    $out | Set-Content -LiteralPath (Join-Path $Evidence 'report.txt') -Encoding utf8
    $out
}

function Get-Lines([DateTimeOffset]$Since, [string[]]$Pattern) {
    $a = @{ Action = 'Logs'; Since = $Since.ToString('o') }
    if ($Pattern) { $a.Pattern = $Pattern }
    @(& $Script @a | ForEach-Object { if ($_.Length -gt 300) { $_.Substring(0, 300) + '...' } else { $_ } })
}

function Invoke-Rounds {
    foreach ($n in 'Dir', 'PeerId') { if (-not (Get-Variable $n -ValueOnly)) { throw "-$n is required" } }
    New-Item -ItemType Directory -Force $Evidence | Out-Null
    $task = @{}
    if ($InTask) { $task.InTask = $true }
    $waitFor = if ($PasswordFile) { 'handle_peer_info' } else { 'leapgate ice: |used to establish' }
    $exe = [IO.Path]::GetFullPath((Join-Path $Dir 'leapgate.exe'))
    $first = [DateTimeOffset]::Now
    "rounds R$From..R$To from $($first.ToString('o')) (unix ms $($first.ToUnixTimeMilliseconds()))"
    for ($i = $From; $i -le $To; $i++) {
        $cancel = $CancelEvery -gt 0 -and $i % $CancelEvery -eq 0
        # With the main program gone (it can crash), --connect finds no window to hand over to and
        # runs the session in a process of its own, and a cancel round watches a log nobody writes.
        $restarted = -not @(Get-Process -Name leapgate -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -and [string]::Equals($_.Path, $exe, [StringComparison]::OrdinalIgnoreCase) }).Count
        if ($restarted) {
            & $Script -Action Start -Dir $Dir @task | Out-Null
            Start-Sleep -Seconds $RestartWaitSec
        }
        $start = [DateTimeOffset]::Now
        $c = @{ Action = 'Connect'; Dir = $Dir; PeerId = $PeerId }
        if ($PasswordFile) { $c.PasswordFile = $PasswordFile }
        if ($cancel) { $c.CancelAfterMs = $CancelAfterMs }
        $connect = @(& $Script @c @task)
        if ($cancel) {
            & $Script -Action Start -Dir $Dir @task | Out-Null
            Start-Sleep -Seconds $RestartWaitSec
        } else {
            $deadline = $start.AddSeconds($ResultTimeoutSec)
            while ([DateTimeOffset]::Now -lt $deadline -and -not @(Get-Lines $start @($waitFor)).Count) { Start-Sleep -Seconds 1 }
            Start-Sleep -Seconds (Get-Random -Minimum $HoldMin -Maximum ($HoldMax + 1))
            & $Script -Action CloseSessions -Dir $Dir @task | Out-Null
            Start-Sleep -Seconds 3
        }
        $lines = @(Get-Lines $start)
        $login = @($lines -match 'handle_peer_info').Count -gt 0
        $rec = [ordered]@{
            round = $i; cancel = $cancel; restarted = $restarted; peer = $PeerId; start = $start.ToString('o')
            end = [DateTimeOffset]::Now.ToString('o'); login = $login; connect = $connect; lines = $lines
        }
        Add-Content -LiteralPath $roundsFile -Encoding utf8 -Value ($rec | ConvertTo-Json -Compress -Depth 3)
        $ice = ($lines | Where-Object { $_ -match 'leapgate ice:' } | ForEach-Object { $_ -replace '^.*leapgate ice: ', '' }) -join ' / '
        "R$i $($start.ToString('HH:mm:ss')) $(if ($restarted) { '(main program was gone, restarted) ' })$(if ($cancel) { 'cancel' } else { 'normal' }) $(Get-Class ([pscustomobject]$rec) $null $null) login=$login :: $ice"
    }
}

if ($Report) { Invoke-Report } else { Invoke-Rounds }
