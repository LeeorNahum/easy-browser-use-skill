<#
.SYNOPSIS
Answers a browser's Save As or Open file dialog with window messages, without keystrokes.

.DESCRIPTION
Waits for a new visible file dialog with the given title from the given process, even one behind
other windows, and ignores any such dialog already open when it starts unless -Existing is given.
It fills the file name box when -Path is given and presses Save or Open, or presses Cancel with
-Cancel. It activates no window and sends no keys.

Prints WAITING once it is watching, and then one result line, and exits with one of these codes:
0  DONE      the dialog closed
1  ERROR     the script itself failed
2  NO_DIALOG no matching dialog appeared within -TimeoutSec
3  AMBIGUOUS more than one matched, and each is left open
4  NO_BOX    the dialog has no file name box this script knows, and is left open
5  NOT_SET   the box did not take the text, or a Save As got several paths, and the dialog is left open
6  REJECTED  the dialog showed its error box for the name, and both were closed
7  BLOCKED   another box sits over the dialog, so both are left open
8  TAKEN     the Save As path already exists, so the dialog is left open
9  OPEN      the dialog did not close
10 BAD_PATH  -Path is not usable, found before WAITING, so nothing was watched or touched
The skill's file dialogs reference gives the next step for each code.

.PARAMETER Title
The dialog's title exactly as shown, such as "Save As" or "Open" on an English Windows.

.PARAMETER Path
The full path of the file, with its extension. For several files in an Open dialog, separate their
full paths with |, which no Windows path contains. Omit to keep the name and folder the dialog
proposes, which may not be Downloads.

.PARAMETER Cancel
Press Cancel instead.

.PARAMETER Existing
Answer a dialog that is already open, such as one an earlier run left open.

.PARAMETER ProcessName
The process that owns the dialog. Defaults to chrome.

.PARAMETER TimeoutSec
How long to wait for the dialog to appear. Defaults to 15.
#>
[CmdletBinding(DefaultParameterSetName = 'Answer')]
param(
  [Parameter(Mandatory)][string]$Title,
  [Parameter(ParameterSetName = 'Answer')][string]$Path,
  [Parameter(ParameterSetName = 'Cancel', Mandatory)][switch]$Cancel,
  [switch]$Existing,
  [string]$ProcessName = 'chrome',
  [int]$TimeoutSec = 15
)
$ErrorActionPreference = 'Stop'
function Done([int]$Code, [string]$Line) { Write-Output ($Line -replace '\s+', ' '); exit $Code }
try {
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class FileDialogWin32 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW")]
  public static extern IntPtr SendText(IntPtr h, uint m, IntPtr w, string l, uint flags, uint ms, out IntPtr result);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW")]
  public static extern IntPtr ReadText(IntPtr h, uint m, IntPtr w, StringBuilder l, uint flags, uint ms, out IntPtr result);
}
"@
$W = [FileDialogWin32]
$WM_SETTEXT = 0x000C; $WM_GETTEXT = 0x000D; $WM_GETTEXTLENGTH = 0x000E; $WM_COMMAND = 0x0111
$IDOK = 1; $IDCANCEL = 2; $GW_OWNER = 4; $SMTO_ABORTIFHUNG = 2; $WAIT_MS = 2000

