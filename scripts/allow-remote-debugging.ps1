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

With -Watch it answers each new window as it appears, looking at the connections made in the ten
seconds before, for every session on the machine. One watcher runs at a time: a second one waits
until the first is watching and then exits. It prints READY once a watcher is watching and nothing
after that. It writes its process id to -PidFile and holds that file open while it runs, which is how
a launcher tells it is running. It answers a window already open when it starts like a new one. It
writes a line per window to -LogFile,
starting with a timestamp and its process id and then one of the words below, and also logs when it
starts, when it ends, and any error of its own. It exits with 0 a few seconds after no launcher is
running, and with 1 after an error that ends the watch.

Without -Watch it prints WAITING once it is watching, answers the windows that appear after it
started, looking at the connections made since then, prints one result line, and exits with one of
these codes.
0  DONE      Allow was pressed and every window closed
1  ERROR      the script itself failed
2  NO_DIALOG  no matching window appeared within -TimeoutSec
3  NO_BUTTON  a window does not have the buttons this script knows, and is left open
4  REFUSED    no chrome-devtools-mcp server holds such a connection, or a program of another kind
              does, so the window is left open
5  OPEN       a window did not close after Allow
6  NO_PORT    no port file, or no Chrome listening on its port, found before WAITING, so nothing was
              watched or touched
When a window was worked on and no launcher is running, the line also says to register the launcher.
The skill's hanging first call reference gives the next step for each code.

.PARAMETER Existing
Answer the windows already open, such as one a call that hung is waiting on, looking at every open
connection.

.PARAMETER Watch
Keep answering windows while any launcher runs. Cannot be combined with -Existing.

