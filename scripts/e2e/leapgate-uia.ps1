<#
.SYNOPSIS
  Finds and drives controls of the new Leapgate UI (leapgate_ui) through UI Automation, by the
  semantics label each control carries (its visible text, or the icon's name), for unattended
  end-to-end runs (docs/新界面/04-M2a拆法.md §6.3).

.DESCRIPTION
  One operation per call. The window is the main window (class LEAPGATE_UI_MAIN) of the process
  whose image is -Dir\leapgate.exe; the semantics tree hangs under its FLUTTERVIEW child.

    Dump     list the elements (index, control type, name, patterns, bounds); -Match filters lines
    Wait     wait up to -TimeoutSec for an element named -Name (or matching -NameMatch); prints it
    Gone     wait up to -TimeoutSec until no element is named -Name (or matches -NameMatch)
    Invoke   InvokePattern on the element (buttons, rows, menu items)
    Toggle   TogglePattern (check boxes, switches)
    Focus    SetFocus on the element
    SetValue ValuePattern.SetValue with -ValueFile's content (first line); the value is never printed
    Type     focus the element, bring the window to the front and type -ValueFile's content with
             SendKeys (for fields whose ValuePattern is read-only); the value is never printed
    Keys     bring the window to the front and send -Keys (SendKeys syntax, e.g. '{ENTER}')
    Click    bring the window to the front and click the middle of the element with the mouse

  As of the M2a acceptance (2026-10-31) the new UI's semantics tree comes up empty on the route C engine
  (only the window and FLUTTERVIEW are visible), so this script finds nothing yet; leapgate-post-input.ps1
  with screenshot coordinates is what the runs use until that is fixed.

  Use it only on builds with the route C engine (patched accessibility bridge): with the official
  engine a UI Automation client may crash the controlling side (flutter#193588).

  A password is only ever passed as a file path (-ValueFile).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Dump', 'Wait', 'Gone', 'Invoke', 'Toggle', 'Focus', 'SetValue', 'Type', 'Keys', 'Click')]
    [string]$Op,
    [Parameter(Mandatory)][string]$Dir,
    [string]$WindowClass = 'LEAPGATE_UI_MAIN',
    [string]$Name,
    [string]$NameMatch,
    [int]$Index = 0,
    [string]$Match,
    [string]$ValueFile,
    [string]$Keys,
    [int]$TimeoutSec = 15
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
if (-not ('LeapgateUia.Win' -as [type])) {
    Add-Type -Namespace LeapgateUia -Name Win -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, System.UIntPtr e);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
}
[void][LeapgateUia.Win]::SetProcessDPIAware()
$A = [Windows.Automation.AutomationElement]

function Get-MainWindow {
    $exe = [IO.Path]::GetFullPath((Join-Path $Dir 'leapgate.exe'))
    $pids = @(Get-Process -Name leapgate -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and [string]::Equals($_.Path, $exe, [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object Id)
    if (-not $pids.Count) { throw "no process runs $exe" }
    $found = [Collections.Generic.List[IntPtr]]::new()
    $cb = [LeapgateUia.Win+EnumProc] {
        param($h, $l)
        $wpid = [uint32]0
        [void][LeapgateUia.Win]::GetWindowThreadProcessId($h, [ref]$wpid)
        if ($pids -contains [int]$wpid) {
            $c = [Text.StringBuilder]::new(256)
            [void][LeapgateUia.Win]::GetClassName($h, $c, 256)
            if ($c.ToString() -eq $WindowClass) { $found.Add($h) }
        }
        $true
    }
    [void][LeapgateUia.Win]::EnumWindows($cb, [IntPtr]::Zero)
    if (-not $found.Count) { throw "no window of class $WindowClass in process(es) $($pids -join ',')" }
    $found[0]
}

# Flutter builds its semantics tree only once an accessibility client shows up, so the first query
# can come back nearly empty; ask again for a few seconds.
function Get-Elements([IntPtr]$hwnd) {
    for ($t = 0; $t -lt 12; $t++) {
        $win = $A::FromHandle($hwnd)
        $view = $win.FindFirst('Children', [Windows.Automation.Condition]::TrueCondition)
        $root = if ($view -and $view.Current.NativeWindowHandle) { $A::FromHandle([IntPtr]$view.Current.NativeWindowHandle) } else { $win }
        $all = @($root.FindAll('Descendants', [Windows.Automation.Condition]::TrueCondition))
        if ($all.Count -gt 3) { break }
        Start-Sleep -Milliseconds 700
    }
    $all
}

function Format-Element($e, [int]$i) {
    $c = $e.Current
    $pats = ($e.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName -replace 'PatternIdentifiers.Pattern', '' }) -join ','
    $r = $c.BoundingRectangle
    $state = @()
    if (-not $c.IsEnabled) { $state += 'disabled' }
    if ($c.HasKeyboardFocus) { $state += 'focused' }
    '{0,4} {1} "{2}" [{3}] {4} @{5},{6} {7}x{8}' -f $i, $c.ControlType.ProgrammaticName.Replace('ControlType.', ''),
    ($c.Name -replace "`r?`n", ' / '), $pats, ($state -join ','), [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height
}

function Test-Hit($e) {
    $n = $e.Current.Name
    if ($Name) { return $n -eq $Name }
    if ($NameMatch) { return $n -match $NameMatch }
    throw '-Name or -NameMatch is required'
}

function Find-Target([IntPtr]$hwnd) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $hits = @(Get-Elements $hwnd | Where-Object { Test-Hit $_ })
        if ($hits.Count -gt $Index) { return $hits[$Index] }
        if ((Get-Date) -gt $deadline) { throw "no element '$Name$NameMatch' (#$Index) within $TimeoutSec s; found $($hits.Count)" }
        Start-Sleep -Milliseconds 500
    }
}

function Read-Value {
    if (-not $ValueFile) { throw '-ValueFile is required' }
    ([IO.File]::ReadAllLines($ValueFile) | Select-Object -First 1).Trim()
}

function Escape-SendKeys([string]$s) { [regex]::Replace($s, '[+^%~(){}\[\]]', { param($m) '{' + $m.Value + '}' }) }

$hwnd = Get-MainWindow
switch ($Op) {
    'Dump' {
        $all = @(Get-Elements $hwnd)
        for ($i = 0; $i -lt $all.Count; $i++) {
            $line = Format-Element $all[$i] $i
            if (-not $Match -or $line -match $Match) { $line }
        }
    }
    'Wait' { Format-Element (Find-Target $hwnd) $Index }
    'Gone' {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while (@(Get-Elements $hwnd | Where-Object { Test-Hit $_ }).Count) {
            if ((Get-Date) -gt $deadline) { throw "'$Name$NameMatch' still there after $TimeoutSec s" }
            Start-Sleep -Milliseconds 500
        }
        "gone: '$Name$NameMatch'"
    }
    'Invoke' { $e = Find-Target $hwnd; $e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); "invoked '$($e.Current.Name)'" }
    'Toggle' { $e = Find-Target $hwnd; $e.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle(); "toggled '$($e.Current.Name)'" }
    'Focus' { $e = Find-Target $hwnd; $e.SetFocus(); "focused '$($e.Current.Name)'" }
    'SetValue' { $e = Find-Target $hwnd; $e.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue((Read-Value)); "set the value of '$($e.Current.Name)'" }
    'Type' {
        $e = Find-Target $hwnd
        [void][LeapgateUia.Win]::SetForegroundWindow($hwnd); Start-Sleep -Milliseconds 300
        $e.SetFocus(); Start-Sleep -Milliseconds 200
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.SendKeys]::SendWait((Escape-SendKeys (Read-Value)))
        "typed into '$($e.Current.Name)'"
    }
    'Keys' {
        if (-not $Keys) { throw '-Keys is required' }
        [void][LeapgateUia.Win]::SetForegroundWindow($hwnd); Start-Sleep -Milliseconds 300
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.SendKeys]::SendWait($Keys)
        "sent keys $Keys"
    }
    'Click' {
        $e = Find-Target $hwnd
        [void][LeapgateUia.Win]::SetForegroundWindow($hwnd); Start-Sleep -Milliseconds 300
        $r = $e.Current.BoundingRectangle
        $x = [int]($r.X + $r.Width / 2); $y = [int]($r.Y + $r.Height / 2)
        [void][LeapgateUia.Win]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 100
        [LeapgateUia.Win]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); [LeapgateUia.Win]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
        "clicked '$($e.Current.Name)' at $x,$y"
    }
}
