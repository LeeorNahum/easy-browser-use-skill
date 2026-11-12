<#
.SYNOPSIS
Presses Allow on Chrome's "Allow remote debugging?" window for the agent's own chrome-devtools connection.

.DESCRIPTION
Chrome shows this window each time a program attaches to the running Chrome, and until Allow is
pressed every call that needs the connection waits. This script finds that window through UI
Automation, even behind other windows, and invokes its Allow button. It activates no window,
moves no mouse, and sends no keys.

It acts only when the connection belongs to the agent. A chrome-devtools-mcp process that has a
parent process in common with this script, such as the harness the agent runs in, must hold a
connection to Chrome's debugging port, and no other connection may be there to have raised the
window. Without -Existing it ignores any such window that was already open when it started, looks
only at connections made after it started, and waits a moment after the first window to see
whether a second follows.

Prints WAITING once it is watching, and then one result line, and exits with one of these codes:
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
  [string]$Title = 'Allow remote debugging?',
  [string]$AllowName = 'Allow',
  [string]$ProcessName = 'chrome',
  [string]$UserDataDir = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'),
  [int]$TimeoutSec = 30
)
$ErrorActionPreference = 'Stop'
function Done([int]$Code, [string]$Line) { Write-Output ($Line -replace '\s+', ' '); exit $Code }
try {
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class RemoteDebugWin32 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
"@
$W = [RemoteDebugWin32]
$started = Get-Date

# Windows and terminal processes that sit above many unrelated sessions, so sharing one of them says nothing about whose connection it is
$sharedHosts = 'explorer', 'svchost', 'services', 'wininit', 'winlogon', 'WmiPrvSE', 'System', 'userinit', 'sihost',
  'taskhostw', 'conhost', 'OpenConsole', 'WindowsTerminal'

function Get-Text([IntPtr]$h) { $sb = [Text.StringBuilder]::new(512); [void]$W::GetWindowText($h, $sb, 512); $sb.ToString() }
function Get-Class([IntPtr]$h) { $sb = [Text.StringBuilder]::new(64); [void]$W::GetClassName($h, $sb, 64); $sb.ToString() }
function Get-Buttons([IntPtr]$h) {
  $root = [Windows.Automation.AutomationElement]::FromHandle($h)
  $isButton = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
  @($root.FindAll([Windows.Automation.TreeScope]::Descendants, $isButton))
}

# Visible windows titled $Title that belong to the Chrome process listening on the debugging port
function Find-Prompts {
  $found = [System.Collections.Generic.List[IntPtr]]::new()
  [void]$W::EnumWindows({ param($h, $l)
    if ($W::IsWindowVisible($h) -and (Get-Class $h) -eq 'Chrome_WidgetWin_1' -and (Get-Text $h) -eq $Title) {
      $procId = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$procId)
      if ($procId -eq $browserPid) { $found.Add($h) }
    }
    $true }, [IntPtr]::Zero)
  , $found
}

# Open connections to the address Chrome listens on, from outside Chrome, each marked Own when a
# chrome-devtools-mcp process of this agent holds it
function Get-PortConnections([int]$Port) {
  $procs = @{}
  foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine) { $procs[[int]$p.ProcessId] = $p }
  $mine = @{}
  for ($id = $PID; $id -and $procs.ContainsKey($id) -and -not $mine.ContainsKey($id); $id = [int]$procs[$id].ParentProcessId) { $mine[$id] = $true }
  $found = @()
  foreach ($c in @(Get-NetTCPConnection -RemotePort $Port -State Established -ErrorAction SilentlyContinue)) {
    if ($c.OwningProcess -eq $browserPid -or $listenAddresses -notcontains $c.RemoteAddress) { continue }
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

$portFile = Join-Path $UserDataDir 'DevToolsActivePort'
if (-not (Test-Path -LiteralPath $portFile)) {
  Done 7 "NO_PORT: '$portFile' does not exist, so no Chrome is running with remote debugging on in that folder. Nothing was touched."
}
$port = [int]((Get-Content -LiteralPath $portFile -TotalCount 1).Trim())
$listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
  Where-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName -eq $ProcessName })
if (-not $listeners.Count) {
  Done 7 "NO_PORT: no $ProcessName process is listening on port $port from '$portFile'. Nothing was touched."
}
$browserPid = [int]$listeners[0].OwningProcess
$listenAddresses = @($listeners | ForEach-Object { $_.LocalAddress })

$before = if ($Existing) { @() } else { (Find-Prompts).ToArray() }
Write-Output 'WAITING'
$deadline = (Get-Date).AddSeconds($TimeoutSec)
do {
  $hits = @((Find-Prompts).ToArray() | Where-Object { $before -notcontains $_ })
  if ($hits.Count) { break }
  Start-Sleep -Milliseconds 200
} while ((Get-Date) -lt $deadline)
if (-not $hits.Count) {
  $which = if ($Existing) { '' } else { 'new ' }
  Done 2 "NO_DIALOG: no ${which}visible $ProcessName window titled '$Title' before the $TimeoutSec-second wait ran out"
}
# A second window can follow the first, and a window can outlast the connection that raised it
if (-not $Existing) {
  Start-Sleep -Milliseconds 1500
  $hits = @((Find-Prompts).ToArray() | Where-Object { $before -notcontains $_ })
  if (-not $hits.Count) { Done 2 "NO_DIALOG: the window that appeared closed again before it could be answered" }
}
if ($hits.Count -gt 1) { Done 3 "AMBIGUOUS: $($hits.Count) $ProcessName windows titled '$Title'. Each is left open." }
$prompt = $hits[0]

# The window does not say who asked, so it is the agent's only when the agent's own server holds a
# connection and no other connection is there to have raised it. The server connects before Chrome
# raises the window. A run without -Existing looks only at connections made since it started.
$connections = @(@(Get-PortConnections $port) | Where-Object { $Existing -or $_.Created -ge $started.AddSeconds(-1) })
if (-not @($connections | Where-Object { $_.Own }).Count) {
  Done 5 'NOT_OURS: no connection to Chrome''s debugging port from this agent''s own chrome-devtools-mcp server, so the window is left open.'
}
if (@($connections | Where-Object { -not $_.Own }).Count) {
  Done 5 'NOT_OURS: a connection to Chrome''s debugging port other than this agent''s own could have raised the window, so it is left open.'
}

$buttons = Get-Buttons $prompt
$allow = @($buttons | Where-Object { $_.Current.Name -eq $AllowName })
if ($buttons.Count -ne 3 -or $allow.Count -ne 1) {
  Done 4 "NO_BUTTON: the window has $($buttons.Count) buttons and $($allow.Count) named '$AllowName'. It is left open."
}
$allow[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()

$until = (Get-Date).AddSeconds(5)
while ((Get-Date) -lt $until) {
  Start-Sleep -Milliseconds 200
  if (-not $W::IsWindow($prompt) -or -not $W::IsWindowVisible($prompt)) { Done 0 'DONE: Allow was pressed and the window closed' }
}
Done 6 'OPEN: the window did not close after Allow. It is left open.'
} catch {
  Done 1 "ERROR: $($_.Exception.Message)"
}