.PARAMETER PidFile
With -Watch, the file that holds the watcher's process id while it runs.

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
  [string]$PidFile = '',
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
if ($Watch -and $Existing) { Done 1 'ERROR: -Watch cannot be combined with -Existing.' }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Collections.Generic; using System.Net; using System.Text; using System.Runtime.InteropServices;
public class TcpRow { public int State; public string LocalAddress; public int LocalPort; public string RemoteAddress; public int RemotePort; public int Pid; public DateTime Created; }
public static class RemoteDebugWin32 {
  [DllImport("iphlpapi.dll")] static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int af, int cls, uint reserved);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, IntPtr buf, int len, out int retLen);
  // Every IPv4 and IPv6 connection with its owning process and creation time (TCP_TABLE_OWNER_MODULE_ALL)
  public static TcpRow[] Tcp() {
    var rows = new List<TcpRow>();
    rows.AddRange(Table(2, 160));
    rows.AddRange(Table(23, 192));
    return rows.ToArray();
  }
  static TcpRow[] Table(int family, int rowSize) {
    // The table can grow between the size query and the read, so leave room and try again
    for (int attempt = 0; attempt < 4; attempt++) {
      int size = 0;
      GetExtendedTcpTable(IntPtr.Zero, ref size, false, family, 8, 0);
      size += rowSize * 32;
      IntPtr buf = Marshal.AllocHGlobal(size);
      try {
        if (GetExtendedTcpTable(buf, ref size, false, family, 8, 0) == 0) return family == 2 ? Rows4(buf) : Rows6(buf);
      } finally { Marshal.FreeHGlobal(buf); }
    }
    throw new InvalidOperationException("the TCP connection table could not be read");
  }
  // MIB_TCPROW_OWNER_MODULE: six DWORDs, the creation FILETIME, then module data, 160 bytes, after an 8-byte count
  static TcpRow[] Rows4(IntPtr buf) {
    int n = Marshal.ReadInt32(buf);
    var rows = new TcpRow[n];
    for (int i = 0; i < n; i++) {
      IntPtr r = IntPtr.Add(buf, 8 + i * 160);
      rows[i] = new TcpRow {
        State = Marshal.ReadInt32(r, 0),
        LocalAddress = new IPAddress((long)(uint)Marshal.ReadInt32(r, 4)).ToString(),
        LocalPort = Port(Marshal.ReadInt32(r, 8)),
        RemoteAddress = new IPAddress((long)(uint)Marshal.ReadInt32(r, 12)).ToString(),
        RemotePort = Port(Marshal.ReadInt32(r, 16)),
        Pid = Marshal.ReadInt32(r, 20),
        Created = Time(Marshal.ReadInt64(r, 24))
      };
    }
    return rows;
  }
  // MIB_TCP6ROW_OWNER_MODULE: local address, scope, port, remote address, scope, port, state, pid,
  // the creation FILETIME at 56, then module data, 192 bytes
  static TcpRow[] Rows6(IntPtr buf) {
    int n = Marshal.ReadInt32(buf);
    var rows = new TcpRow[n];
    for (int i = 0; i < n; i++) {
      IntPtr r = IntPtr.Add(buf, 8 + i * 192);
      rows[i] = new TcpRow {
        LocalAddress = Address6(r, 0),
        LocalPort = Port(Marshal.ReadInt32(r, 20)),
        RemoteAddress = Address6(r, 24),
        RemotePort = Port(Marshal.ReadInt32(r, 44)),
        State = Marshal.ReadInt32(r, 48),
        Pid = Marshal.ReadInt32(r, 52),
        Created = Time(Marshal.ReadInt64(r, 56))
      };
    }
    return rows;
  }
  static string Address6(IntPtr r, int offset) { var b = new byte[16]; Marshal.Copy(IntPtr.Add(r, offset), b, 0, 16); return new IPAddress(b).ToString(); }
  static DateTime Time(long fileTime) { return fileTime > 0 ? DateTime.FromFileTimeUtc(fileTime).ToLocalTime() : DateTime.MinValue; }
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
  if ($LogFile) { try { Add-Content -LiteralPath $LogFile -Value ("{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $PID, $Line) } catch { } }
}

# Whether any session's launcher is running: Node with the launcher's script on its command line,
# leaving out the launcher's helper that keeps the watcher running
function Test-Launcher {
  foreach ($p in @(Get-Process -Name node -ErrorAction SilentlyContinue)) {
    $line = "$($W::CommandLine($p.Id))"
    if ($line -match '[\\/]scripts[\\/]launch-server\.mjs' -and $line -notmatch '--watcher-helper') { return $true }
  }
  $false
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
  $listeners = @(Get-Connections | Where-Object { $_.State -eq 2 -and $_.LocalPort -eq $port -and
    (Get-Process -Id $_.Pid -ErrorAction SilentlyContinue).ProcessName -eq $ProcessName })
  if (-not $listeners.Count) {
    return [pscustomobject]@{ Error = "NO_PORT: no $ProcessName process is listening on port $port from '$portFile'." }
  }
  [pscustomobject]@{ Error = $null; Port = $port; Pid = [int]$listeners[0].Pid; Addresses = @($listeners | ForEach-Object { $_.LocalAddress }) }
}

# Every IPv4 and IPv6 TCP connection, read directly because the system queries take a quarter second each
function Get-Connections { $W::Tcp() }

# Whether a process is a chrome-devtools-mcp server: Node running that package's own entry script.
# The command line is read directly, and through the slower system query when that fails.
function Test-Server([int]$ProcessId) {
  if ((Get-Process -Id $ProcessId -ErrorAction SilentlyContinue).ProcessName -ne 'node') { return $false }
  $line = $W::CommandLine($ProcessId)
  if ($null -eq $line) { $line = (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue).CommandLine }
  "$line" -match '[\\/]chrome-devtools-mcp[\\/].*[\\/]chrome-devtools-mcp\.js'
}

# Why a window must be left open, or nothing when Allow can be pressed. Any open connection from a
# program of another kind refuses it, whatever its age. A server connection counts only when it was
# made since $Since, because Chrome raises the window as the connection is made.
function Test-Connections($Browser, [datetime]$Since) {
  $servers = 0
  foreach ($c in @(Get-Connections | Where-Object { $_.State -eq 5 -and $_.RemotePort -eq $Browser.Port })) {
    if ($c.Pid -eq $Browser.Pid -or $Browser.Addresses -notcontains $c.RemoteAddress) { continue }
    if (-not (Test-Server $c.Pid)) { return 'a program other than chrome-devtools-mcp is connected to Chrome''s debugging port' }
    if ($c.Created -ge $Since) { $servers++ }
  }
  if (-not $servers) { return 'no chrome-devtools-mcp server has a connection to Chrome''s debugging port that could have raised the window' }
}

# Presses Allow when the window shows exactly the three buttons this script knows. Chrome ignores a
# press that comes within a double-click interval of the window appearing or of an earlier press, so
# the first press waits a moment after $SeenAt and any further press comes a second after the last.
# $Check runs again before every press, so a program that connects in the meantime still refuses it.
function Invoke-Allow([long]$Prompt, [datetime]$SeenAt, [scriptblock]$Check) {
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
      $why = & $Check
      if ($why) { return [pscustomobject]@{ Code = 4; Line = "REFUSED: $why. The window is left open." } }
      $allow[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
      $pressed = $true
    } catch { if (-not (& $gone)) { throw } }
    $wait = (Get-Date).AddMilliseconds(1100)
    while ((Get-Date) -lt $wait -and -not (& $gone)) { Start-Sleep -Milliseconds 40 }
  }
  [pscustomobject]@{ Code = 5; Line = 'OPEN: the window did not close after Allow. It is left open.' }
}

if ($Watch) {
  # One watcher serves every session. A second one waits for the first to be watching, so its
  # launcher starts the server only once a window can be answered, and then leaves.
  $only = [System.Threading.Mutex]::new($false, 'Local\easy-browser-use-watcher')
  $ready = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, 'Local\easy-browser-use-watcher-ready')
  try { $owner = $only.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owner = $true }
  if (-not $owner) {
    if (-not $ready.WaitOne(10000)) { exit 1 }
    Write-Output 'READY'
    exit 0
  }
  [void]$ready.Reset()
  # Held open for writing until the watcher exits, which is how a launcher tells it is running
  if ($PidFile) {
    $pidHandle = [System.IO.File]::Open($PidFile, 'OpenOrCreate', 'Write', 'Read')
    $pidHandle.SetLength(0)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("$PID")
    $pidHandle.Write($bytes, 0, $bytes.Length)
    $pidHandle.Flush()
  }
  # A window already open is answered like a new one, so one raised while a watcher was being replaced is not missed
  $handled = @{}
  Write-Log "watching for windows titled '$Title' while a launcher runs"
  [void]$ready.Set()
  Write-Output 'READY'
  $nextLauncherCheck = Get-Date
  $watching = $true
  while ($watching) {
    try {
      if ((Get-Date) -ge $nextLauncherCheck) {
        $watching = Test-Launcher
        $nextLauncherCheck = (Get-Date).AddSeconds(4)
      }
      $open = @(Find-Titled)
      # A closed window's handle can be reused, so forget the ones that are gone
      foreach ($h in @($handled.Keys)) { if (-not ($open | Where-Object { $_.Handle -eq $h })) { $handled.Remove($h) } }
      $fresh = @($open | Where-Object { -not $handled.ContainsKey($_.Handle) })
      if ($watching -and $fresh.Count) {
        $seenAt = Get-Date
        $browser = Get-Browser
        if ($browser.Error) {
          Write-Log "$($browser.Error) The window is left open."
          foreach ($f in $fresh) { $handled[$f.Handle] = $true }
        } else {
          $check = { Test-Connections $browser $seenAt.AddSeconds(-10) }
          # A window is marked once it is decided, so one that an error interrupted is tried again next time
          foreach ($f in $fresh) {
            if ($f.Pid -ne $browser.Pid -or -not $W::IsWindow([IntPtr]$f.Handle)) { $handled[$f.Handle] = $true; continue }
            $why = & $check
            if ($why) { $handled[$f.Handle] = $true; Write-Log "REFUSED: $why. The window is left open."; continue }
            $result = Invoke-Allow $f.Handle $seenAt $check
            $handled[$f.Handle] = $true
            if ($result) { Write-Log ("{0} ({1:N0} ms after it was seen)" -f $result.Line, ((Get-Date) - $seenAt).TotalMilliseconds) }
          }
        }
      }
    } catch { Write-Log "ERROR: $($_.Exception.Message)" }
    if ($watching) { Start-Sleep -Milliseconds 250 }
  }
  Write-Log 'no launcher is running, so the watch ends'
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

# With -Existing every open server connection counts, and a run without it counts those made since it started
$since = if ($Existing) { [datetime]::MinValue } else { $started.AddSeconds(-1) }
$check = { Test-Connections $browser $since }
$why = & $check
if ($why) { Done 4 "REFUSED: $why, so the window is left open." }

$worst = $null
foreach ($hit in $hits) {
  if (-not $W::IsWindow([IntPtr]$hit.Handle)) { continue }
  $result = Invoke-Allow $hit.Handle $seenAt $check
  if ($result -and (-not $worst -or $result.Code -gt $worst.Code)) { $worst = $result }
}
if (-not $worst) { Done 2 'NO_DIALOG: the window closed before it could be answered' }
# Without a launcher, this server will wait on the window again at its next connection
$hint = if (Test-Launcher) { '' } else { ' No launcher is running, so register the launcher as the skill''s Setup says.' }
Done $worst.Code "$($worst.Line)$hint"
} catch {
  if ($Watch) { Write-Log "ERROR: $($_.Exception.Message) The watch ends."; exit 1 }
  Done 1 "ERROR: $($_.Exception.Message)"
}
