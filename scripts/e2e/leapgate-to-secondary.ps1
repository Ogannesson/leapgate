<#
.SYNOPSIS
  Keeps test windows off the primary monitor during unattended end-to-end runs on a machine someone
  may be using. A window of a matched process that sits on the primary monitor is moved to the same
  place on the secondary monitor, without activating it and without changing its size.
.DESCRIPTION
  The new UI creates its main window hidden and shows it a moment later, centered on the monitor
  under the mouse; the connection manager is a separate process that places itself at the top right
  of the primary monitor. So start -Watch before launching anything: it catches each window while it
  is still hidden, and the window then first appears on the secondary monitor.
  Only top-level windows whose class starts with LEAPGATE_UI_ (new UI) or FLUTTER_ (legacy UI) count.
  A window is moved at most 5 times, so a window that keeps putting itself back is left alone.
.PARAMETER Dir
  Match processes whose executable is in this folder (the build under test). Covers the main
  window, the connection manager and any later window of that build.
.PARAMETER ProcessId
  Match this one process instead.
.PARAMETER Watch
  Keep watching (every 150 ms) until -Minutes have passed; without it, one pass and exit.
.PARAMETER Minutes
  How long -Watch runs (default 240).
.EXAMPLE
  # before launching the build under test (run it in the background):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File leapgate-to-secondary.ps1 -Dir C:\builds\app -Watch
  # one pass over windows that are already open:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File leapgate-to-secondary.ps1 -Dir C:\builds\app
#>
param([string]$Dir = '', [int]$ProcessId = 0, [switch]$Watch, [int]$Minutes = 240)
if (-not $Dir -and -not $ProcessId) { 'give -Dir or -ProcessId'; exit 2 }
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text; using System.Collections.Generic;
public static class LgToSecondary {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, uint flags, StringBuilder s, ref uint n);

  static readonly Dictionary<uint, string> paths = new Dictionary<uint, string>();
  static readonly Dictionary<IntPtr, int> moves = new Dictionary<IntPtr, int>();

  static string PathOf(uint pid) {
    string p;
    if (paths.TryGetValue(pid, out p)) return p;
    p = "";
    IntPtr h = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
    if (h != IntPtr.Zero) {
      var sb = new StringBuilder(1024); uint n = 1024;
      if (QueryFullProcessImageName(h, 0, sb, ref n)) p = sb.ToString();
      CloseHandle(h);
    }
    paths[pid] = p;
    return p;
  }

  // One pass. pri/sec are the monitors' bounds, secWork the secondary's work area, all physical.
  public static List<string> Pass(string dir, uint onlyPid, RECT pri, RECT sec, RECT secWork) {
    var log = new List<string>();
    EnumWindows((h, l) => {
      if (GetWindow(h, 4) != IntPtr.Zero) return true; // GW_OWNER: skip owned popups
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (onlyPid != 0 ? pid != onlyPid
          : !PathOf(pid).StartsWith(dir, StringComparison.OrdinalIgnoreCase)) return true;
      var sb = new StringBuilder(256); GetClassName(h, sb, 256); var cls = sb.ToString();
      if (!cls.StartsWith("LEAPGATE_UI_") && !cls.StartsWith("FLUTTER_")) return true;
      RECT r; if (!GetWindowRect(h, out r)) return true;
      int cx = (r.L + r.R) / 2, cy = (r.T + r.B) / 2;
      if (cx < pri.L || cx >= pri.R || cy < pri.T || cy >= pri.B) return true;
      int done; moves.TryGetValue(h, out done);
      if (done >= 5) return true;
      int w = r.R - r.L, ht = r.B - r.T;
      int x = Math.Max(secWork.L, Math.Min(r.L + sec.L - pri.L, secWork.R - w));
      int y = Math.Max(secWork.T, Math.Min(r.T + sec.T - pri.T, secWork.B - ht));
      bool ok = SetWindowPos(h, IntPtr.Zero, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010); // NOSIZE|NOZORDER|NOACTIVATE
      moves[h] = done + 1;
      log.Add(String.Format("{0:HH:mm:ss.fff} moved pid={1} {2} {3},{4} -> {5},{6} : {7}", DateTime.Now, pid, cls, r.L, r.T, x, y, ok));
      return true;
    }, IntPtr.Zero);
    return log;
  }
}
'@
# Per-monitor aware before anything reads geometry, so every coordinate is physical.
[void][LgToSecondary]::SetProcessDpiAwarenessContext([IntPtr]-4)
Add-Type -AssemblyName System.Windows.Forms
$screens = [System.Windows.Forms.Screen]::AllScreens
$pri = $screens | Where-Object Primary | Select-Object -First 1
$sec = $screens | Where-Object { -not $_.Primary } | Select-Object -First 1
if (-not $sec) { 'no secondary monitor; windows left where they are'; exit 0 }
function Rect($b) { $r = New-Object LgToSecondary+RECT; $r.L = $b.Left; $r.T = $b.Top; $r.R = $b.Right; $r.B = $b.Bottom; $r }
$priR = Rect $pri.Bounds; $secR = Rect $sec.Bounds; $secW = Rect $sec.WorkingArea
if ($Dir) { $Dir = [IO.Path]::GetFullPath($Dir).TrimEnd('\') + '\' }
$deadline = (Get-Date).AddMinutes($Minutes)
do {
  [LgToSecondary]::Pass($Dir, [uint32]$ProcessId, $priR, $secR, $secW)
  if ($Watch) { Start-Sleep -Milliseconds 150 }
} while ($Watch -and (Get-Date) -lt $deadline)
