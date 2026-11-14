# Remote Debugging Prompt

Each time the server attaches to the running Chrome, Chrome can raise a window titled "Allow remote debugging?" with the buttons Turn off in settings, Allow, and Cancel. The server's first call that needs the browser starts the connection, and every call waits until the window is answered. A repeated call while the window waits raises no second one. A window left unanswered goes away after a while, and the next call raises a new one. Chrome ignores a press that comes within a double-click interval of the window appearing or of an earlier press.

The [prompt script](../scripts/allow-remote-debugging.ps1) finds that window through UI Automation, even behind other windows, and invokes its Allow button. It activates no window, moves no mouse, and sends no keys. It is written for Chrome on an English Windows, so on another language pass `-Title` and `-AllowName` as the window shows them, and for another channel pass its folder as `-UserDataDir`.

## What Allow Grants

Allow gives the program on the other end every tab, cookie, and signed-in account of the profile, until the connection ends. Chrome's window is where a person decides that, and it does not say which program asked. The script presses Allow when a chrome-devtools-mcp server, any agent's, holds a connection that could have raised the window, and leaves it open when no server does. While a program of another kind holds any open connection to the port, however old, every window is left open, and the check runs again before each press. So one agent's script can answer another agent's window, and several agents connecting at once are all answered.

## With The Launcher

A server registered through the launcher in Setup needs none of what follows. The launcher starts the script in watch mode beside the server and starts the server once the script is watching, or without the script after fifteen seconds, with a warning on stderr. The script answers each new window for as long as the server runs, looking at the connections made in the ten seconds before it appeared, usually within a second. Every session's watcher sees every window, and one at a time works on them.

It writes a line per window to `allow.log` in `%LOCALAPPDATA%\easy-browser-use`, and lines for its start, its end, and any error of its own. A window's line has a timestamp and the process number of the launcher whose watcher answered it, which can be another session's, then the result word from the table below with its reason.

When a call hangs under the launcher, read that log. No log, or no "watching" line in it, means the watcher never started, and the launcher's stderr says why. A window that was open before the watcher began is left alone. A refusal line means the window was left open, and the table's Next column, written for the plain script, applies to it. A window the log shows nothing for was raised before the watcher was watching or by another Chrome, so run the plain script with `-Existing`. The rest of this file is for a server registered the plain way.

## Running It

Start the script as a background command, or as a separate process whose output can be read while it runs, and make the call that connects only after it prints `WAITING`. If it ends before printing `WAITING`, read its result and do not make the call. The script leaves alone any matching window that was already open when it started, and waits up to 30 seconds for a new one. Raise `-TimeoutSec` when the server may first have to be downloaded, for example to 120. The call returns once the window is answered, and the script prints `DONE`. A result of `NO_DIALOG` can mean the connection was already open, so make the call and see.

For a call that is already hanging, add `-Existing`, which answers the windows open now and looks at every open connection. If the harness cannot run a command while the call waits, the call times out and counts as failed. Run the script with `-Existing` if the window is still open, and make the call again.

Where the skill's files are not on disk, fetch the script and run it. The fetched line runs the repository's current main branch.

```powershell
$s = Join-Path $env:TEMP "allow-remote-debugging-$([guid]::NewGuid()).ps1"; Invoke-RestMethod 'https://raw.githubusercontent.com/LeeorNahum/easy-browser-use-skill/main/scripts/allow-remote-debugging.ps1' -OutFile $s -ErrorAction Stop; pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $s; Remove-Item $s
```

Where the files are on disk, run the script from the skill's folder:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '<skill-root>\scripts\allow-remote-debugging.ps1'
```

On a machine with only Windows PowerShell 5.1, write `powershell` in place of `pwsh`. Any other argument goes after the script's path or after `-File $s`. A missing or malformed argument fails before the script starts, with PowerShell's own error and no result line.

## Results

The plain script prints one result line, starting with the word below, and exits with its number. `NO_PORT` comes before `WAITING`, and `ERROR` can come at any point. Every refusal leaves the window open.

| Exit | Word | Meaning | Next |
| --- | --- | --- | --- |
| 0 | `DONE` | Allow was pressed and every window closed | The waiting call completes. Make it again if it came back failed |
| 1 | `ERROR` | The script itself failed | Read the message, and check whether the window is still open |
| 2 | `NO_DIALOG` | No matching window appeared in time, or it closed before it was answered | Make a call to see whether the connection is already open. If a call hangs and the window is open now, run again with `-Existing`. Otherwise check the title and that the call was made after `WAITING` |
| 3 | `NO_BUTTON` | A window does not show exactly the three buttons this script knows | Chrome may have changed the window. Answer it through desktop control and report it |
| 4 | `REFUSED` | A program other than chrome-devtools-mcp is connected, or no chrome-devtools-mcp server is | Leave the window and report it, naming the program when the log or the connection list shows it. When no server is connected, check that the call was made after `WAITING` |
| 5 | `OPEN` | A window did not close after Allow | Run again with `-Existing`. If it ends in `OPEN` again, answer it through desktop control and report it |
| 6 | `NO_PORT` | No port file, or no Chrome listening on its port, so nothing was watched or touched | Start Chrome, turn remote debugging on at `chrome://inspect/#remote-debugging` through desktop control, or pass the folder of the Chrome that is running as `-UserDataDir`, then start over |
