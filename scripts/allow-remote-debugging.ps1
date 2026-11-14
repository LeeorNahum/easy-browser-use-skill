<#
.SYNOPSIS
Presses Allow on Chrome's "Allow remote debugging?" window for the agent's own chrome-devtools connection.

.DESCRIPTION
Chrome shows this window each time a program attaches to the running Chrome, and until Allow is
pressed every call that needs the connection waits. This script finds that window through UI
Automation, even behind other windows, and invokes its Allow button. It activates no window,
moves no mouse, and sends no keys.

It acts only when the connection belongs to the agent. A chrome-devtools-mcp process that has a
parent process in common with this script, such as the harness the agent runs in and not a Windows
or terminal host process, must hold a
connection to Chrome's debugging port, and no other connection may be there to have raised the
window. Without -Existing it ignores any such window that was already open when it started, looks
only at connections made after it started, and waits a moment after the first window to see
whether a second follows.

With -Watch it keeps running instead, for the launcher that starts the server. It prints READY once
it is watching and nothing after that. It answers each new window the same way, counting as the
agent's own only a chrome-devtools-mcp process that descends from -ParentPid and looking at the
connections made in the ten seconds before the window appeared. It writes one line per window to
-LogFile, starting with a timestamp and -ParentPid and then one of the words below. It also logs
when it starts, when it ends, and any error of its own. It exits with 0 when that process does, and
with 1 after an error that ends the watch.

Without -Watch it prints WAITING once it is watching, and then one result line, and exits with one
of these codes:
0  DONE       the window closed after Allow
1  ERROR      the script itself failed
2  NO_DIALOG  no matching window appeared within -TimeoutSec
3  AMBIGUOUS  more than one matched, and each is left open
4  NO_BUTTON  the window does not have the buttons this script knows, and is left open
5  NOT_OURS   the agent's own server holds no connection, or another connection could have raised the
           window, and the window is left open
6  OPEN       the window did not close after Allow
7  NO_PORT    no port file, or no Chrome listening on its port, found before WAITING, so nothing was
           watched or touched
The skill's remote debugging prompt reference gives the next step for each code.

.PARAMETER Existing
Answer a window that is already open, such as one a call that hung is waiting on. Needs exactly one
such window, and every open connection to Chrome's debugging port must be the agent's own.

.PARAMETER Watch
Keep answering windows until -ParentPid exits. Needs -ParentPid and cannot be combined with -Existing.

.PARAMETER ParentPid
With -Watch, the process whose descendants count as the agent's own.

.PARAMETER LogFile
With -Watch, the file that gets one line per window and what was done about it.

.PARAMETER Title
The window's title exactly as shown. Defaults to "Allow remote debugging?", its English title.

.PARAMETER AllowName
The Allow button's name exactly as shown. Defaults to "Allow".

.PARAMETER ProcessName
The process that owns the window. Defaults to chrome.

.PARAMETER UserDataDir
Chrome's user data folder, which holds DevToolsActivePort. Defaults to the stable channel's.

