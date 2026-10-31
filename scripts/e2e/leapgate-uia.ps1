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

  It talks to the native COM IUIAutomation, the API Inspect and Narrator use. System.Windows.Automation
  does not see the Flutter tree at all: it shows FLUTTERVIEW as a plain Win32 pane with no children, and a
  window it queried right after start may then stay empty for COM clients too. So this script never loads
  it, and finds FLUTTERVIEW with EnumChildWindows (docs/新界面/无障碍语义树为空排查.md §9.3).

  It needs the route C engine with patch 0003: without 0003 the new UI's semantics tree stays empty, and
  with the official engine a UI Automation client may crash the controlling side (flutter#193588).

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
if (-not ('LeapgateUia.Win' -as [type])) {
    Add-Type -Namespace LeapgateUia -Name Win -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumChildWindows(System.IntPtr p, EnumProc f, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, System.UIntPtr e);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
}
# Only the slots up to the last method used are declared; the vtable order is UIAutomationClient.h's.
# C# 5: Windows PowerShell compiles this with the .NET Framework compiler.
if (-not ('LeapgateUia.Com' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace LeapgateUia {
[ComImport, Guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IUIAutomation {
    void CompareElements(); void CompareRuntimeIds(); void GetRootElement();
    [PreserveSig] int ElementFromHandle(IntPtr hwnd, out IUIAutomationElement element);
    void ElementFromPoint(); void GetFocusedElement(); void GetRootElementBuildCache();
    void ElementFromHandleBuildCache(); void ElementFromPointBuildCache(); void GetFocusedElementBuildCache();
    void CreateTreeWalker(); void get_ControlViewWalker(); void get_ContentViewWalker(); void get_RawViewWalker();
    void get_RawViewCondition(); void get_ControlViewCondition(); void get_ContentViewCondition();
    void CreateCacheRequest();
    [PreserveSig] int CreateTrueCondition([MarshalAs(UnmanagedType.IUnknown)] out object condition);
}
[ComImport, Guid("d22108aa-8ac5-49a5-837b-37bbb3d7591e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IUIAutomationElement {
    [PreserveSig] int SetFocus();
    void GetRuntimeId(); void FindFirst();
    [PreserveSig] int FindAll(int scope, [MarshalAs(UnmanagedType.IUnknown)] object condition, out IUIAutomationElementArray found);
    void FindFirstBuildCache(); void FindAllBuildCache(); void BuildUpdatedCache();
    [PreserveSig] int GetCurrentPropertyValue(int propertyId, [MarshalAs(UnmanagedType.Struct)] out object value);
    void GetCurrentPropertyValueEx(); void GetCachedPropertyValue(); void GetCachedPropertyValueEx();
    void GetCurrentPatternAs(); void GetCachedPatternAs();
    [PreserveSig] int GetCurrentPattern(int patternId, [MarshalAs(UnmanagedType.IUnknown)] out object pattern);
}
[ComImport, Guid("14314595-b4bc-4055-95f2-58f2e42c9855"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IUIAutomationElementArray {
    [PreserveSig] int get_Length(out int length);
    [PreserveSig] int GetElement(int index, out IUIAutomationElement element);
}
[ComImport, Guid("fb377fbe-8ea6-46d5-9c73-6499642d3059"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IUIAutomationInvokePattern { [PreserveSig] int Invoke(); }
[ComImport, Guid("94cf8058-9b8d-4ab9-8bfd-4cd0a33c8c70"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IUIAutomationTogglePattern { [PreserveSig] int Toggle(); }
[ComImport, Guid("a94cd8b1-0844-4cd6-9d2d-640537ab39e9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IUIAutomationValuePattern { [PreserveSig] int SetValue([MarshalAs(UnmanagedType.BStr)] string value); }

public class Element {
    internal IUIAutomationElement Raw;
    public string Name, ControlType, Patterns;
    public int X, Y, Width, Height;
    public bool Enabled, Focused;
}

public static class Com {
    const int TreeScopeDescendants = 4;
    const int InvokePatternId = 10000, ValuePatternId = 10002, TogglePatternId = 10015;
    static readonly string[] ControlTypes = {
        "Button", "Calendar", "CheckBox", "ComboBox", "Edit", "Hyperlink", "Image", "ListItem", "List", "Menu",
        "MenuBar", "MenuItem", "ProgressBar", "RadioButton", "ScrollBar", "Slider", "Spinner", "StatusBar", "Tab",
        "TabItem", "Text", "ToolBar", "ToolTip", "Tree", "TreeItem", "Custom", "Group", "Thumb", "DataGrid",
        "DataItem", "Document", "SplitButton", "Window", "Pane", "Header", "HeaderItem", "Table", "TitleBar",
        "Separator", "SemanticZoom", "AppBar" };
    // UIA_Is<Pattern>PatternAvailablePropertyId
    static readonly int[] PatternProperties = { 30031, 30041, 30043, 30028, 30036, 30033 };
    static readonly string[] PatternNames = { "Invoke", "Toggle", "Value", "ExpandCollapse", "SelectionItem", "RangeValue" };

    static IUIAutomation automation;
    static IUIAutomation Automation {
        get {
            if (automation == null) {
                automation = (IUIAutomation)Activator.CreateInstance(
                    Type.GetTypeFromCLSID(new Guid("ff48dba4-60ef-4201-aa87-54103eef594e")));
            }
            return automation;
        }
    }

    static void Check(int hr, string what) {
        if (hr != 0) throw new COMException(what + " failed", hr);
    }

    static object Property(IUIAutomationElement e, int id) {
        object v;
        return e.GetCurrentPropertyValue(id, out v) == 0 ? v : null;
    }

    public static List<Element> Descendants(IntPtr hwnd) {
        IUIAutomationElement root;
        Check(Automation.ElementFromHandle(hwnd, out root), "ElementFromHandle");
        object all;
        Check(Automation.CreateTrueCondition(out all), "CreateTrueCondition");
        IUIAutomationElementArray found;
        Check(root.FindAll(TreeScopeDescendants, all, out found), "FindAll");
        var list = new List<Element>();
        int n = 0;
        if (found != null) found.get_Length(out n);
        for (int i = 0; i < n; i++) {
            IUIAutomationElement raw;
            if (found.GetElement(i, out raw) != 0 || raw == null) continue;
            var e = new Element { Raw = raw };
            e.Name = (Property(raw, 30005) as string) ?? "";
            object type = Property(raw, 30003);
            int t = type is int ? (int)type - 50000 : -1;
            e.ControlType = t >= 0 && t < ControlTypes.Length ? ControlTypes[t] : "Type" + type;
            var rect = Property(raw, 30001) as double[];
            if (rect != null && rect.Length == 4) {
                e.X = (int)rect[0]; e.Y = (int)rect[1]; e.Width = (int)rect[2]; e.Height = (int)rect[3];
            }
            e.Enabled = Property(raw, 30010) as bool? ?? false;
            e.Focused = Property(raw, 30008) as bool? ?? false;
            var patterns = new List<string>();
            for (int p = 0; p < PatternProperties.Length; p++) {
                if (Property(raw, PatternProperties[p]) as bool? ?? false) patterns.Add(PatternNames[p]);
            }
            e.Patterns = string.Join(",", patterns);
            list.Add(e);
        }
        return list;
    }

    static object Pattern(Element e, int id, string name) {
        object p;
        Check(e.Raw.GetCurrentPattern(id, out p), name);
        if (p == null) throw new InvalidOperationException("'" + e.Name + "' has no " + name);
        return p;
    }

    public static void Invoke(Element e) {
        Check(((IUIAutomationInvokePattern)Pattern(e, InvokePatternId, "InvokePattern")).Invoke(), "Invoke");
    }
    public static void Toggle(Element e) {
        Check(((IUIAutomationTogglePattern)Pattern(e, TogglePatternId, "TogglePattern")).Toggle(), "Toggle");
    }
    public static void SetValue(Element e, string value) {
        Check(((IUIAutomationValuePattern)Pattern(e, ValuePatternId, "ValuePattern")).SetValue(value), "SetValue");
    }
    public static void Focus(Element e) {
        Check(e.Raw.SetFocus(), "SetFocus");
    }
}
}
'@
}
[void][LeapgateUia.Win]::SetProcessDPIAware()

# The main window and its FLUTTERVIEW child, found without UI Automation.
function Get-Windows {
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
    $views = [Collections.Generic.List[IntPtr]]::new()
    $vcb = [LeapgateUia.Win+EnumProc] {
        param($h, $l)
        $c = [Text.StringBuilder]::new(256)
        [void][LeapgateUia.Win]::GetClassName($h, $c, 256)
        if ($c.ToString() -eq 'FLUTTERVIEW') { $views.Add($h); return $false }
        $true
    }
    [void][LeapgateUia.Win]::EnumChildWindows($found[0], $vcb, [IntPtr]::Zero)
    if (-not $views.Count) { throw "no FLUTTERVIEW under the $WindowClass window" }
    [pscustomobject]@{ Main = $found[0]; View = $views[0] }
}

# Flutter builds its semantics tree only once an accessibility client shows up, so the first query
# can come back nearly empty; ask again for a few seconds.
function Get-Elements {
    for ($t = 0; $t -lt 12; $t++) {
        $all = @([LeapgateUia.Com]::Descendants($win.View))
        if ($all.Count -gt 3) { break }
        Start-Sleep -Milliseconds 700
    }
    $all
}

function Format-Element($e, [int]$i) {
    $state = @()
    if (-not $e.Enabled) { $state += 'disabled' }
    if ($e.Focused) { $state += 'focused' }
    '{0,4} {1} "{2}" [{3}] {4} @{5},{6} {7}x{8}' -f $i, $e.ControlType, ($e.Name -replace "`r?`n", ' / '),
    $e.Patterns, ($state -join ','), $e.X, $e.Y, $e.Width, $e.Height
}

function Test-Hit($e) {
    # A name may hold line breaks; -Name also accepts it the way Dump prints it (' / ').
    if ($Name) { return $e.Name -eq $Name -or ($e.Name -replace "`r?`n", ' / ') -eq $Name }
    if ($NameMatch) { return $e.Name -match $NameMatch }
    throw '-Name or -NameMatch is required'
}

function Find-Target {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $hits = @(Get-Elements | Where-Object { Test-Hit $_ })
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

$win = Get-Windows
switch ($Op) {
    'Dump' {
        $all = @(Get-Elements)
        for ($i = 0; $i -lt $all.Count; $i++) {
            $line = Format-Element $all[$i] $i
            if (-not $Match -or $line -match $Match) { $line }
        }
    }
    'Wait' { Format-Element (Find-Target) $Index }
    'Gone' {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while (@(Get-Elements | Where-Object { Test-Hit $_ }).Count) {
            if ((Get-Date) -gt $deadline) { throw "'$Name$NameMatch' still there after $TimeoutSec s" }
            Start-Sleep -Milliseconds 500
        }
        "gone: '$Name$NameMatch'"
    }
    'Invoke' { $e = Find-Target; [LeapgateUia.Com]::Invoke($e); "invoked '$($e.Name)'" }
    'Toggle' { $e = Find-Target; [LeapgateUia.Com]::Toggle($e); "toggled '$($e.Name)'" }
    'Focus' { $e = Find-Target; [LeapgateUia.Com]::Focus($e); "focused '$($e.Name)'" }
    'SetValue' { $e = Find-Target; [LeapgateUia.Com]::SetValue($e, (Read-Value)); "set the value of '$($e.Name)'" }
    'Type' {
        $e = Find-Target
        [void][LeapgateUia.Win]::SetForegroundWindow($win.Main); Start-Sleep -Milliseconds 300
        [LeapgateUia.Com]::Focus($e); Start-Sleep -Milliseconds 200
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.SendKeys]::SendWait((Escape-SendKeys (Read-Value)))
        "typed into '$($e.Name)'"
    }
    'Keys' {
        if (-not $Keys) { throw '-Keys is required' }
        [void][LeapgateUia.Win]::SetForegroundWindow($win.Main); Start-Sleep -Milliseconds 300
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.SendKeys]::SendWait($Keys)
        "sent keys $Keys"
    }
    'Click' {
        $e = Find-Target
        [void][LeapgateUia.Win]::SetForegroundWindow($win.Main); Start-Sleep -Milliseconds 300
        $x = [int]($e.X + $e.Width / 2); $y = [int]($e.Y + $e.Height / 2)
        [void][LeapgateUia.Win]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 100
        [LeapgateUia.Win]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); [LeapgateUia.Win]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
        "clicked '$($e.Name)' at $x,$y"
    }
}
