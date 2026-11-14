# Setup

## Windows

Install the launcher once and register it in place of the plain server command. It starts the same server, runs a copy kept on disk so the server starts without the network, and answers Chrome's "Allow remote debugging?" window for that server's connections, so no agent step is needed. The launcher passes any flags on to the server and uses `--autoConnect` when it is given none. It needs Node.js with npm and git.

Run these in PowerShell, using the lines for the harness in use. Where a plain registration already exists, remove it first, with `-s <scope>` when it is not at the default scope. A remove that finds nothing is harmless:

```powershell
claude mcp remove chrome-devtools
codex mcp remove chrome-devtools
```

```powershell
$dir = Join-Path $env:LOCALAPPDATA 'easy-browser-use'
npm install --prefix $dir github:LeeorNahum/easy-browser-use-skill
claude mcp add --scope user chrome-devtools -- node "$dir\node_modules\easy-browser-use\scripts\launch-server.mjs"
codex mcp add chrome-devtools -- node "$dir\node_modules\easy-browser-use\scripts\launch-server.mjs"
```

`claude mcp list` shows the result. A session that is already running keeps the server it started, so the change takes effect in the next one, after Chrome has the setting below. Any other harness takes the same stdio command. Flags for the server go after the script path in the add command.

`npm update --prefix $dir` reinstalls the launcher from the repository's default branch and the server within the range `package.json` allows. The launcher writes a line per window to `allow.log` in that folder.

The launcher answers the window in English for the stable channel's Chrome. For another language or channel, register the plain server and run the prompt script with its parameters.

## Elsewhere

Register the plain server once per machine, at user scope:

```text
claude mcp add --scope user chrome-devtools -- npx -y chrome-devtools-mcp@latest --autoConnect
codex mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest --autoConnect
```

Any other harness takes the same stdio command. On Windows this registration works too, and its window is answered by the prompt script.

## Chrome

In Chrome, remote debugging is allowed at `chrome://inspect/#remote-debugging`. The server cannot reach that page before it is attached, so the agent takes desktop control where the harness has it. That is the one setting. Chrome still raises its "Allow remote debugging?" window for each new connection.

`--autoConnect` is what makes the server attach to the running Chrome. Without it the server launches a separate Chrome with a profile of its own, where every page tool still works. When the user's tabs are missing from the list, check that flag first and then which profile the server attached to.

A separate Chrome profile avoids the window. Chrome started with `--remote-debugging-port` and a `--user-data-dir` other than its default is reached with `--browserUrl http://127.0.0.1:<port>` in place of `--autoConnect`. It holds only that profile, which has none of the user's sign-ins unless they sign in there, and any program on the machine can use its open debugging port.
