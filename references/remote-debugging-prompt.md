# Remote Debugging Prompt

Each time the server attaches to the running Chrome, Chrome can raise a window titled "Allow remote debugging?" with the buttons Turn off in settings, Allow, and Cancel. The server's first call that needs the browser starts the connection, and every call waits until the window is answered. A repeated call while the window waits raises no second one. A window left unanswered goes away after a while, and the next call raises a new one.

The [prompt script](../scripts/allow-remote-debugging.ps1) finds that window through UI Automation, even behind other windows, and invokes its Allow button. It activates no window, moves no mouse, and sends no keys. It is written for Chrome on an English Windows, so on another language pass `-Title` and `-AllowName` as the window shows them, and for another channel pass its folder as `-UserDataDir`.

## Running It

Start the script as a background command, or as a separate process whose output can be read while it runs, and make the call that connects only after it prints `WAITING`. If it ends before printing `WAITING`, read its result and do not make the call. The script ignores a matching window that was already open when it started, and waits up to 30 seconds for a new one. Raise `-TimeoutSec` when the server may first have to be downloaded, for example to 120. The call returns once the window is answered, and the script prints `DONE`. A result of `NO_DIALOG` can mean the connection was already open, so make the call and see.

For a call that is already hanging, add `-Existing`. If the harness cannot run a command while the call waits, the call times out and counts as failed. Run the script with `-Existing` if the window is still open, and make the call again.

Where the skill's files are not on disk, fetch the script and run it in one line. Where they are, run it from the skill's folder. The fetched line runs the repository's current main branch. Both lines are PowerShell. On a machine with only Windows PowerShell 5.1, write `powershell` in place of `pwsh`, and put any other argument after `-File $s` or the script's path:

```powershell
$s = Join-Path $env:TEMP "allow-remote-debugging-$([guid]::NewGuid()).ps1"; Invoke-RestMethod 'https://raw.githubusercontent.com/LeeorNahum/easy-browser-use-skill/main/scripts/allow-remote-debugging.ps1' -OutFile $s -ErrorAction Stop; pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $s
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '<skill-root>\scripts\allow-remote-debugging.ps1'
```

A missing or malformed argument fails before the script starts, with PowerShell's own error and no result line.

## Results

The script prints one result line, starting with the word below, and exits with its number. `NO_PORT`, and `ERROR` from a failed start, come before `WAITING`. Every refusal leaves the window open.

| Exit | Word | Meaning | Next |
| --- | --- | --- | --- |
| 0 | `DONE` | Allow was pressed and the window closed | The waiting call completes. If it still hangs, the window was not its own, so run again with `-Existing` |
| 1 | `ERROR` | The script itself failed | Read the message, and check whether the window is still open |
| 2 | `NO_DIALOG` | No matching window appeared in time, or the one that appeared closed again | Make a call to see whether the connection is already open. If a call hangs and the window is open now, run again with `-Existing`. Otherwise check the title and that the call was made after `WAITING` |
| 3 | `AMBIGUOUS` | Several windows are open, possibly from other agents | Unanswered ones go away after a while, so run again with `-Existing` once one is left |
| 4 | `NO_BUTTON` | The window does not show exactly the three buttons this script knows | The connection was the agent's own. Chrome may have changed the window, so answer it through desktop control and report it |
| 5 | `NOT_OURS` | The agent's own server holds no connection, or another connection could have raised the window | The script cannot tell whose window it is. When the agent's own call is the one hanging and no other agent was starting a connection, desktop control can answer it. Otherwise leave the window, and start over once it has gone away |
| 6 | `OPEN` | The window did not close after Allow | Run again with `-Existing`. If it ends in `OPEN` again, answer it through desktop control and report it |
| 7 | `NO_PORT` | No port file, or no Chrome listening on its port, so nothing was watched or touched | Start Chrome, turn remote debugging on at `chrome://inspect/#remote-debugging` through desktop control, or pass the folder of the Chrome that is running as `-UserDataDir`, then start over |

## What Allow Grants

Allow gives the program on the other end every tab, cookie, and signed-in account of the profile, until the connection ends. Chrome's window is where a person decides that, and it does not say who asked. The script presses it only when the agent's own server holds a connection and no other connection could have raised the window. A chrome-devtools-mcp server that has a parent process in common with the script, such as the harness, counts as the agent's own, and so do agents started from one shell. A run without `-Existing` looks only at connections and windows that appeared after it started, and `-Existing` needs every open connection to be the agent's own. Another agent attaching at the same moment makes the script refuse. No flag or policy is documented that skips the window for the user's own profile, and the one way around it is a separate Chrome profile reached with `--browserUrl`, which holds none of the user's sign-ins unless they sign in there.