.PARAMETER TimeoutSec
How long to wait for the window to appear. Defaults to 30.
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
Add-Type @"
using System; using System.Collections.Generic; using System.Text; using System.Runtime.InteropServices;
public static class RemoteDebugWin32 {
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

# Windows and terminal processes that sit above many unrelated sessions, so sharing one of them says nothing about whose connection it is
$sharedHosts = 'explorer', 'svchost', 'services', 'wininit', 'winlogon', 'WmiPrvSE', 'System', 'userinit', 'sihost',
  'taskhostw', 'conhost', 'OpenConsole', 'WindowsTerminal'

function Write-Log([string]$Line) {
  if ($LogFile) { try { Add-Content -LiteralPath $LogFile -Value ("{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $ParentPid, $Line) } catch { } }
}
function Get-Buttons([IntPtr]$h) {
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
  $root = [Windows.Automation.AutomationElement]::FromHandle($h)
  $isButton = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
  @($root.FindAll([Windows.Automation.TreeScope]::Descendants, $isButton))
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
  $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
    Where-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName -eq $ProcessName })
  if (-not $listeners.Count) {
    return [pscustomobject]@{ Error = "NO_PORT: no $ProcessName process is listening on port $port from '$portFile'." }
  }
  [pscustomobject]@{ Error = $null; Port = $port; Pid = [int]$listeners[0].OwningProcess; Addresses = @($listeners | ForEach-Object { $_.LocalAddress }) }
}

# Open connections to the address Chrome listens on, from outside Chrome, each marked Own when a
# chrome-devtools-mcp process of this agent holds it
function Get-PortConnections($Browser) {
  $procs = @{}
  foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine) { $procs[[int]$p.ProcessId] = $p }
  $mine = @{}
  if ($Watch) { $mine[$ParentPid] = $true }
  else { for ($id = $PID; $id -and $procs.ContainsKey($id) -and -not $mine.ContainsKey($id); $id = [int]$procs[$id].ParentProcessId) { $mine[$id] = $true } }
  $found = @()
  foreach ($c in @(Get-NetTCPConnection -RemotePort $Browser.Port -State Established -ErrorAction SilentlyContinue)) {
    if ($c.OwningProcess -eq $Browser.Pid -or $Browser.Addresses -notcontains $c.RemoteAddress) { continue }
    $owner = $procs[[int]$c.OwningProcess]
    $server = $null -ne $owner -and $owner.CommandLine -match 'chrome-devtools-mcp'
    $own = $false
    if ($server) {
      $seen = @{}
      for ($id = [int]$c.OwningProcess; $id -and $procs.ContainsKey($id) -and -not $seen.ContainsKey($id); $id = [int]$procs[$id].ParentProcessId) {
        $seen[$id] = $true
        if ($mine.ContainsKey($id)) { $own = $sharedHosts -notcontains $procs[$id].Name.Replace('.exe', ''); break }
      }
    }
    $found += [pscustomobject]@{ Created = $c.CreationTime; Own = $own }
  }
  $found
}

# The window does not say who asked, so it is the agent's only when the agent's own server holds a
# connection and no other connection is there to have raised it. The server connects before Chrome
# raises the window. Returns why not, or nothing when it is the agent's.
function Test-Attribution($Browser, [datetime]$Since) {
  $connections = @(@(Get-PortConnections $Browser) | Where-Object { $_.Created -ge $Since })
  if (-not @($connections | Where-Object { $_.Own }).Count) {
    return 'no connection to Chrome''s debugging port from this agent''s own chrome-devtools-mcp server'
  }
  if (@($connections | Where-Object { -not $_.Own }).Count) {
    return 'a connection to Chrome''s debugging port other than this agent''s own could have raised the window'
  }
}

# Presses Allow when the window shows exactly the three buttons this script knows
function Invoke-Allow([long]$Prompt) {
  $buttons = @(Get-Buttons ([IntPtr]$Prompt))
  $allow = @($buttons | Where-Object { $_.Current.Name -eq $AllowName })
  if ($buttons.Count -ne 3 -or $allow.Count -ne 1) {
    return [pscustomobject]@{ Code = 4; Line = "NO_BUTTON: the window has $($buttons.Count) buttons and $($allow.Count) named '$AllowName'. It is left open." }
  }
  $allow[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
  $until = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $until) {
    Start-Sleep -Milliseconds 200
    if (-not $W::IsWindow([IntPtr]$Prompt) -or -not $W::IsWindowVisible([IntPtr]$Prompt)) {
      return [pscustomobject]@{ Code = 0; Line = 'DONE: Allow was pressed and the window closed' }
    }
  }
  [pscustomobject]@{ Code = 6; Line = 'OPEN: the window did not close after Allow. It is left open.' }
}

if ($Watch) {
  # Windows open now belong to connections made before this watch, so they are left alone
  $handled = @{}
  foreach ($existing in @(Find-Titled)) { $handled[$existing.Handle] = $true }
  $parent = [System.Diagnostics.Process]::GetProcessById($ParentPid)
  Write-Log "watching for windows titled '$Title' while process $ParentPid runs"
  # The launcher starts the server once this is printed, so no window comes before the snapshot above
  Write-Output 'READY'
  while (-not $parent.HasExited) {
    try {
      $open = @(Find-Titled)
      # A closed window's handle can be reused, so forget the ones that are gone
      foreach ($h in @($handled.Keys)) { if (-not ($open | Where-Object { $_.Handle -eq $h })) { $handled.Remove($h) } }
      $fresh = @($open | Where-Object { -not $handled.ContainsKey($_.Handle) })
      if ($fresh.Count) {
        $seenAt = Get-Date
        $browser = Get-Browser
        foreach ($f in $fresh) { $handled[$f.Handle] = $true }
        if ($browser.Error) { Write-Log "$($browser.Error) The window is left open." }
        else {
          Start-Sleep -Milliseconds 1500
          $now = @(Find-Titled | Where-Object { $_.Pid -eq $browser.Pid -and ($_.Handle -in $fresh.Handle -or -not $handled.ContainsKey($_.Handle)) })
          foreach ($n in $now) { $handled[$n.Handle] = $true }
          if (-not $now.Count) { Write-Log 'NO_DIALOG: the window closed again before it could be answered' }
          elseif ($now.Count -gt 1) { Write-Log "AMBIGUOUS: $($now.Count) windows. Each is left open." }
          else {
            # Chrome raises the window as the connection is made, so any connection that could have raised it is recent
            $why = Test-Attribution $browser $seenAt.AddSeconds(-10)
            if ($why) { Write-Log "NOT_OURS: $why. The window is left open." }
            else {
              $result = Invoke-Allow $now[0].Handle
              Write-Log $result.Line
              # The window is gone, so its handle can be reused by the next one
              if ($result.Code -eq 0) { $handled.Remove($now[0].Handle) }
            }
          }
        }
      }
    } catch { Write-Log "ERROR: $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 1000
  }
  Write-Log "process $ParentPid is gone, so the watch ends"
  exit 0
}

$browser = Get-Browser
if ($browser.Error) { Done 7 "$($browser.Error) Nothing was touched." }

$before = if ($Existing) { @() } else { @(Find-Titled | Where-Object { $_.Pid -eq $browser.Pid } | ForEach-Object { $_.Handle }) }
Write-Output 'WAITING'
$deadline = (Get-Date).AddSeconds($TimeoutSec)
do {
  $hits = @(Find-Titled | Where-Object { $_.Pid -eq $browser.Pid -and $before -notcontains $_.Handle })
  if ($hits.Count) { break }
  Start-Sleep -Milliseconds 200
} while ((Get-Date) -lt $deadline)
if (-not $hits.Count) {
  $which = if ($Existing) { '' } else { 'new ' }
  Done 2 "NO_DIALOG: no ${which}visible $ProcessName window titled '$Title' before the $TimeoutSec-second wait ran out"
}
# A second window can follow the first, and the first can close again
if (-not $Existing) {
  Start-Sleep -Milliseconds 1500
  $hits = @(Find-Titled | Where-Object { $_.Pid -eq $browser.Pid -and $before -notcontains $_.Handle })
  if (-not $hits.Count) { Done 2 'NO_DIALOG: the window that appeared closed again before it could be answered' }
}
if ($hits.Count -gt 1) { Done 3 "AMBIGUOUS: $($hits.Count) $ProcessName windows titled '$Title'. Each is left open." }

# With -Existing every open connection counts, and a run without it looks only at connections made since it started
$why = Test-Attribution $browser $(if ($Existing) { [datetime]::MinValue } else { $started.AddSeconds(-1) })
if ($why) { Done 5 "NOT_OURS: $why, so the window is left open." }

$result = Invoke-Allow $hits[0].Handle
Done $result.Code $result.Line
} catch {
  if ($Watch) { Write-Log "ERROR: $($_.Exception.Message) The watch ends."; exit 1 }
  Done 1 "ERROR: $($_.Exception.Message)"
}
