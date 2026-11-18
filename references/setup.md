# Setup

## Windows

Install the launcher once and register it in place of the plain server command. It starts the same server from a copy kept on disk, so the server starts without the network. The launcher passes any flags on to the server and uses `--autoConnect` when it is given none. It needs Node.js with npm and git.

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

The launcher also starts the server with these defaults, ahead of any flags in the add command, so a flag there overrides a default. Once the add command has a flag of its own, the launcher no longer adds `--autoConnect`, so include `--autoConnect` there too:

- `--no-usage-statistics` and `--no-performance-crux`: the server sends Google no usage statistics and no URLs from performance traces. `--usage-statistics` or `--performance-crux` turns one back on.
- `--maxNavigationSaved=1`: each page keeps the network requests and console messages of its current navigation only, not of the ones before it. A `--maxNavigationSaved` of your own replaces it, and `3` is the server's own default.
- `--workspace` with the root of each local fixed drive, such as `C:\`: the tools that read or write a file, such as the upload tool and a screenshot or snapshot saved to a path, reach any folder on those drives, not only the session's folders and the temp folder, so an agent can attach any file there to a page. Network and removable drives are left out. Folders passed with `--workspace` are added to the drive roots, and turning unrestricted paths on, with `--allow-unrestricted-paths` or in the server's config file, leaves the roots out. Folders listed as `filesystemRoot` in the server's config file take the place of the drive roots, and the harness's own folders and the temp folder stay reachable beside them.
- The server does not check for a newer release of itself, since the launcher keeps it current.

The server's config file is the one `--config` names, or else the first the server finds of `cd4a.config.json` in the folder the `PLUGIN_DATA` variable names and `%LOCALAPPDATA%\Google\cd4a\config.json`. A setting made there keeps its value, and the launcher leaves out its default for that setting. The launcher reads the file as the session starts, so a setting added while the session runs takes effect in the next one.

The launcher keeps itself current. Once a day it checks the repository's default branch, and installs a newer release, or a newer server within the range `package.json` allows, into a folder of its own under `$dir\versions`. Each session starts the newest copy on disk, and one already running keeps the copy it started with. A check that fails changes nothing, and the next session's line in the harness's log for the server says why.

The launcher is written for the stable channel's Chrome on an English Windows. For another language or channel, register the plain server as under Elsewhere, with `--channel=<channel>` after `--autoConnect` for another channel. The plain server has none of the launcher's defaults, so add the flags above after `--autoConnect` to keep them.

## Elsewhere

Register the plain server once per machine, at user scope:

```text
claude mcp add --scope user chrome-devtools -- npx -y chrome-devtools-mcp@latest --autoConnect
codex mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest --autoConnect
```

Any other harness takes the same stdio command.

## Chrome

In Chrome, remote debugging is allowed at `chrome://inspect/#remote-debugging`. The server cannot reach that page before it is attached, so the agent takes desktop control where the harness has it. That is the one setting.

`--autoConnect` is what makes the server attach to the running Chrome. Without it the server launches a separate Chrome with a profile of its own, where every page tool still works. When the user's tabs are missing from the list, check that flag first and then which profile the server attached to.

For a separate Chrome profile, start Chrome with `--remote-debugging-port` and a `--user-data-dir` other than its default, and register the server with `--browserUrl http://127.0.0.1:<port>` in place of `--autoConnect`. That Chrome holds only that profile, which has none of the user's sign-ins unless they sign in there, and any program on the machine can use its open debugging port.
