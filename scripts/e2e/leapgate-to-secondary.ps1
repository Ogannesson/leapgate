<#
.SYNOPSIS
  Moves a test window onto the secondary monitor without activating it, so unattended end-to-end runs
  stay out of the way of someone using the primary monitor. Keeps the window's size and Z order.
.PARAMETER Class
  Window class to look for (default: the new UI's main window, LEAPGATE_UI_MAIN).
.PARAMETER ProcessId
  Move every visible top-level window of this process instead (for windows without a known class,
  such as the connection manager or a legacy-UI window).
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File leapgate-to-secondary.ps1
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File leapgate-to-secondary.ps1 -ProcessId 1234
#>
param([string]$Class = 'LEAPGATE_UI_MAIN', [int]$ProcessId = 0)
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class LgToSecondary {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  public static List<IntPtr> OfProcess(uint pid) {
    var r = new List<IntPtr>();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) r.Add(h); return true; }, IntPtr.Zero);
    return r;
  }
}
'@
# Per-monitor aware before anything reads screen geometry, so every coordinate below is physical.
[void][LgToSecondary]::SetProcessDpiAwarenessContext([IntPtr]-4)
Add-Type -AssemblyName System.Windows.Forms
$second = [System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary } | Select-Object -First 1
if (-not $second) { 'no secondary monitor; window left where it is'; return }
$x = $second.WorkingArea.X + 120
$y = $second.WorkingArea.Y + 120
$windows = if ($ProcessId) {
  [LgToSecondary]::OfProcess([uint32]$ProcessId)
} else {
  @([LgToSecondary]::FindWindow($Class, $null)) | Where-Object { $_ -ne [IntPtr]::Zero }
}
if (-not $windows) { "no window (class $Class, process $ProcessId)"; return }
foreach ($h in $windows) {
  # SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
  $ok = [LgToSecondary]::SetWindowPos($h, [IntPtr]::Zero, $x, $y, 0, 0, 0x0001 -bor 0x0004 -bor 0x0010)
  "moved $h to $x,$y : $ok"
}
