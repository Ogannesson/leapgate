<#
.SYNOPSIS
  Sends mouse clicks, key presses and typed text to a Leapgate window by posting window messages to its
  Flutter view, without moving the real cursor or taking the keyboard, for unattended end-to-end runs
  on a machine someone may be using (docs/新界面/04-M2a拆法.md §6.3).

.DESCRIPTION
  The window is the first visible top-level window of class -WindowClass owned by the process whose image
  is -Dir\leapgate.exe (LEAPGATE_UI_MAIN for the new UI; FLUTTER_RUNNER_WIN32_WINDOW for the upstream UI's
  main window, or pass another class). Coordinates are in pixels of a PrintWindow capture of that top-level
  window (as leapgate-shot-style captures produce them, per-monitor DPI aware), so they can be read off a
  screenshot; they are turned into the Flutter view's client coordinates here.

    Click     -X -Y: mouse move, left button down and up
    Move      -X -Y: mouse move only (hover)
    Key       -Key: one virtual key (Enter, Escape, Tab, Down, Up, Back, Delete, Space, or a VK number),
              key down then key up; -Hold leaves it down, -Release only sends the key up
    Text      the first line of -ValueFile, one WM_CHAR per character (the value is never printed)

  A password is only ever passed as a file path (-ValueFile).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Click', 'Move', 'Key', 'Text')][string]$Op,
    [Parameter(Mandatory)][string]$Dir,
    [string]$WindowClass = 'LEAPGATE_UI_MAIN',
    [int]$X, [int]$Y,
    [string]$Key,
    [switch]$Hold,
    [switch]$Release,
    [string]$ValueFile
)
$ErrorActionPreference = 'Stop'
if (-not ('LeapgatePost.Win' -as [type])) {
    Add-Type -Namespace LeapgatePost -Name Win -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumChildWindows(System.IntPtr p, EnumProc f, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr h, ref POINT p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c, uint t);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
}
[void][LeapgatePost.Win]::SetProcessDPIAware()
$exe = [IO.Path]::GetFullPath((Join-Path $Dir 'leapgate.exe'))
$pids = @(Get-Process leapgate -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | ForEach-Object Id)
if (-not $pids.Count) { throw "no process runs $exe" }
$script:top = [IntPtr]::Zero
[void][LeapgatePost.Win]::EnumWindows([LeapgatePost.Win+EnumProc] {
        param($h, $l)
        $p = [uint32]0; [void][LeapgatePost.Win]::GetWindowThreadProcessId($h, [ref]$p)
        $c = [Text.StringBuilder]::new(256); [void][LeapgatePost.Win]::GetClassName($h, $c, 256)
        if ($script:top -eq [IntPtr]::Zero -and $pids -contains [int]$p -and $c.ToString() -eq $WindowClass -and [LeapgatePost.Win]::IsWindowVisible($h)) { $script:top = $h }
        $true
    }, [IntPtr]::Zero)
if ($script:top -eq [IntPtr]::Zero) { throw "no visible window of class $WindowClass" }
$script:view = $script:top
[void][LeapgatePost.Win]::EnumChildWindows($script:top, [LeapgatePost.Win+EnumProc] {
        param($h, $l)
        $c = [Text.StringBuilder]::new(256); [void][LeapgatePost.Win]::GetClassName($h, $c, 256)
        if ($c.ToString() -eq 'FLUTTERVIEW') { $script:view = $h; return $false }
        $true
    }, [IntPtr]::Zero)
$h = $script:view

function Post([uint32]$m, [long]$w, [long]$l) { [void][LeapgatePost.Win]::PostMessage($h, $m, [IntPtr]$w, [IntPtr]$l) }
function Get-LParamXY {
    $r = New-Object LeapgatePost.Win+RECT; [void][LeapgatePost.Win]::GetWindowRect($script:top, [ref]$r)
    $o = New-Object LeapgatePost.Win+POINT; [void][LeapgatePost.Win]::ClientToScreen($h, [ref]$o)
    $cx = $r.L + $X - $o.X; $cy = $r.T + $Y - $o.Y
    ($cy -shl 16) -bor ($cx -band 0xffff)
}
$vk = @{ Enter = 0x0D; Escape = 0x1B; Tab = 0x09; Down = 0x28; Up = 0x26; Left = 0x25; Right = 0x27; Back = 0x08; Delete = 0x2E; Space = 0x20; Shift = 0x10; Control = 0x11; A = 0x41 }

switch ($Op) {
    'Move' { Post 0x0200 0 (Get-LParamXY); "moved to $X,$Y" }
    'Click' {
        $lp = Get-LParamXY
        Post 0x0200 0 $lp; Start-Sleep -Milliseconds 80
        Post 0x0201 1 $lp; Start-Sleep -Milliseconds 60
        Post 0x0202 0 $lp
        "clicked $X,$Y"
    }
    'Key' {
        $code = if ($vk.ContainsKey($Key)) { $vk[$Key] } else { [int]$Key }
        $scan = [LeapgatePost.Win]::MapVirtualKey($code, 0)
        $down = 1 -bor ($scan -shl 16); $up = $down -bor (3 -shl 30)
        if (-not $Release) { Post 0x0100 $code $down }
        if ($code -eq 0x0D -and -not $Release) { Post 0x0102 0x0D $down }
        if (-not $Hold) { Start-Sleep -Milliseconds 60; Post 0x0101 $code $up }
        "key $Key$(if ($Hold) { ' down' } elseif ($Release) { ' up' })"
    }
    'Text' {
        if (-not $ValueFile) { throw '-ValueFile is required' }
        $v = ([IO.File]::ReadAllLines($ValueFile) | Select-Object -First 1).Trim()
        foreach ($ch in $v.ToCharArray()) { Post 0x0102 ([int]$ch) 1; Start-Sleep -Milliseconds 30 }
        "typed $($v.Length) characters"
    }
}
