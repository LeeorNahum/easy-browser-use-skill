<#
.SYNOPSIS
Presses Allow on Chrome's "Allow remote debugging?" window when a chrome-devtools server asked for it.

.DESCRIPTION
Chrome shows this window each time a program attaches to the running Chrome, and until Allow is
pressed every call that needs the connection waits. This script finds that window through UI
Automation, even behind other windows, and invokes its Allow button. It activates no window,
moves no mouse, and sends no keys.

The window does not say which program asked. The script presses Allow when a chrome-devtools-mcp
server, any agent's, holds a connection to Chrome's debugging port that could have raised the
window, and no program of another kind does. Otherwise it leaves the window open.

With -Watch it keeps running for the launcher that starts the server, and answers each new window
as it appears, looking at the connections made in the ten seconds before. It prints READY once it
is watching and nothing after that. It writes a line per window to -LogFile, starting with a
timestamp and -ParentPid and then one of the words below, and also logs when it starts, when it
ends, and any error of its own. It exits with 0 when -ParentPid exits, and with 1 after an error
that ends the watch.

Without -Watch it prints WAITING once it is watching, answers the windows that appear after it
started, looking at the connections made since then, prints one result line, and exits with one of
these codes:
0  DONE       Allow was pressed and every window closed
1  ERROR      the script itself failed
2  NO_DIALOG  no matching window appeared within -TimeoutSec
3  NO_BUTTON  a window does not have the buttons this script knows, and is left open
4  REFUSED    no chrome-devtools-mcp server holds such a connection, or a program of another kind
              does, so the window is left open
5  OPEN       a window did not close after Allow
6  NO_PORT    no port file, or no Chrome listening on its port, found before WAITING, so nothing was
              watched or touched
The skill's remote debugging prompt reference gives the next step for each code.

.PARAMETER Existing
Answer the windows already open, such as one a call that hung is waiting on, looking at every open
connection.

.PARAMETER Watch
Keep answering windows until -ParentPid exits. Needs -ParentPid and cannot be combined with -Existing.

.PARAMETER ParentPid
With -Watch, the launcher. The watch ends when it does.

.PARAMETER LogFile
With -Watch, the file that gets a line per window and what was done about it.

.PARAMETER Title
The window's title exactly as shown. Defaults to "Allow remote debugging?", its English title.

.PARAMETER AllowName
The Allow button's name exactly as shown. Defaults to "Allow".

.PARAMETER ProcessName
The process that owns the window. Defaults to chrome.

.PARAMETER UserDataDir
Chrome's user data folder, which holds DevToolsActivePort. Defaults to the stable channel's.

