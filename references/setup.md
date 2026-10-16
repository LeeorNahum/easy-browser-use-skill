# Setup

Register the server once per machine, at user scope:

```text
claude mcp add --scope user chrome-devtools -- npx -y chrome-devtools-mcp@latest --autoConnect
codex mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest --autoConnect
```

Any other harness takes the same stdio command.

In Chrome, the user opens `chrome://inspect/#remote-debugging` and allows remote debugging. That is the one setting.

`--autoConnect` is what makes the server attach to the running Chrome. Without it the server launches a separate Chrome with a profile of its own, where every page tool still works. When the user's tabs are missing from the list, check that flag first and then which profile the server attached to.