function Get-Text([IntPtr]$h) { $sb = [Text.StringBuilder]::new(512); [void]$W::GetWindowText($h, $sb, 512); $sb.ToString() }
function Get-Class([IntPtr]$h) { $sb = [Text.StringBuilder]::new(64); [void]$W::GetClassName($h, $sb, 64); $sb.ToString() }
function Send-Command([IntPtr]$h, [int]$id) {
  if (-not $W::PostMessage($h, $WM_COMMAND, [IntPtr]$id, [IntPtr]::Zero)) { throw "PostMessage failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
}
# Gone means destroyed, not merely hidden
function Wait-Gone([IntPtr]$h, [int]$Seconds) {
  $until = (Get-Date).AddSeconds($Seconds)
  while ($W::IsWindow($h) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 200 }
  -not $W::IsWindow($h)
}

# Visible dialog-class windows of $ProcessName titled $Title, left out when owned by a window
# of the same title (that is the error box a dialog raises over itself)
function Find-Dialogs {
  $found = [System.Collections.Generic.List[IntPtr]]::new()
  [void]$W::EnumWindows({ param($h, $l)
    if ($W::IsWindowVisible($h) -and (Get-Class $h) -eq '#32770' -and (Get-Text $h) -eq $Title) {
      $procId = 0; [void]$W::GetWindowThreadProcessId($h, [ref]$procId)
      if ((Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName -eq $ProcessName -and
          (Get-Text $W::GetWindow($h, $GW_OWNER)) -ne $Title) { $found.Add($h) }
    }
    $true }, [IntPtr]::Zero)
  , $found
}
# Visible windows owned by the dialog, of any title
function Find-OwnedBoxes([IntPtr]$Owner) {
  $found = [System.Collections.Generic.List[IntPtr]]::new()
  [void]$W::EnumWindows({ param($h, $l)
    if ($W::IsWindowVisible($h) -and $W::GetWindow($h, $GW_OWNER) -eq $Owner) { $found.Add($h) }
    $true }, [IntPtr]::Zero)
  , $found
}
# The dialog's error for a name it cannot use: its own title and a single button
function Test-NameError([IntPtr]$Box) {
  if ((Get-Text $Box) -ne $Title) { return $false }
  $script:buttons = 0
  [void]$W::EnumChildWindows($Box, { param($c, $l) if ((Get-Class $c) -eq 'Button') { $script:buttons++ }; $true }, [IntPtr]::Zero)
  $script:buttons -eq 1
}

# Validate -Path before touching anything
$paths = @()
if ($Path) {
  $paths = @($Path.Split('|') | ForEach-Object { $_.Trim() })
  if ($paths -contains '') { Done 10 'BAD_PATH: -Path has an empty entry. Nothing was touched.' }
  # A full path starts with a drive and a backslash, or is a network path
  foreach ($p in $paths) { if ($p -notmatch '^([A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)') { Done 10 "BAD_PATH: '$p' is not a full path. Nothing was touched." } }
}

$before = if ($Existing) { @() } else { (Find-Dialogs).ToArray() }
Write-Output 'WAITING'
$deadline = (Get-Date).AddSeconds($TimeoutSec)
do {
  $hits = @((Find-Dialogs).ToArray() | Where-Object { $before -notcontains $_ })
  if ($hits.Count) { break }
  Start-Sleep -Milliseconds 250
} while ((Get-Date) -lt $deadline)
if (-not $hits.Count) {
  $which = if ($Existing) { '' } else { 'new ' }
  Done 2 "NO_DIALOG: no ${which}visible $ProcessName dialog titled '$Title' before the $TimeoutSec-second wait ran out"
}
if ($hits.Count -gt 1) { Done 3 "AMBIGUOUS: $($hits.Count) $ProcessName dialogs titled '$Title'. Each is left open." }
$dialog = $hits[0]

$boxes = Find-OwnedBoxes $dialog
if ($boxes.Count) { Done 7 "BLOCKED: a box titled '$(Get-Text $boxes[0])' is over the dialog. Both are left open." }

if ($Cancel) {
  Send-Command $dialog $IDCANCEL
  if (Wait-Gone $dialog 5) { Done 0 'DONE: the dialog was cancelled' }
  Done 9 'OPEN: the dialog did not close after Cancel'
}

# The file name box is an Edit. In an Open dialog it sits inside the combo box numbered 1148.
# In a Save As dialog it is numbered 1001 itself.
$combo = $W::GetDlgItem($dialog, 1148)
$isOpen = $combo -ne [IntPtr]::Zero
$script:edit = [IntPtr]::Zero
[void]$W::EnumChildWindows($(if ($isOpen) { $combo } else { $dialog }), { param($c, $l)
  if ((Get-Class $c) -eq 'Edit' -and ($isOpen -or $W::GetDlgCtrlID($c) -eq 1001)) { $script:edit = $c; return $false }
  $true }, [IntPtr]::Zero)
if ($script:edit -eq [IntPtr]::Zero) { Done 4 'NO_BOX: the dialog has no file name box this script knows. It is left open.' }

if ($paths.Count) {
  if (-not $isOpen -and $paths.Count -gt 1) { Done 5 'NOT_SET: a Save As dialog takes one path. It is left open.' }
  if (-not $isOpen -and (Test-Path -LiteralPath $paths[0])) {
    Done 8 "TAKEN: '$($paths[0])' already exists. The dialog is left open."
  }
  # Several files go in the box as quoted full paths separated by spaces
  $text = if ($paths.Count -gt 1) { ($paths | ForEach-Object { '"' + $_ + '"' }) -join ' ' } else { $paths[0] }
  $r = [IntPtr]::Zero
  if ($W::SendText($script:edit, $WM_SETTEXT, [IntPtr]::Zero, $text, $SMTO_ABORTIFHUNG, $WAIT_MS, [ref]$r) -eq [IntPtr]::Zero) {
    Done 5 'NOT_SET: the dialog did not take the text in time. It is left open.'
  }
  if ($W::ReadText($script:edit, $WM_GETTEXTLENGTH, [IntPtr]::Zero, $null, $SMTO_ABORTIFHUNG, $WAIT_MS, [ref]$r) -eq [IntPtr]::Zero) {
    Done 5 'NOT_SET: the dialog did not report its text in time. It is left open.'
  }
  $sb = [Text.StringBuilder]::new([int]$r + 1)
  if ($W::ReadText($script:edit, $WM_GETTEXT, [IntPtr]($sb.Capacity), $sb, $SMTO_ABORTIFHUNG, $WAIT_MS, [ref]$r) -eq [IntPtr]::Zero -or
      $sb.ToString() -ne $text) { Done 5 'NOT_SET: the box does not hold the text. The dialog is left open.' }
}

# Posted, not sent: a rejected name raises a modal error box, and a sent message would wait on it
Send-Command $dialog $IDOK

$until = (Get-Date).AddSeconds(5)
while ((Get-Date) -lt $until) {
  Start-Sleep -Milliseconds 250
  if (-not $W::IsWindow($dialog)) { Done 0 'DONE: the dialog closed' }
  $boxes = Find-OwnedBoxes $dialog
  if ($boxes.Count) {
    $box = $boxes[0]
    if ($boxes.Count -gt 1 -or -not (Test-NameError $box)) {
      Done 7 "BLOCKED: a box titled '$(Get-Text $box)' is over the dialog. Both are left open."
    }
    Send-Command $box $IDOK
    if (-not (Wait-Gone $box 3)) { Done 7 'BLOCKED: the error box did not close. Both are left open.' }
    Send-Command $dialog $IDCANCEL
    if (Wait-Gone $dialog 5) { Done 6 'REJECTED: the dialog could not use the name, so it was cancelled' }
    Done 9 'OPEN: the dialog refused the name and did not close after Cancel'
  }
}
Done 9 'OPEN: the dialog did not close. It is left open.'
} catch {
  Done 1 "ERROR: $($_.Exception.Message)"
}
