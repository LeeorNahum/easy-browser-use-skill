# Hanging First Call

A first call that hangs is usually waiting on Chrome's "Allow remote debugging?" window, which Chrome can raise each time the server attaches to the running Chrome. The window has the buttons Turn off in settings, Allow, and Cancel, and every call waits until it is answered. A repeated call while it waits raises no second window. A window left unanswered goes away after a while, and the next call raises a new one. Make a call that was waiting again only when it came back failed or cancelled, after checking that what it was meant to do has not already happened.

`claude mcp get chrome-devtools`, `codex mcp get chrome-devtools`, or another harness's server settings show how the server is registered. One whose arguments name `launch-server.mjs` runs through the launcher from Setup. Off Windows, go to Off Windows at the end.

## Under The Launcher

One watcher, shared by every session on the machine, answers each window. It writes a line per window to `allow.log` in `%LOCALAPPDATA%\easy-browser-use`, and lines for its start, its end, and any error of its own. A window's line has a timestamp and the watcher's process number, then the result word from the table below with its reason.

Read that log. No log, or no "watching" line in it, usually means the watcher never started, and the launcher's stderr says why. A refusal line means the window was left open, and the table's Next column applies to it. A refusal because a program of another kind is connected names each such program by its name, process id, and command line, or its path, so tell the user which program it is. The window is left open because that program could have raised it, so whether it may connect is the user's decision. Once that program is closed, a run of the script with `-Existing` answers the window. A window the log shows nothing for was raised while no watcher ran, by another channel's Chrome, or in another language, so run the script with `-Existing` and the parameters that match it, as below.

## Running The Script

The [prompt script](../scripts/allow-remote-debugging.ps1) finds the window through UI Automation, even behind other windows, and invokes its Allow button. It activates no window, moves no mouse, and sends no keys. Allow gives the program on the other end every tab, cookie, and signed-in account of the profile, and the window does not say which program asked, so the script presses it only when a chrome-devtools-mcp server, any agent's, holds a connection that could have raised the window, and leaves it open while a program of another kind is connected. It is written for Chrome on an English Windows, so on another language pass `-Title` and `-AllowName` as the window shows them, and for another channel pass its folder as `-UserDataDir`.

For a call that is hanging now, run the script with `-Existing`, which answers the windows open now and looks at every open connection. If the harness cannot run a command while the call waits, the call times out and counts as failed. Then run the script with `-Existing` if the window is still open, and make the call again.

For a call not made yet, such as the next one after a window went away unanswered, start the script without `-Existing` as a background command, or as a separate process whose output can be read while it runs, and make the call only after it prints `WAITING`. If it ends before printing `WAITING`, read its result and do not make the call. The script leaves alone any matching window that was already open when it started, and waits up to 30 seconds for a new one. Raise `-TimeoutSec` when the server may first have to be downloaded, for example to 120. The call returns once the window is answered, and the script prints `DONE`. A result of `NO_DIALOG` can mean the connection was already open, so make the call and see.

Where the skill's files are not on disk, fetch the script and run it. The fetched line runs the repository's current main branch.

```powershell
$s = Join-Path $env:TEMP "allow-remote-debugging-$([guid]::NewGuid()).ps1"; Invoke-RestMethod 'https://raw.githubusercontent.com/LeeorNahum/easy-browser-use-skill/main/scripts/allow-remote-debugging.ps1' -OutFile $s -ErrorAction Stop; pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $s -Existing; Remove-Item $s
```

Where the files are on disk, run the script from the skill's folder:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '<skill-root>\scripts\allow-remote-debugging.ps1' -Existing
```

On a machine with only Windows PowerShell 5.1, write `powershell` in place of `pwsh`. Any other argument goes after the script's path or after `-File $s`. A missing or malformed argument fails before the script starts, with PowerShell's own error and no result line.

## Results

The script prints one result line, starting with the word below, and exits with its number. `NO_PORT` comes before `WAITING`, and `ERROR` can come at any point. Every refusal leaves the window open. When the script worked on a window and no launcher is running, the line ends by saying to register the launcher, which stops the window from waiting again at the next connection.

| Exit | Word | Meaning | Next |
| --- | --- | --- | --- |
| 0 | `DONE` | Allow was pressed and every window closed | The waiting call completes. Make it again if it came back failed |
| 1 | `ERROR` | The script itself failed | Read the message, and check whether the window is still open |
| 2 | `NO_DIALOG` | No matching window appeared in time, or it closed before it was answered | Make a call to see whether the connection is already open. If a call hangs and the window is open now, run again with `-Existing`. Otherwise check the title and that the call was made after `WAITING` |
| 3 | `NO_BUTTON` | A window does not show exactly the three buttons this script knows | Chrome may have changed the window. Answer it through desktop control and report it |
| 4 | `REFUSED` | A program other than chrome-devtools-mcp is connected, or no chrome-devtools-mcp server is. A program of another kind is named by its name, process id, and command line or path | Leave the window, and tell the user about each program the line names. Once the user closes it, run again with `-Existing`. When no server is connected, check that the call was made after `WAITING` |
| 5 | `OPEN` | A window did not close after Allow | Run again with `-Existing`. If it ends in `OPEN` again, answer it through desktop control and report it |
| 6 | `NO_PORT` | No port file, or no Chrome listening on its port, so nothing was watched or touched | Start Chrome, turn remote debugging on at `chrome://inspect/#remote-debugging` through desktop control, or pass the folder of the Chrome that is running as `-UserDataDir`, then start over |

## Off Windows

No script answers the window there. Answer it through desktop control where the harness has it, and let the waiting call finish. Tell the user the window is waiting only where the harness has no desktop control. A separate Chrome profile, registered as Setup describes, connects without the window, but holds none of the user's sign-ins.