.PARAMETER TimeoutSec
How long to wait for a window to appear. Defaults to 30.
#>
[CmdletBinding()]
param(
  [switch]$Existing,
  [switch]$Watch,
  [int]$ParentPid = 0,
  [string]$LogFile = '',
  [string]$Title = 'Allow remote debugging?',
  [string]$AllowName = 'Allow',
  [string]$ProcessName = 'chrome',
  [string]$UserDataDir = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'),
  [int]$TimeoutSec = 30
)
$ErrorActionPreference = 'Stop'
function Done([int]$Code, [string]$Line) { Write-Output ($Line -replace '\s+', ' '); exit $Code }
try {
if ($Watch -and ($Existing -or $ParentPid -lt 1)) { Done 1 'ERROR: -Watch needs -ParentPid and cannot be combined with -Existing.' }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Collections.Generic; using System.Net; using System.Text; using System.Runtime.InteropServices;
public class TcpRow { public int State; public string LocalAddress; public int LocalPort; public string RemoteAddress; public int RemotePort; public int Pid; public DateTime Created; }
public static class RemoteDebugWin32 {
  [DllImport("iphlpapi.dll")] static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int af, int cls, uint reserved);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, IntPtr buf, int len, out int retLen);
  // The IPv4 connection table with owning process and creation time (TCP_TABLE_OWNER_MODULE_ALL)
  public static TcpRow[] Tcp4() {
    // The table can grow between the size query and the read, so leave room and try again
    for (int attempt = 0; attempt < 4; attempt++) {
      int size = 0;
      GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2, 8, 0);
      size += 160 * 32;
      IntPtr buf = Marshal.AllocHGlobal(size);
      try {
        if (GetExtendedTcpTable(buf, ref size, false, 2, 8, 0) == 0) return ReadRows(buf);
      } finally { Marshal.FreeHGlobal(buf); }
    }
    throw new InvalidOperationException("the TCP connection table could not be read");
  }
  // Rows of MIB_TCPROW_OWNER_MODULE: six DWORDs, the creation FILETIME, then module data, 160 bytes each
  static TcpRow[] ReadRows(IntPtr buf) {
    int n = Marshal.ReadInt32(buf);
    var rows = new TcpRow[n];
    for (int i = 0; i < n; i++) {
      IntPtr r = IntPtr.Add(buf, 8 + i * 160);
      long created = Marshal.ReadInt64(r, 24);
      rows[i] = new TcpRow {
        State = Marshal.ReadInt32(r, 0),
        LocalAddress = new IPAddress((long)(uint)Marshal.ReadInt32(r, 4)).ToString(),
        LocalPort = Port(Marshal.ReadInt32(r, 8)),
        RemoteAddress = new IPAddress((long)(uint)Marshal.ReadInt32(r, 12)).ToString(),
        RemotePort = Port(Marshal.ReadInt32(r, 16)),
        Pid = Marshal.ReadInt32(r, 20),
        Created = created > 0 ? DateTime.FromFileTimeUtc(created).ToLocalTime() : DateTime.MinValue
      };
    }
    return rows;
  }
  static int Port(int p) { return ((p & 0xFF) << 8) | ((p >> 8) & 0xFF); }
  // A process's command line (ProcessCommandLineInformation), or null when it cannot be read
  public static string CommandLine(int pid) {
    IntPtr h = OpenProcess(0x1000, false, pid);
    if (h == IntPtr.Zero) return null;
    try {
      int len;
      NtQueryInformationProcess(h, 60, IntPtr.Zero, 0, out len);
      if (len <= 0) return null;
      IntPtr buf = Marshal.AllocHGlobal(len);
      try {
        if (NtQueryInformationProcess(h, 60, buf, len, out len) != 0) return null;
        int chars = Marshal.ReadInt16(buf) / 2;
        IntPtr text = Marshal.ReadIntPtr(buf, IntPtr.Size);
        return Marshal.PtrToStringUni(text, chars);
      } finally { Marshal.FreeHGlobal(buf); }
    } finally { CloseHandle(h); }
  }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  // Handle and owning process id, in pairs, of each visible window with this class and exact title
  public static long[] Find(string cls, string title) {
    var found = new List<long>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (IsWindowVisible(h)) {
        var c = new StringBuilder(64); GetClassName(h, c, 64);
        if (c.ToString() == cls) {
          var t = new StringBuilder(512); GetWindowText(h, t, 512);
          if (t.ToString() == title) { uint pid; GetWindowThreadProcessId(h, out pid); found.Add(h.ToInt64()); found.Add(pid); }
        }
      }
      return true;
    }, IntPtr.Zero);
    return found.ToArray();
  }
}
"@
$W = [RemoteDebugWin32]
$started = Get-Date

