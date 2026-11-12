# Setup

Register the server once per machine, at user scope:

```text
claude mcp add --scope user chrome-devtools -- npx -y chrome-devtools-mcp@latest --autoConnect
codex mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest --autoConnect
```

Any other harness takes the same stdio command.

In Chrome, remote debugging is allowed at `chrome://inspect/#remote-debugging`. The server cannot reach that page before it is attached, so the agent takes desktop control where the harness has it. That is the one setting. Chrome still raises its "Allow remote debugging?" window for each new connection.

`--autoConnect` is what makes the server attach to the running Chrome. Without it the server launches a separate Chrome with a profile of its own, where every page tool still works. When the user's tabs are missing from the list, check that flag first and then which profile the server attached to.

A separate Chrome profile avoids the window. Chrome started with `--remote-debugging-port` and a `--user-data-dir` other than its default is reached with `--browserUrl http://127.0.0.1:<port>` in place of `--autoConnect`. It holds only that profile, which has none of the user's sign-ins unless they sign in there, and any program on the machine can use its open debugging port.