function Write-Log([string]$Line) {
  if ($LogFile) { try { Add-Content -LiteralPath $LogFile -Value ("{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $ParentPid, $Line) } catch { } }
}

# Every visible window titled $Title, as objects with Handle and Pid
function Find-Titled {
  $a = $W::Find('Chrome_WidgetWin_1', $Title)
  for ($i = 0; $i -lt $a.Length; $i += 2) { [pscustomobject]@{ Handle = [long]$a[$i]; Pid = [int]$a[$i + 1] } }
}

# The Chrome process listening on the debugging port named in the port file, or why there is none
function Get-Browser {
  $portFile = Join-Path $UserDataDir 'DevToolsActivePort'
  if (-not (Test-Path -LiteralPath $portFile)) {
    return [pscustomobject]@{ Error = "NO_PORT: '$portFile' does not exist, so no Chrome is running with remote debugging on in that folder." }
  }
  $port = [int]((Get-Content -LiteralPath $portFile -TotalCount 1).Trim())
  # Chrome listens on IPv4, whose table is read directly. The system query is the slower fallback.
  foreach ($system in $false, $true) {
    $listeners = @(Get-Connections $system | Where-Object { $_.State -eq 'Listen' -and $_.LocalPort -eq $port -and
      (Get-Process -Id $_.Pid -ErrorAction SilentlyContinue).ProcessName -eq $ProcessName })
    if ($listeners.Count) {
      return [pscustomobject]@{ Error = $null; Port = $port; Pid = [int]$listeners[0].Pid; System = $system; Addresses = @($listeners | ForEach-Object { $_.LocalAddress }) }
    }
  }
  [pscustomobject]@{ Error = "NO_PORT: no $ProcessName process is listening on port $port from '$portFile'." }
}

# Every TCP connection as State, addresses, ports, Pid and Created, from the IPv4 table read
# directly, or from the system query when $System is set
function Get-Connections([bool]$System) {
  if (-not $System) {
    foreach ($r in $W::Tcp4()) {
      $state = switch ($r.State) { 2 { 'Listen' } 5 { 'Established' } default { 'Other' } }
      [pscustomobject]@{ State = $state; LocalAddress = $r.LocalAddress; LocalPort = $r.LocalPort; RemoteAddress = $r.RemoteAddress; RemotePort = $r.RemotePort; Pid = $r.Pid; Created = $r.Created }
    }
  } else {
    foreach ($c in @(Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
      [pscustomobject]@{ State = "$($c.State)"; LocalAddress = $c.LocalAddress; LocalPort = $c.LocalPort; RemoteAddress = $c.RemoteAddress; RemotePort = $c.RemotePort; Pid = [int]$c.OwningProcess; Created = $c.CreationTime }
    }
  }
}

# Why a window raised after $Since must be left open, or nothing when Allow can be pressed. Chrome
# raises the window as a connection is made, so the connections made since then are the candidates.
function Test-Connections($Browser, [datetime]$Since) {
  $servers = 0; $others = 0
  foreach ($c in @(Get-Connections $Browser.System | Where-Object { $_.State -eq 'Established' -and $_.RemotePort -eq $Browser.Port })) {
    if ($c.Pid -eq $Browser.Pid -or $Browser.Addresses -notcontains $c.RemoteAddress -or $c.Created -lt $Since) { continue }
    if ("$($W::CommandLine($c.Pid))" -match 'chrome-devtools-mcp') { $servers++ } else { $others++ }
  }
  if ($others) { return 'a program other than chrome-devtools-mcp is connected to Chrome''s debugging port' }
  if (-not $servers) { return 'no chrome-devtools-mcp server has a connection to Chrome''s debugging port that could have raised the window' }
}

# Presses Allow when the window shows exactly the three buttons this script knows. Chrome ignores a
# press that comes within a double-click interval of the window appearing or of an earlier press, so
# the first press waits a moment after $SeenAt and any further press comes a second after the last.
function Invoke-Allow([long]$Prompt, [datetime]$SeenAt) {
  $isButton = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
  $gone = { -not $W::IsWindow([IntPtr]$Prompt) -or -not $W::IsWindowVisible([IntPtr]$Prompt) }
  $closed = [pscustomobject]@{ Code = 0; Line = 'DONE: Allow was pressed and the window closed' }
  $first = $SeenAt.AddMilliseconds(600)
  while ((Get-Date) -lt $first -and -not (& $gone)) { Start-Sleep -Milliseconds 40 }
  $until = (Get-Date).AddSeconds(6)
  $pressed = $false
  while ((Get-Date) -lt $until) {
    if (& $gone) { if ($pressed) { return $closed } return $null }
    try {
      $buttons = @([Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Prompt).FindAll([Windows.Automation.TreeScope]::Descendants, $isButton))
      $allow = @($buttons | Where-Object { $_.Current.Name -eq $AllowName })
      if ($buttons.Count -ne 3 -or $allow.Count -ne 1) {
        if (& $gone) { continue }
        return [pscustomobject]@{ Code = 3; Line = "NO_BUTTON: the window has $($buttons.Count) buttons and $($allow.Count) named '$AllowName'. It is left open." }
      }
      $allow[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
      $pressed = $true
    } catch { if (-not (& $gone)) { throw } }
    $wait = (Get-Date).AddMilliseconds(1100)
    while ((Get-Date) -lt $wait -and -not (& $gone)) { Start-Sleep -Milliseconds 40 }
  }
  [pscustomobject]@{ Code = 5; Line = 'OPEN: the window did not close after Allow. It is left open.' }
}

if ($Watch) {
  # Windows open now belong to connections made before this watch, so they are left alone
  $handled = @{}
  foreach ($openAtStart in @(Find-Titled)) { $handled[$openAtStart.Handle] = $true }
  $parent = [System.Diagnostics.Process]::GetProcessById($ParentPid)
  Write-Log "watching for windows titled '$Title' while process $ParentPid runs"
  # The launcher starts the server once this is printed, so no window comes before the snapshot above
  Write-Output 'READY'
  # Every session's watcher sees every window, so one at a time works on them and the others find them answered
  $lock = [System.Threading.Mutex]::new($false, 'Local\easy-browser-use-allow')
  while (-not $parent.HasExited) {
    $locked = $false
    try {
      $open = @(Find-Titled)
      # A closed window's handle can be reused, so forget the ones that are gone
      foreach ($h in @($handled.Keys)) { if (-not ($open | Where-Object { $_.Handle -eq $h })) { $handled.Remove($h) } }
      $fresh = @($open | Where-Object { -not $handled.ContainsKey($_.Handle) })
      if ($fresh.Count) {
        try { $locked = $lock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
      }
      if ($locked) {
        $seenAt = Get-Date
        foreach ($f in $fresh) { $handled[$f.Handle] = $true }
        $browser = Get-Browser
        if ($browser.Error) { Write-Log "$($browser.Error) The window is left open." }
        else {
          $why = Test-Connections $browser $seenAt.AddSeconds(-10)
          foreach ($f in @($fresh | Where-Object { $_.Pid -eq $browser.Pid })) {
            if (-not $W::IsWindow([IntPtr]$f.Handle)) { continue }
            if ($why) { Write-Log "REFUSED: $why. The window is left open."; continue }
            $result = Invoke-Allow $f.Handle $seenAt
            if ($result) { Write-Log ("{0} ({1:N0} ms after it was seen)" -f $result.Line, ((Get-Date) - $seenAt).TotalMilliseconds) }
          }
        }
      }
    } catch { Write-Log "ERROR: $($_.Exception.Message)" }
    finally { if ($locked) { $lock.ReleaseMutex() } }
    Start-Sleep -Milliseconds 250
  }
  Write-Log "process $ParentPid is gone, so the watch ends"
  exit 0
}

$browser = Get-Browser
if ($browser.Error) { Done 6 "$($browser.Error) Nothing was touched." }

$before = if ($Existing) { @() } else { @(Find-Titled | Where-Object { $_.Pid -eq $browser.Pid } | ForEach-Object { $_.Handle }) }
Write-Output 'WAITING'
$deadline = (Get-Date).AddSeconds($TimeoutSec)
do {
  $hits = @(Find-Titled | Where-Object { $_.Pid -eq $browser.Pid -and $before -notcontains $_.Handle })
  if ($hits.Count) { break }
  Start-Sleep -Milliseconds 100
} while ((Get-Date) -lt $deadline)
# A window already open may have been there for a while, so only a new one needs the pause before pressing
$seenAt = if ($Existing) { [datetime]::MinValue } else { Get-Date }
if (-not $hits.Count) {
  $which = if ($Existing) { '' } else { 'new ' }
  Done 2 "NO_DIALOG: no ${which}visible $ProcessName window titled '$Title' before the $TimeoutSec-second wait ran out"
}

$why = Test-Connections $browser $(if ($Existing) { [datetime]::MinValue } else { $started.AddSeconds(-1) })
if ($why) { Done 4 "REFUSED: $why, so the window is left open." }

$worst = $null
foreach ($hit in $hits) {
  if (-not $W::IsWindow([IntPtr]$hit.Handle)) { continue }
  $result = Invoke-Allow $hit.Handle $seenAt
  if ($result -and (-not $worst -or $result.Code -gt $worst.Code)) { $worst = $result }
}
if (-not $worst) { Done 2 'NO_DIALOG: the window closed before it could be answered' }
Done $worst.Code $worst.Line
} catch {
  if ($Watch) { Write-Log "ERROR: $($_.Exception.Message) The watch ends."; exit 1 }
  Done 1 "ERROR: $($_.Exception.Message)"
}
